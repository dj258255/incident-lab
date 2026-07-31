#!/usr/bin/env bash
# README 의 "못 한 것" 두 개를 잡는다.
#
#   1) 동시성이 네 세션 하나입니다
#      "설계 넷의 직렬화를 네 세션에서만 쟀습니다. 세션 수를 늘리면 어느 설계가 먼저
#       무너지는지는 안 봤습니다."
#      세션 수를 2·4·8·16 으로 바꿔 가며 같은 총량을 나눠 던진다. 총량을 고정해야
#      "세션이 늘어서 오래 걸린다" 와 "일이 늘어서 오래 걸린다" 가 안 섞인다.
#
#   2) 한 번의 고정 타이밍 실행입니다
#      조건마다 REPEAT 회 돌려 회차 폭을 함께 남긴다.
#
# 직렬화를 읽는 법. 총량이 고정이므로 완벽히 병렬이면 세션이 늘수록 벽시계가 줄어야
# 한다. 완전히 직렬이면 세션 수와 무관하게 일정하다. 늘어나면 경합 비용이 일보다 큰 것이다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
DB=lab-f02-db
TOTAL=${TOTAL:-200}
SESSION_LIST=${SESSION_LIST:-"2 4 8 16"}
REPEAT=${REPEAT:-3}

PSQL(){ docker exec -i "$DB" psql -U lab -d ledger -X -qAt "$@"; }

for _ in $(seq 1 60); do [ "$(PSQL -c 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(PSQL -c 'SELECT 1')" = "1" ] || { echo "중단: $DB 가 쿼리를 받지 못합니다" >&2; exit 2; }

# 기반 스키마부터 확인한다. 러너가 단계마다 볼륨까지 지우고 새로 띄우므로 표가 없다.
# 처음에는 reset_ledger 함수만 확인했는데, 08-designs.sql 이 함수는 만들고 표는 안
# 만들기 때문에 그 확인은 통과했다. 그리고 매 세션이 "relation holdings does not exist"
# 를 찍으며 돌아 벽시계만 남았다. 표와 행 수까지 확인한다.
ensure_schema(){
  local n
  n=$(PSQL -c "SELECT count(*) FROM information_schema.tables
               WHERE table_schema='public' AND table_name IN ('holdings','company')")
  if [ "${n:-0}" != "2" ]; then
    echo "기반 스키마가 없습니다. 01-schema.sql 과 00-seed-holdings.sql 을 겁니다."
    docker exec -i "$DB" psql -U lab -d ledger -X -q -v ON_ERROR_STOP=1 < "$ROOT/sql/01-schema.sql" >/dev/null 2>&1
    docker exec -i "$DB" psql -U lab -d ledger -X -q -v ON_ERROR_STOP=1 < "$ROOT/sql/00-seed-holdings.sql" >/dev/null 2>&1
  fi
  n=$(PSQL -c "SELECT count(*) FROM information_schema.tables
               WHERE table_schema='public' AND table_name IN ('holdings','company')")
  [ "${n:-0}" = "2" ] || { echo "중단: holdings 와 company 표가 없습니다" >&2; exit 3; }
  local rows
  rows=$(PSQL -c "SELECT count(*) FROM holdings")
  case "${rows:-0}" in ''|*[!0-9]*) rows=0 ;; esac
  [ "$rows" -gt 0 ] || { echo "중단: holdings 가 비어 있습니다" >&2; exit 3; }
  echo "스키마 확인: holdings ${rows}행"
}
ensure_schema

# 08-designs.sql 이 남기는 함수들이 있어야 한다. 없으면 먼저 걸어 준다.
HAVE=$(PSQL -c "SELECT count(*) FROM pg_proc WHERE proname='reset_ledger'")
if [ "${HAVE:-0}" = "0" ]; then
  echo "설계 함수가 없습니다. sql/08-designs.sql 을 먼저 겁니다."
  docker exec -i "$DB" psql -U lab -d ledger -X -v ON_ERROR_STOP=1 < "$ROOT/sql/08-designs.sql" >/dev/null
fi
HAVE=$(PSQL -c "SELECT count(*) FROM pg_proc WHERE proname='reset_ledger'")
[ "${HAVE:-0}" != "0" ] || { echo "중단: reset_ledger 함수가 없습니다" >&2; exit 3; }

# 매 회차 끝에 표가 여전히 있는지 본다. 없으면 그 뒤 값은 전부 빈 루프의 시간이다.
guard_rows(){
  local rows
  rows=$(PSQL -c "SELECT count(*) FROM holdings" 2>/dev/null)
  case "${rows:-0}" in ''|*[!0-9]*) rows=0 ;; esac
  [ "$rows" -gt 0 ] || { echo "중단: 실행 중에 holdings 가 사라졌습니다" >&2; exit 4; }
}

