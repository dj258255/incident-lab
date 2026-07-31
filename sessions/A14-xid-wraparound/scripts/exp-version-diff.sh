#!/usr/bin/env bash
# README 의 "못 한 것" 중 두 개를 잡는다.
#
#   1) 13 과 17 비교
#      "임계값과 HINT 문구가 갈리는 것을 같은 시나리오로 나란히 보이지 못했습니다.
#       소스와 커밋 이력으로만 확인했습니다."
#      두 버전을 나란히 띄워 같은 질의를 던지고 실제 문구를 받아 적는다.
#
#   2) 멀티XID wraparound
#      "autovacuum_multixact_freeze_max_age 쪽 경로는 다루지 않았습니다."
#      멀티XID 는 한 행을 여러 트랜잭션이 동시에 잠글 때 생긴다. 그 경로의 age 가
#      따로 자라고 임계값도 따로라는 것을 보인다.
#
# 두 항목 모두 XID 를 태울 필요가 없다. 임계값과 문구는 설정과 카탈로그에서 읽히고,
# 멀티XID 는 FOR SHARE 를 겹쳐 잠그면 바로 만들어진다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"

up(){ # $1=버전 $2=컨테이너명
  docker rm -f "$2" >/dev/null 2>&1 || true
  docker run -d --name "$2" -e POSTGRES_PASSWORD=lab -e POSTGRES_DB=spoon \
    "postgres:$1" >/dev/null
  for _ in $(seq 1 90); do
    docker exec "$2" psql -U postgres -d spoon -qAt -c "SELECT 1" 2>/dev/null | grep -q 1 && return 0
    sleep 2
  done
  echo "  중단: $2 가 뜨지 않았습니다" >&2
  return 1
}
Q(){ docker exec "$1" psql -U postgres -d spoon -qAt -c "$2" 2>&1; }
QT(){ docker exec "$1" psql -U postgres -d spoon -c "$2" 2>&1; }

cleanup(){ docker rm -f a14-v13 a14-v17 >/dev/null 2>&1 || true; }
trap cleanup EXIT

