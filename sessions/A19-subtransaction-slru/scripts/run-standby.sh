#!/usr/bin/env bash
# GitLab 사례(스탠바이 절벽)를 시도한다.
#   사용법: ./run-standby.sh <라벨> <writer 파일명(확장자 제외)> <longtx:yes|no>
#
# 스탠바이가 서브트랜잭션 오버플로를 알게 되는 경로는 WAL의
# XLOG_XACT_ASSIGNMENT 레코드뿐이다. 그 레코드가 실제로 나오는지 함께 센다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
LABEL="$1"; W="$2"; LONGTX="${3:-yes}"
P(){ docker exec a19-primary psql -U postgres -d spoon -qAt -c "$1"; }
S(){ docker exec a19-standby psql -U postgres -d spoon -qAt -c "$1"; }

if [ "$LONGTX" = "yes" ]; then
  docker exec -i a19-primary psql -U postgres -d spoon >"$OUT/$LABEL-longtx.log" 2>&1 <<'IEOF' &
BEGIN;
SELECT txid_current();
SELECT pg_sleep(60);
ROLLBACK;
IEOF
  LTX=$!; sleep 3
else LTX=""; fi

L0=$(P "SELECT pg_current_wal_lsn()")
docker exec a19-primary pgbench -U postgres -d spoon -n -f "/scripts/$W.sql" -c 4 -j 2 -T 45 >"$OUT/$LABEL-writer.txt" 2>&1 &
WP=$!
sleep 15
SNAP=$(S "SELECT pg_current_snapshot()")
LAG=$(S "SELECT COALESCE(EXTRACT(epoch FROM now()-pg_last_xact_replay_timestamp())::int,-1)")
S "SELECT pg_stat_reset_shared('slru')" >/dev/null
( END=$(( $(date +%s) + 10 ))
  while [ "$(date +%s)" -lt "$END" ]; do
    S "SELECT coalesce(wait_event_type,'CPU')||'/'||coalesce(wait_event,'-') FROM pg_stat_activity WHERE state='active' AND query LIKE 'select amount%'" >> "$OUT/$LABEL-waits.txt"; sleep 0.2
  done ) & SAMP=$!
docker exec a19-standby pgbench -U postgres -d spoon -n -M prepared -f /scripts/reader.sql \
  -c 32 -j 4 -T 10 >"$OUT/$LABEL-reader.txt" 2>&1
wait $SAMP 2>/dev/null || true
SL=$(S "SELECT blks_hit||' '||blks_read FROM pg_stat_slru WHERE name='subtransaction'")
L1=$(P "SELECT pg_current_wal_lsn()")
ASG=$(docker exec a19-primary pg_waldump -p /var/lib/postgresql/data/pg_wal -s "$L0" -e "$L1" -r Transaction 2>/dev/null | grep -c ASSIGNMENT || true)
kill $WP 2>/dev/null; wait $WP 2>/dev/null
[ -n "$LTX" ] && { P "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE 'SELECT pg_sleep%'" >/dev/null; wait $LTX 2>/dev/null; }

TPS=$(grep -E "^tps = " "$OUT/$LABEL-reader.txt"|head -1|awk '{print $3}')
SW=$(grep -c SubtransSLRU "$OUT/$LABEL-waits.txt" 2>/dev/null || echo 0)
printf '%-16s 쓰기=%-16s 롱TX=%-3s tps=%-12s SLRU(hit read)=%-10s ASSIGNMENT=%-6s SubtransSLRU=%s 스냅샷=%s 지연=%ss\n' \
  "$LABEL" "$W" "$LONGTX" "${TPS:-?}" "$SL" "$ASG" "$SW" "$SNAP" "$LAG"
