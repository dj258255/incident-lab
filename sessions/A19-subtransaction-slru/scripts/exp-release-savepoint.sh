#!/usr/bin/env bash
# RELEASE SAVEPOINT 가 활성 서브트랜잭션 수를 줄이는가.
#
# postgres.ai 는 활성 서브트랜잭션을 64 미만으로 유지하면 총 100개를 만들어도
# 열화가 없다고 적었다. 이 세션은 총 70개를 만들어 절벽을 봤을 뿐, 활성 수와
# 누적 수를 나눠 재지 않았다. 그 둘을 가른다.
#
# 세 방식을 같은 개수(70)로 만들고 PGPROC 캐시에 몇 개가 남는지 본다.
#   A. SAVEPOINT → UPDATE → RELEASE        (각각 커밋)
#   B. SAVEPOINT → UPDATE → ROLLBACK TO    (각각 롤백)
#   C. SAVEPOINT 를 겹쳐 쌓고 풀지 않음     (전부 활성)
#
# 관측은 PG17 의 pg_stat_get_backend_subxact 로 한다. PGPROC 의 subxids 캐시
# 개수와 넘침 여부를 그대로 돌려준다. 64를 넘으면 넘침이 참이 되고, 그때부터
# 읽는 쪽이 pg_subtrans(SLRU)를 봐야 한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
Q(){ docker exec a19-primary psql -U postgres -d spoon -qAt -c "$1" 2>&1; }

for _ in $(seq 1 60); do [ "$(Q 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(Q 'SELECT 1')" = "1" ] || { echo "중단: a19-primary 가 쿼리를 받지 못합니다" >&2; exit 2; }

N=${N:-70}

# 대상 세션을 띄우고, 지정한 방식으로 서브트랜잭션 N개를 만든 뒤 버틴다.
run_case() {  # $1=라벨  $2=본문 SQL
  local label="$1" body="$2"
  docker exec -i a19-primary psql -U postgres -d spoon -q -c "SELECT pg_backend_pid()" >/dev/null 2>&1
  # 태그를 application_name 에 심어 관측 쪽에서 이 세션을 찾는다.
  docker exec -i a19-primary psql -U postgres -d spoon -q >/dev/null 2>&1 <<EOF &
SET application_name = 'sp-$label';
BEGIN;
UPDATE sponsor SET amount = amount + 1 WHERE id = 1;
$body
SELECT pg_sleep(12);
COMMIT;
EOF
  sleep 5
  # 관측. application_name 으로 대상 백엔드를 찾아 캐시 상태를 읽는다.
  Q "SELECT format('  %-26s 캐시에 남은 서브트랜잭션 %s개, 넘침 %s',
                   a.application_name, s.subxact_count, s.subxact_overflowed)
       FROM pg_stat_activity a,
            pg_stat_get_backend_subxact(
              (SELECT b FROM pg_stat_get_backend_idset() b
                WHERE pg_stat_get_backend_pid(b) = a.pid)) s
      WHERE a.application_name = 'sp-$label'"
  wait
}

{
echo "# RELEASE SAVEPOINT 가 활성 서브트랜잭션 수를 줄이는가"
echo "# $(Q 'SELECT version()' | cut -c1-45)"
echo "# 세 방식 모두 서브트랜잭션 ${N}개. PGPROC 캐시 상한은 PGPROC_MAX_CACHED_SUBXIDS=64"
echo

echo "## A. SAVEPOINT → UPDATE → RELEASE (각각 커밋)"
run_case A "DO \$\$
BEGIN
  FOR i IN 1..$N LOOP
    BEGIN
      UPDATE sponsor SET amount = amount + 1 WHERE id = 1000 + i;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
END \$\$;"
echo "  PL/pgSQL 의 EXCEPTION 블록이 곧 서브트랜잭션이고, 블록을 정상으로 빠져나가면"
echo "  RELEASE 와 같습니다. 이 세션의 기존 워크로드가 쓰던 방식입니다."
echo

echo "## B. SAVEPOINT → UPDATE → ROLLBACK TO (각각 롤백)"
run_case B "DO \$\$
BEGIN
  FOR i IN 1..$N LOOP
    BEGIN
      UPDATE sponsor SET amount = amount + 1 WHERE id = 2000 + i;
      RAISE EXCEPTION 'rollback this subtransaction';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
END \$\$;"
echo

echo "## C. SAVEPOINT 를 겹쳐 쌓고 풀지 않음 (전부 활성)"
SP=""
for i in $(seq 1 "$N"); do SP="$SP
SAVEPOINT s$i;
UPDATE sponsor SET amount = amount + 1 WHERE id = 3000 + $i;"; done
run_case C "$SP"
echo

echo "## 정리"
echo "  캐시에 남은 개수가 64를 넘으면 넘침이 참이 되고, 그 시점부터 읽는 쪽은"
echo "  스냅숏만으로 판정하지 못하고 pg_subtrans SLRU 를 봐야 합니다."
} 2>&1 | tee "$OUT/exp-release-savepoint.txt"
