#!/usr/bin/env bash
# 세션 수를 바꿔 가며 네 방어의 비용을 잰다.
# 7절은 네 세션 하나뿐이었다. 물질화 합계(D)가 76ms 로 문제없다고 적었는데, 그 값은
# 네 세션에서만 성립한다. company 한 행의 잠금이 병목이 되는 지점을 찾는다.
# 캐싱: 조건마다 컨테이너 재시작 + 같은 웜업.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
C=f02-conc; LEVELS=${LEVELS:-"2 4 8 16 32"}; PER=${PER:-40}

docker rm -f "$C" >/dev/null 2>&1
docker run -d --name "$C" -e POSTGRES_PASSWORD=lab -e POSTGRES_DB=lab postgres:17.5 -c max_connections=200 >/dev/null
P(){ docker exec -i "$C" psql -U postgres -d lab -At -c "$1" 2>&1; }
for _ in $(seq 1 90); do [ "$(P 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(P 'SELECT 1')" = "1" ] || { echo "중단: PostgreSQL 이 안 뜹니다" >&2; exit 2; }

setup(){
  P "DROP TABLE IF EXISTS holding, company CASCADE;
     CREATE TABLE company(id int PRIMARY KEY, issued bigint NOT NULL, held bigint NOT NULL DEFAULT 0);
     CREATE TABLE holding(id bigserial PRIMARY KEY, company_id int NOT NULL, owner int NOT NULL, qty bigint NOT NULL);
     INSERT INTO company VALUES (1, 89000000, 0);
     CREATE INDEX ON holding(company_id);" >/dev/null
}
# D 방어: 물질화 합계. company.held 를 갱신하며 발행총수를 넘지 않게 검사한다.
work(){ # $1 = 세션 수
  local n="$1" i
  setup
  docker restart "$C" >/dev/null; for _ in $(seq 1 90); do [ "$(P 'SELECT 1')" = "1" ] && break; sleep 2; done
  local t0 t1
  t0=$(date +%s%N)
  for i in $(seq 1 "$n"); do
    docker exec -i "$C" bash -c "
      for k in \$(seq 1 $PER); do
        psql -U postgres -d lab -q -c \"
          BEGIN;
          UPDATE company SET held = held + 100 WHERE id=1 AND held + 100 <= issued;
          INSERT INTO holding(company_id,owner,qty)
            SELECT 1, $i, 100 WHERE (SELECT held FROM company WHERE id=1) IS NOT NULL;
          COMMIT;\" >/dev/null 2>&1
      done" 2>/dev/null &
  done
  wait
  t1=$(date +%s%N)
  local held rows
  held=$(P "SELECT held FROM company WHERE id=1"); rows=$(P "SELECT COALESCE(SUM(qty),0) FROM holding")
  local ms=$(( (t1-t0)/1000000 )); local total=$((n*PER))
  local ok="맞음"; [ "${held:-0}" != "${rows:-1}" ] && ok="**어긋남**"
  printf "  %4s세션  총 %5s트랜잭션  %7sms  요청당 %6sms  company.held=%s 합계=%s %s\n" \
    "$n" "$total" "$ms" "$(( ms / (total>0?total:1) ))" "${held:-?}" "${rows:-?}" "$ok"
  echo "$n,$total,$ms,${held:-0},${rows:-0}" >> "$OUT/concurrency-sweep.csv"
}
echo "sessions,transactions,elapsed_ms,company_held,holding_sum" > "$OUT/concurrency-sweep.csv"
{
echo "# 물질화 합계 방어의 세션 수별 비용"
echo "# PostgreSQL $(P 'SHOW server_version') · 세션당 $PER 트랜잭션 · 조건마다 재시작"
echo "# 7절은 네 세션 하나였습니다. company 한 행의 잠금이 병목이 되는 지점을 찾습니다."
echo
for n in $LEVELS; do work "$n"; done
echo
echo "  요청당 시간이 세션 수에 비례해 늘면 그 지점부터 한 행의 잠금이 직렬화 병목입니다."
} 2>&1 | tee "$OUT/exp3-concurrency-sweep.txt"
docker rm -f "$C" >/dev/null 2>&1
