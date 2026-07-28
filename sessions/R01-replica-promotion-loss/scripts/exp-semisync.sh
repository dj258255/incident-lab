#!/usr/bin/env bash
# 실험 B: 반동기(AFTER_SYNC)에서는 같은 분단·강제 종료에서 확정 커밋이 유실되지 않는다.
# 실험 C: 다만 타임아웃이 지나면 비동기로 강등되고, 그 창에서는 유실이 되살아난다.
#
# 전제: 환경을 새로 만들었고(setup.sh) 복제가 붙어 있다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/../../.venv/bin/python"
OUT="$ROOT/results"
mkdir -p "$OUT"

S() { docker exec r01-source  mysql -uroot -plab -N -B -e "$1" 2>/dev/null; }
R() { docker exec r01-replica mysql -uroot -plab -N -B -e "$1" 2>/dev/null; }
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$OUT/semi-timeline.txt"; }
: > "$OUT/semi-timeline.txt"

log "반동기 플러그인 설치 (AFTER_SYNC, 타임아웃 8초)"
S "INSTALL PLUGIN rpl_semi_sync_source SONAME 'semisync_source.so';" 2>/dev/null || true
R "INSTALL PLUGIN rpl_semi_sync_replica SONAME 'semisync_replica.so';" 2>/dev/null || true
S "SET GLOBAL rpl_semi_sync_source_enabled=1;
   SET GLOBAL rpl_semi_sync_source_timeout=8000;
   SET GLOBAL rpl_semi_sync_source_wait_point=AFTER_SYNC;"
R "SET GLOBAL rpl_semi_sync_replica_enabled=1; STOP REPLICA IO_THREAD; START REPLICA IO_THREAD;"
sleep 3
S "SHOW STATUS LIKE 'Rpl_semi_sync_source_status';" | tee -a "$OUT/semi-timeline.txt"

log "실험 B: 분단 5초 뒤(타임아웃 8초 안) 소스 강제 종료"
"$PY" "$ROOT/scripts/writer.py" 30 "$OUT/semi-writer.csv" > "$OUT/semi-writer-summary.txt" 2>&1 &
WRITER=$!
sleep 10
log "복제망 분단"
docker network disconnect r01-repl-net r01-replica
sleep 5
log "소스 강제 종료 (반동기가 ack를 기다리는 창 안)"
docker kill r01-source >/dev/null
wait $WRITER || true
log "쓰기 종료: $(cat "$OUT/semi-writer-summary.txt")"

sleep 2
R "STOP REPLICA;"
R "SELECT COUNT(*), COALESCE(MAX(seq),0), COALESCE(SUM(amount),0) FROM spoon.sponsor;" > "$OUT/semi-promoted.txt"
log "승격본 행수/최대seq/합계: $(cat "$OUT/semi-promoted.txt")"

log "실험 C 준비: 환경 원복 후 타임아웃이 지나 강등된 상태에서 종료"
docker network connect r01-repl-net r01-replica 2>/dev/null || true
docker start r01-source >/dev/null
for _ in $(seq 1 40); do docker exec r01-source mysqladmin ping -plab >/dev/null 2>&1 && break; sleep 2; done
sleep 2
# 승격본이 소스보다 뒤에 있으므로 레플리카를 소스에 다시 붙인다 (실험 B에서 유실이 없으면 그대로 이어진다)
R "CHANGE REPLICATION SOURCE TO SOURCE_HOST='source', SOURCE_USER='root', SOURCE_PASSWORD='lab',
   SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1; START REPLICA;"
S "SET GLOBAL rpl_semi_sync_source_enabled=1; SET GLOBAL rpl_semi_sync_source_timeout=8000;"
sleep 5

"$PY" "$ROOT/scripts/writer.py" 40 "$OUT/degraded-writer.csv" > "$OUT/degraded-writer-summary.txt" 2>&1 &
WRITER=$!
sleep 10
log "복제망 분단. 8초 뒤 강등을 기다린다"
docker network disconnect r01-repl-net r01-replica
sleep 12
S "SHOW STATUS LIKE 'Rpl_semi_sync_source_status';" | tee -a "$OUT/semi-timeline.txt"
log "강등 확인 후 5초 더 쓰고 강제 종료"
sleep 5
docker kill r01-source >/dev/null
wait $WRITER || true
log "쓰기 종료: $(cat "$OUT/degraded-writer-summary.txt")"

sleep 2
R "STOP REPLICA;"
R "SELECT COUNT(*), COALESCE(MAX(seq),0), COALESCE(SUM(amount),0) FROM spoon.sponsor;" > "$OUT/degraded-promoted.txt"
log "승격본 행수/최대seq/합계: $(cat "$OUT/degraded-promoted.txt")"
log "실험 B·C 종료"