drop_triggers(){
  PSQL -c "DROP TRIGGER IF EXISTS trg_total_cap ON holdings;
           DROP TRIGGER IF EXISTS trg_total_cap_row ON holdings;
           DROP TRIGGER IF EXISTS trg_total_cap_trans ON holdings;
           DROP TRIGGER IF EXISTS trg_sync_total ON holdings;
           ALTER TABLE company DROP CONSTRAINT IF EXISTS chk_total_within_issued;
           ALTER TABLE company DROP COLUMN IF EXISTS total_shares" >/dev/null 2>&1 || true
}

apply(){ # $1=설계
  drop_triggers
  PSQL -c "SELECT reset_ledger()" >/dev/null
  case "$1" in
    none) : ;;
    A) PSQL -c "CREATE TRIGGER trg_total_cap AFTER INSERT OR UPDATE OF shares ON holdings
                FOR EACH STATEMENT EXECUTE FUNCTION assert_total_within_issued()" >/dev/null ;;
    B) PSQL -c "CREATE TRIGGER trg_total_cap_row AFTER UPDATE OF shares ON holdings
                FOR EACH ROW WHEN (NEW.shares > OLD.shares)
                EXECUTE FUNCTION assert_row_increase()" >/dev/null ;;
    C) PSQL -c "CREATE TRIGGER trg_total_cap_trans AFTER UPDATE ON holdings
                REFERENCING OLD TABLE AS oldtab NEW TABLE AS newtab
                FOR EACH STATEMENT EXECUTE FUNCTION assert_transition()" >/dev/null ;;
    D) PSQL -c "ALTER TABLE company ADD COLUMN total_shares bigint NOT NULL DEFAULT 0" >/dev/null
       PSQL -c "UPDATE company SET total_shares=(SELECT coalesce(sum(shares),0) FROM holdings) WHERE company_id=1" >/dev/null
       PSQL -c "ALTER TABLE company ADD CONSTRAINT chk_total_within_issued CHECK (total_shares <= issued_shares)" >/dev/null
       PSQL -c "CREATE TRIGGER trg_sync_total AFTER UPDATE ON holdings
                REFERENCING OLD TABLE AS oldtab NEW TABLE AS newtab
                FOR EACH STATEMENT EXECUTE FUNCTION sync_total()" >/dev/null ;;
  esac
}

label(){ case "$1" in
  none) echo "대조군(가드 없음)" ;;
  A) echo "A. 문장 단위 + advisory" ;;
  B) echo "B. 행 단위 + WHEN" ;;
  C) echo "C. 전이 테이블" ;;
  D) echo "D. 물질화 합계 + CHECK" ;;
esac; }

# 세션 $1 개가 각각 $2 회씩 매도를 던진다. 벽시계 밀리초를 찍는다.
run_wave(){ # $1=세션수 $2=세션당 횟수
  local s T0 T1
  : > /tmp/f02sw-err.txt
  T0=$(date +%s%N)
  for s in $(seq 1 "$1"); do
    (
      docker exec -i "$DB" psql -U lab -d ledger -X -q -c "
        DO \$\$ DECLARE i int; BEGIN
          FOR i IN 1..$2 LOOP
            BEGIN
              UPDATE holdings SET shares = shares - 1
               WHERE account_id = (random()*999)::int + 1 AND shares > 0;
            EXCEPTION WHEN others THEN NULL; END;
          END LOOP; END \$\$;" >/dev/null 2>>/tmp/f02sw-err.txt
    ) &
  done
  wait
  T1=$(date +%s%N)
  python3 -c "print(f'{($T1-$T0)/1e6:.0f}')"
}

