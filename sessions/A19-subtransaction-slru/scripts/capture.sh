#!/usr/bin/env bash
# 문서에 실을 증거를 결과 파일로 남긴다.
#
# 스탠바이 재현 실패는 이 세션의 결론 절반을 차지하는데, 그 근거 두 개가
# 측정 중에는 터미널로만 흘러갔다. 파일이 없으면 검증도 이미지도 불가능하므로
# 따로 남긴다.
#
#   1) 스탠바이의 pg_stat_slru: subtransaction이 0인데 transaction은 살아 있다.
#      통계 수집이 죽어서 0이 아니라는 것을 같은 화면에서 보여야 한다.
#   2) pg_waldump의 XLOG_XACT_ASSIGNMENT 개수: 스탠바이가 오버플로를 통보받는
#      유일한 경로다. 서브트랜잭션 10만 개면 1,562개, SAVEPOINT 3개면 0개다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
P(){ docker exec a19-primary psql -U postgres -d spoon -qAt -c "$1" 2>/dev/null; }
PT(){ docker exec a19-primary psql -U postgres -d spoon -c "$1" 2>&1; }
ST(){ docker exec a19-standby psql -U postgres -d spoon -c "$1" 2>&1; }

for _ in $(seq 1 90); do [ "$(P 'SELECT 1')" = "1" ] && break; sleep 2; done

# ── 1) 스탠바이의 SLRU 카운터 ────────────────────────────────────────────
# 프라이머리에 롱트랜잭션과 SAVEPOINT 쓰기를 걸고, 스탠바이에서 읽으며 관측한다.
docker exec -i a19-primary psql -U postgres -d spoon >/dev/null 2>&1 <<'EOF' &
BEGIN;
SELECT txid_current();
SELECT pg_sleep(50);
ROLLBACK;
EOF
LTX=$!
sleep 3
L0=$(P "SELECT pg_current_wal_lsn()")
docker exec a19-primary pgbench -U postgres -d spoon -n -M prepared \
  -f /scripts/writer-sp-write.sql -c 4 -j 2 -T 30 >/dev/null 2>&1 &
WP=$!
sleep 10
docker exec a19-standby psql -U postgres -d spoon -qAt -c "SELECT pg_stat_reset_shared('slru')" >/dev/null 2>&1
docker exec a19-standby pgbench -U postgres -d spoon -n -M prepared \
  -f /scripts/reader.sql -c 32 -j 4 -T 10 >/dev/null 2>&1
{
  echo "-- 스탠바이. 프라이머리에 롱트랜잭션 + SAVEPOINT 쓰기가 도는 동안 10초 조회 후"
  ST "SELECT name, blks_zeroed, blks_hit, blks_read FROM pg_stat_slru WHERE name IN ('subtransaction','transaction') ORDER BY name;"
} > "$OUT/evidence-standby-slru.txt"
echo "→ results/evidence-standby-slru.txt"

L1=$(P "SELECT pg_current_wal_lsn()")
kill $WP 2>/dev/null; wait $WP 2>/dev/null
P "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE 'SELECT pg_sleep%'" >/dev/null
wait $LTX 2>/dev/null

# ── 2) WAL의 ASSIGNMENT 레코드 개수 ──────────────────────────────────────
count_asg() {  # $1=시작 LSN  $2=끝 LSN
  docker exec a19-primary pg_waldump -p /var/lib/postgresql/data/pg_wal \
    -s "$1" -e "$2" -r Transaction 2>/dev/null \
    | sed -E 's/.*desc: ([A-Z_]+).*/\1/' | sort | uniq -c | sort -rn
}
SP3=$(count_asg "$L0" "$L1")

# 한 트랜잭션에 쓰기 서브트랜잭션 10만 개
L2=$(P "SELECT pg_current_wal_lsn()")
docker exec a19-primary psql -U postgres -d spoon -qAt -c \
  "BEGIN; SELECT txid_current(); DO \$\$ BEGIN FOR i IN 1..100000 LOOP BEGIN UPDATE sponsor SET amount=amount+1 WHERE id=i; EXCEPTION WHEN OTHERS THEN NULL; END; END LOOP; END \$\$; COMMIT;" >/dev/null 2>&1
L3=$(P "SELECT pg_current_wal_lsn()")
SUB100K=$(count_asg "$L2" "$L3")

{
  echo "-- SAVEPOINT 3개짜리 트랜잭션이 도는 구간의 WAL Transaction 레코드"
  echo "\$ pg_waldump -s $L0 -e $L1 -r Transaction | 종류별 집계"
  echo "$SP3"
  echo
  echo "-- 한 트랜잭션에 쓰기 서브트랜잭션 10만 개를 만든 구간"
  echo "\$ pg_waldump -s $L2 -e $L3 -r Transaction | 종류별 집계"
  echo "$SUB100K"
  echo
  echo "-- 100000 / 64 = 1562.5. 트랜잭션 하나 안에서 서브트랜잭션 64개마다 한 번 기록된다."
} > "$OUT/evidence-wal-assignment.txt"
echo "→ results/evidence-wal-assignment.txt"
