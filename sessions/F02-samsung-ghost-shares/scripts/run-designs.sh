#!/usr/bin/env bash
# 설계 넷의 비용과 동시 매도의 직렬화를 잰다.
#
#   전반부: sql/08-designs.sql 이 네 설계를 갈아 끼우며 매도·매수 200회씩 잰다
#   후반부: 같은 네 설계에서 동시 세션 넷이 매도를 던져 직렬화 정도를 본다
#
# 후반부를 셸에서 따로 도는 이유는 psql 한 세션 안에서는 동시성을 만들 수 없기 때문이다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
DB=lab-f02-db
PSQL(){ docker exec -i "$DB" psql -U lab -d ledger -X -q "$@"; }

for _ in $(seq 1 60); do
  docker exec "$DB" pg_isready -U lab -d ledger >/dev/null 2>&1 && break
  sleep 2
done
docker exec "$DB" pg_isready -U lab -d ledger >/dev/null 2>&1 \
  || { echo "중단: $DB 가 준비되지 않았습니다" >&2; exit 2; }

{
echo "# 설계 넷의 비용과 동시 매도의 직렬화"
echo "# PostgreSQL $(PSQL -At -c 'SHOW server_version')"
echo "# 조건마다 1회 실행입니다."
echo

# 전반부. 스키마가 없으면 먼저 만든다.
PSQL -At -c "SELECT 1 FROM information_schema.tables WHERE table_name='holdings'" | grep -q 1 \
  || docker exec -i "$DB" psql -U lab -d ledger -X -v ON_ERROR_STOP=1 < "$ROOT/sql/01-schema.sql" >/dev/null
docker exec -i "$DB" psql -U lab -d ledger -X -v ON_ERROR_STOP=1 < "$ROOT/sql/08-designs.sql"

echo
echo "=================================================================="
echo "동시 매도 넷이 붙었을 때의 직렬화"
echo "=================================================================="
echo "  네 세션이 각각 매도 50회를 던집니다. 총 200회로 위 표와 같은 양입니다."
echo "  한 세션이 걸리는 시간이 위의 총 소요와 비슷하면 직렬화가 없는 것이고,"
echo "  네 배 가까이 늘어나면 넷이 줄을 선 것입니다."
echo

# 설계를 하나씩 다시 걸고 동시 매도를 던진다.
# 08-designs.sql 이 남긴 함수를 그대로 쓴다.
apply(){ # $1=설계 이름
  PSQL -c "SELECT reset_ledger()" >/dev/null
  case "$1" in
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
  A) echo "A. 문장 단위 + advisory lock" ;;
  B) echo "B. 행 단위 + WHEN" ;;
  C) echo "C. 전이 테이블" ;;
  D) echo "D. 물질화 합계 + CHECK" ;;
esac; }

printf "  %-28s %12s %12s %10s\n" "설계" "가장 빠른 세션" "가장 느린 세션" "실패"
for d in A B C D; do
  apply "$d"
  : > /tmp/f02-times.txt
  for s in 1 2 3 4; do
    (
      T0=$(date +%s%N)
      docker exec -i "$DB" psql -U lab -d ledger -X -q -c "
        DO \$\$ DECLARE i int; BEGIN
          FOR i IN 1..50 LOOP
            BEGIN
              UPDATE holdings SET shares = shares - 1
               WHERE account_id = (random()*999)::int + 1 AND shares > 0;
            EXCEPTION WHEN others THEN NULL; END;
          END LOOP; END \$\$;" >/dev/null 2>>/tmp/f02-err.txt
      T1=$(date +%s%N)
      python3 -c "print(f'{($T1-$T0)/1e6:.0f}')" >> /tmp/f02-times.txt
    ) &
  done
  wait
  MIN=$(sort -n /tmp/f02-times.txt | head -1)
  MAX=$(sort -n /tmp/f02-times.txt | tail -1)
  ERR=$(grep -c "ERROR" /tmp/f02-err.txt 2>/dev/null || echo 0)
  : > /tmp/f02-err.txt
  printf "  %-28s %10sms %10sms %10s건\n" "$(label "$d")" "$MIN" "$MAX" "$ERR"
done

echo
echo "  네 세션이 같은 양(각 50회, 합 200회)을 던졌습니다. 위 표의 시간과 앞 표의"
echo "  총 소요를 견주면 직렬화 정도가 보입니다. 한 세션의 시간이 앞 표의 200회 총"
echo "  소요와 비슷하면 넷이 줄을 선 것이고, 4분의 1에 가까우면 나란히 돈 것입니다."
} 2>&1 | tee "$OUT/designs.txt"