{
echo "# 동시 세션 수를 늘리면 어느 설계가 먼저 무너지는가"
echo "# PostgreSQL $(PSQL -c 'SHOW server_version')"
echo "# 총 매도 ${TOTAL}회 고정, 세션 수 ${SESSION_LIST}, 조건마다 ${REPEAT}회"
echo
echo "  총량을 고정했으므로 세션이 늘수록 벽시계가 줄면 나란히 돈 것이고,"
echo "  일정하면 줄을 선 것이고, 늘어나면 경합 비용이 일보다 큰 것입니다."
echo

: > "$OUT/concurrency-sweep.csv"
echo "design,sessions,run,wall_ms,errors" >> "$OUT/concurrency-sweep.csv"

for d in none A B C D; do
  echo "### $(label "$d")"
  printf "  %10s %26s %10s %10s\n" "세션" "회차별 벽시계" "중앙" "2세션 대비"
  BASE=
  for n in $SESSION_LIST; do
    PER=$(( TOTAL / n ))
    [ "$PER" -lt 1 ] && PER=1
    VALS=""
    for run in $(seq 1 "$REPEAT"); do
      apply "$d"
      MS=$(run_wave "$n" "$PER")
      guard_rows
      ERR=$(grep -c "ERROR" /tmp/f02sw-err.txt 2>/dev/null || echo 0)
      echo "$d,$n,$run,$MS,$ERR" >> "$OUT/concurrency-sweep.csv"
      VALS="$VALS $MS"
    done
    MED=$(echo $VALS | tr ' ' '\n' | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
    [ -z "$BASE" ] && BASE="$MED"
    RATIO=$(python3 -c "print(f'{${MED:-0}/${BASE:-1}:.2f}배')")
    printf "  %10s %26s %8sms %10s\n" "$n" "[$(echo $VALS | tr ' ' ',')]" "$MED" "$RATIO"
  done
  echo
done

echo "=================================================================="
echo "## 정리"
echo "=================================================================="
python3 - "$OUT/concurrency-sweep.csv" <<'PY'
import csv, sys, collections, statistics
rows = collections.defaultdict(list)
for r in csv.DictReader(open(sys.argv[1], encoding='utf-8')):
    rows[(r['design'], int(r['sessions']))].append(float(r['wall_ms']))
designs = []
for d, _ in rows:
    if d not in designs:
        designs.append(d)
sessions = sorted({s for _, s in rows})
LBL = {'none': '대조군', 'A': 'A 문장+advisory', 'B': 'B 행+WHEN',
       'C': 'C 전이 테이블', 'D': 'D 물질화+CHECK'}
head = "  {:<18}".format("설계") + "".join(f"{s:>10}" for s in sessions) + f"{'최저 대비 최고':>16}"
print(head)
for d in designs:
    meds = [statistics.median(rows[(d, s)]) for s in sessions if (d, s) in rows]
    cells = "".join(f"{m:>9.0f}ms" for m in meds)
    worst = max(meds) / min(meds) if meds and min(meds) else 0
    print(f"  {LBL.get(d, d):<18}{cells}{worst:>15.2f}배")
print()
print("  마지막 열이 1 에 가까우면 세션 수가 늘어도 벽시계가 안 변한 것입니다.")
print("  총량이 고정이므로 그것은 완전히 줄을 섰다는 뜻입니다.")
print("  1 보다 크게 나오면 경합 자체의 비용이 일보다 크다는 뜻입니다.")
PY
echo
echo "  각 조건 ${REPEAT}회 실행이고 총 매도 횟수는 ${TOTAL}회로 고정했습니다."
} 2>&1 | tee "$OUT/exp-concurrency-sweep.txt"
