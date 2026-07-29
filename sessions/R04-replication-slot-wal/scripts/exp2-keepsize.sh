#!/usr/bin/env bash
# 실험 2. 안전장치를 걸면 무엇이 달라지는가.
#
# max_slot_wal_keep_size는 PostgreSQL 13부터 있는 상한이다.
# 슬롯이 붙잡을 수 있는 WAL 양을 제한하고, 넘으면 슬롯을 무효화한다.
# 디스크를 지키는 대신 그 슬롯의 CDC는 처음부터 다시 시작해야 한다. 그 교환을 실측한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"
P() { docker exec r04-pg psql -U postgres -d spoon -tAc "$1" 2>/dev/null; }
PT(){ docker exec r04-pg psql -U postgres -d spoon -c "$1" 2>&1; }
log(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "$OUT/exp2.txt"; }
: > "$OUT/exp2.txt"

P "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots" >/dev/null 2>&1 || true
log "안전장치 설정: max_slot_wal_keep_size = 64MB"
docker exec r04-pg psql -U postgres -c "ALTER SYSTEM SET max_slot_wal_keep_size='64MB';" >/dev/null 2>&1
docker exec r04-pg psql -U postgres -c "SELECT pg_reload_conf();" >/dev/null 2>&1
sleep 1
log "현재값 $(P "SELECT current_setting('max_slot_wal_keep_size')")"

P "SELECT pg_create_logical_replication_slot('cdc_slot','test_decoding')" >/dev/null
log "슬롯 생성. 컨슈머는 붙이지 않는다 (죽은 CDC 상태로 시작)"

docker exec -d r04-pg bash -c "
  for i in \$(seq 1 100000); do
    psql -U postgres -d spoon -c \"INSERT INTO watch_log (live_id, payload)
      SELECT (random()*1000)::int, repeat(md5(random()::text), 32) FROM generate_series(1,400);\" >/dev/null 2>&1
    sleep 0.1
  done"
log "쓰기 시작"

echo "ts,wal_mb,lag_mb,wal_status,safe_wal_mb" > "$OUT/keepsize.csv"
PREV=""
# 2026-07-29 실행분(results/exp2.txt)은 이 자리에서 "t=${i}s"를 찍었다. i는 반복 횟수이고
# 경과 초가 아니다. 한 바퀴에 psql 왕복이 네 번 들어가 실제로는 평균 2.32초가 걸렸고,
# 그래서 로그의 t=19s는 실제 41.7초였다. 이후 실행은 아래처럼 시작 시각과의 차이를 찍는다.
# 이미 기록된 exp2.txt는 원문이므로 고치지 않았다. 실제 경과는 keepsize.csv로 확인한다.
T0=$(date +%s)
for i in $(seq 1 100); do
  WAL=$(P "SELECT ROUND(SUM(size)/1024/1024) FROM pg_ls_waldir()")
  LAG=$(P "SELECT ROUND(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)/1024/1024) FROM pg_replication_slots WHERE slot_name='cdc_slot'")
  ST=$(P "SELECT wal_status FROM pg_replication_slots WHERE slot_name='cdc_slot'")
  SAFE=$(P "SELECT ROUND(COALESCE(safe_wal_size,0)/1024/1024) FROM pg_replication_slots WHERE slot_name='cdc_slot'")
  echo "$(date +%s.%N),${WAL:-0},${LAG:-0},${ST:-none},${SAFE:-0}" >> "$OUT/keepsize.csv"
  if [ "$ST" != "$PREV" ]; then
    log "  t=$(( $(date +%s) - T0 ))s(경과) 반복 ${i}회  WAL ${WAL}MB  슬롯지연 ${LAG}MB  상태 ${ST}  여유 ${SAFE}MB"
    PREV="$ST"
  fi
  [ "$ST" = "lost" ] && { log "  슬롯이 무효화됐다. 더 쌓지 않는다."; break; }
  sleep 2
done

log "최종 상태"
PT "SELECT slot_name, active, wal_status,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag,
    pg_size_pretty(safe_wal_size) AS safe_wal
    FROM pg_replication_slots;" | tee -a "$OUT/exp2.txt"
log "WAL $(P "SELECT pg_size_pretty(SUM(size)) FROM pg_ls_waldir()"), 파일 $(P "SELECT COUNT(*) FROM pg_ls_waldir()")개"

log "무효화된 슬롯에 컨슈머를 다시 붙이면"
docker exec r04-pg bash -c "timeout 5 pg_recvlogical -U postgres -d spoon --slot=cdc_slot --start -f /dev/null" 2>&1 | head -3 | sed 's/^/  /' | tee -a "$OUT/exp2.txt"

docker exec r04-pg bash -c "pkill -f 'seq 1 100000'" 2>/dev/null || true
docker exec r04-pg psql -U postgres -c "ALTER SYSTEM RESET max_slot_wal_keep_size; SELECT pg_reload_conf();" >/dev/null 2>&1
log "종료"
