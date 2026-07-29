#!/usr/bin/env bash
# CDC 컨슈머가 멈추면 WAL이 어떻게 쌓이는지 잰다.
#
# 타임라인
#   0~30초    슬롯 없이 쓰기만. WAL이 재활용되는 정상 상태를 기준선으로 잡는다
#   30초      논리 복제 슬롯을 만들고 pg_recvlogical로 소비를 시작한다
#   30~60초   컨슈머가 살아 있는 상태. 슬롯의 restart_lsn이 따라 움직인다
#   60초      컨슈머를 죽인다. 슬롯은 그대로 남는다 (이것이 사고의 시작이다)
#   60~180초  쓰기는 계속된다. WAL이 쌓이기만 하고 지워지지 않는다
#   180초     슬롯을 지우고 회수되는지 확인한다
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/../../.venv/bin/python"
OUT="$ROOT/results"
mkdir -p "$OUT"
P()  { docker exec r04-pg psql -U postgres -d spoon -tAc "$1" 2>/dev/null; }
PT() { docker exec r04-pg psql -U postgres -d spoon -c "$1" 2>&1; }
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$OUT/timeline.txt"; }
: > "$OUT/timeline.txt"

P "DROP TABLE IF EXISTS watch_log;
   CREATE TABLE watch_log (id BIGSERIAL PRIMARY KEY, live_id BIGINT NOT NULL,
                           payload TEXT NOT NULL, created_at TIMESTAMPTZ DEFAULT now());" >/dev/null
P "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots" >/dev/null 2>&1 || true

# 1초마다 WAL 크기와 슬롯 지연을 기록한다.
"$PY" - "$OUT/metrics.csv" <<'PYEOF' &
import csv, subprocess, sys, time
out = sys.argv[1]
def q(sql):
    r = subprocess.run(["docker","exec","r04-pg","psql","-U","postgres","-d","spoon","-tAc",sql],
                       capture_output=True, text=True)
    return r.stdout.strip()
with open(out, "w", newline="", buffering=1) as f:
    w = csv.writer(f)
    w.writerow(["ts","wal_bytes","wal_files","slot_lag_bytes","slot_active","rows"])
    end = time.time() + 210
    while time.time() < end:
        wal = q("SELECT COALESCE(SUM(size),0) FROM pg_ls_waldir()")
        n   = q("SELECT COUNT(*) FROM pg_ls_waldir()")
        lag = q("SELECT COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn),0)::bigint "
                "FROM pg_replication_slots LIMIT 1") or "0"
        act = q("SELECT COALESCE(bool_or(active),false) FROM pg_replication_slots") or "f"
        rows= q("SELECT COUNT(*) FROM watch_log")
        w.writerow([f"{time.time():.1f}", wal or 0, n or 0, lag, act, rows or 0])
        time.sleep(1)
PYEOF
MON=$!

# 쓰기 부하. 행당 1KB를 넣어 WAL이 눈에 띄게 늘게 한다.
docker exec -d r04-pg bash -c "
  for i in \$(seq 1 100000); do
    psql -U postgres -d spoon -c \"INSERT INTO watch_log (live_id, payload)
      SELECT (random()*1000)::int, repeat(md5(random()::text), 32) FROM generate_series(1,200);\" >/dev/null 2>&1
    sleep 0.2
  done"
# 이 루프의 목표치는 초당 1,000행이지만 psql을 매번 새로 띄우는 비용 때문에 그대로 나오지 않는다.
# 2026-07-29 실행분(results/timeline.txt)은 여기서 "초당 약 1,000행"이라고 찍었고, 같은 실행의
# metrics.csv로 다시 재니 859.6행/초(구간별 400~1,000)였다. 목표치를 기록하면 나중에 실측과 헷갈리므로
# 로그에는 루프 구성만 적는다. 이미 기록된 timeline.txt는 원문이라 고치지 않았다.
log "쓰기 시작 (200행 INSERT 뒤 0.2초 대기 반복, 행당 약 1KB. 실제 속도는 metrics.csv로 잰다)"

sleep 30
log "논리 복제 슬롯 생성 + pg_recvlogical 시작"
P "SELECT pg_create_logical_replication_slot('cdc_slot','test_decoding')" | sed 's/^/  /' | tee -a "$OUT/timeline.txt"
docker exec -d r04-pg bash -c \
  "pg_recvlogical -U postgres -d spoon --slot=cdc_slot --start -f /dev/null > /tmp/recv.log 2>&1"
sleep 2
log "컨슈머 상태 active=$(P "SELECT active FROM pg_replication_slots WHERE slot_name='cdc_slot'")"

sleep 30
log "컨슈머 강제 종료 (CDC 파이프라인이 죽은 상황)"
docker exec r04-pg bash -c "pkill -f pg_recvlogical" 2>/dev/null || true
sleep 2
log "슬롯 상태 active=$(P "SELECT active FROM pg_replication_slots WHERE slot_name='cdc_slot'") (슬롯은 남아 있다)"

log "쓰기를 120초 더 계속한다"
sleep 120

log "현재 WAL $(P "SELECT pg_size_pretty(SUM(size)) FROM pg_ls_waldir()"), 파일 $(P "SELECT COUNT(*) FROM pg_ls_waldir()")개"
log "슬롯 지연 $(P "SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) FROM pg_replication_slots WHERE slot_name='cdc_slot'")"
PT "SELECT slot_name, active, wal_status,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag
    FROM pg_replication_slots;" | tee -a "$OUT/timeline.txt"

log "조치: 슬롯 삭제 후 체크포인트"
P "SELECT pg_drop_replication_slot('cdc_slot')" >/dev/null
P "CHECKPOINT" >/dev/null
sleep 8
log "삭제 후 WAL $(P "SELECT pg_size_pretty(SUM(size)) FROM pg_ls_waldir()"), 파일 $(P "SELECT COUNT(*) FROM pg_ls_waldir()")개"

docker exec r04-pg bash -c "pkill -f 'seq 1 100000'" 2>/dev/null || true
wait $MON 2>/dev/null || true
log "측정 종료"