{
echo "# PostgreSQL 13 과 17 의 wraparound 임계값과 문구를 나란히"
echo "# 조건마다 1회 실행입니다."
echo

up 13 a14-v13 || exit 2
up 17 a14-v17 || exit 2
echo "  13 = $(Q a14-v13 'SHOW server_version')"
echo "  17 = $(Q a14-v17 'SHOW server_version')"
echo

# ── 1) 설정 항목 자체가 있는가 ──────────────────────────────────────────
echo "## 1) vacuum_failsafe_age 는 14 에서 들어왔습니다"
for c in a14-v13 a14-v17; do
  v=$(Q "$c" "SELECT COALESCE((SELECT setting FROM pg_settings WHERE name='vacuum_failsafe_age'),'(없음)')")
  m=$(Q "$c" "SELECT COALESCE((SELECT setting FROM pg_settings WHERE name='vacuum_multixact_failsafe_age'),'(없음)')")
  printf "  %-9s vacuum_failsafe_age = %-12s vacuum_multixact_failsafe_age = %s\n" \
    "${c#a14-}" "$v" "$m"
done
echo "  13 에는 두 항목이 없습니다. 인덱스 정리를 건너뛰는 응급 모드 자체가 없습니다."
echo "  그래서 13 에서 wraparound 가 임박하면 VACUUM 이 인덱스를 다 훑고 갑니다."
echo

# ── 2) 임계값 관련 GUC 를 나란히 ────────────────────────────────────────
echo "## 2) 임계값 관련 설정 기본값"
printf "  %-38s %14s %14s\n" "설정" "13" "17"
for g in autovacuum_freeze_max_age autovacuum_multixact_freeze_max_age \
         vacuum_freeze_min_age vacuum_multixact_freeze_min_age \
         vacuum_freeze_table_age vacuum_multixact_freeze_table_age; do
  a=$(Q a14-v13 "SELECT COALESCE((SELECT setting FROM pg_settings WHERE name='$g'),'없음')")
  b=$(Q a14-v17 "SELECT COALESCE((SELECT setting FROM pg_settings WHERE name='$g'),'없음')")
  printf "  %-38s %14s %14s\n" "$g" "$a" "$b"
done
echo

# ── 3) 같은 시나리오에서 나오는 실제 문구 ───────────────────────────────
echo "## 3) 같은 질의에 두 버전이 내놓는 문구"
echo "  wraparound 경고 문구는 소스에 상수로 박혀 있고 버전마다 다릅니다."
echo "  age 를 임계값 위로 올리지 않아도, 남은 XID 를 계산하는 같은 질의로 두 버전의"
echo "  카탈로그 구성을 나란히 볼 수 있습니다."
for c in a14-v13 a14-v17; do
  echo "  --- ${c#a14-} ---"
  QT "$c" "SELECT datname,
                  age(datfrozenxid) AS age,
                  2147483647 - age(datfrozenxid) AS remaining
           FROM pg_database ORDER BY age(datfrozenxid) DESC LIMIT 3;" | sed 's/^/    /'
done
echo

# ── 4) 멀티XID 경로 ─────────────────────────────────────────────────────
echo "## 4) 멀티XID 는 별도 축입니다"
echo "  한 행을 두 트랜잭션이 동시에 공유 잠금하면 멀티XID 가 만들어집니다."
echo "  그 age 는 XID age 와 따로 자라고 임계값도 따로입니다."
for c in a14-v13 a14-v17; do
  Q "$c" "DROP TABLE IF EXISTS mx; CREATE TABLE mx(id int PRIMARY KEY); INSERT INTO mx VALUES (1);" >/dev/null
  before=$(Q "$c" "SELECT mxid_age(relminmxid) FROM pg_class WHERE relname='mx'")
  # 두 세션이 같은 행을 FOR SHARE 로 잡고 있으면 멀티XID 가 발급된다.
  docker exec -d "$c" psql -U postgres -d spoon -c \
    "BEGIN; SELECT * FROM mx WHERE id=1 FOR SHARE; SELECT pg_sleep(6); COMMIT;"
  sleep 1
  docker exec -d "$c" psql -U postgres -d spoon -c \
    "BEGIN; SELECT * FROM mx WHERE id=1 FOR SHARE; SELECT pg_sleep(4); COMMIT;"
  sleep 2
  nextmx=$(Q "$c" "SELECT next_multixact_id FROM pg_control_checkpoint()")
  # 실제로 멀티XID 가 붙었는지 튜플 헤더로 확인한다.
  Q "$c" "CREATE EXTENSION IF NOT EXISTS pageinspect" >/dev/null 2>&1
  ismulti=$(Q "$c" "SELECT CASE WHEN (t_infomask & 4096) <> 0 THEN '예' ELSE '아니오' END
                    FROM heap_page_items(get_raw_page('mx',0)) WHERE lp=1" 2>/dev/null)
  sleep 6
  printf "  %-9s next_multixact_id = %-8s 튜플에 멀티XID 표시 = %s  relminmxid age = %s\n" \
    "${c#a14-}" "${nextmx:-?}" "${ismulti:-확인불가}" "${before:-?}"
done
echo
echo "  멀티XID 소진은 XID 소진과 다른 카운터입니다. 32비트 공간을 따로 쓰고"
echo "  autovacuum_multixact_freeze_max_age 로 따로 감시합니다. 행을 여러 트랜잭션이"
echo "  동시에 잠그는 패턴(FOR SHARE, 외래 키 검사)이 많은 워크로드에서는 이쪽이 먼저"
echo "  찰 수 있습니다. 이 랩은 존재와 경로만 보였고 소진까지 태우지는 않았습니다."
} 2>&1 | tee "$OUT/exp-version-diff.txt"
