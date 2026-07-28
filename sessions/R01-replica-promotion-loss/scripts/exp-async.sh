#!/usr/bin/env bash
# 실험 A: 비동기 복제에서 네트워크 분단 중 프라이머리가 죽으면 커밋이 사라진다.
#
# 타임라인
#   0초   쓰기 시작 (커밋 성공 건만 로그)
#   10초  복제망 분단 (레플리카를 repl-net에서 분리. 호스트 관측 경로는 유지)
#   25초  소스 강제 종료 (분단 15초 동안의 커밋은 레플리카에 없다)
#   이후  레플리카 승격, 유실 계수, 옛 소스를 살려 GTID 차집합 확인
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/../../.venv/bin/python"
OUT="$ROOT/results"
mkdir -p "$OUT"

S() { docker exec r01-source  mysql -uroot -plab -N -B -e "$1" 2>/dev/null; }
R() { docker exec r01-replica mysql -uroot -plab -N -B -e "$1" 2>/dev/null; }
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$OUT/async-timeline.txt"; }
: > "$OUT/async-timeline.txt"

# 레플리카의 Seconds_Behind_Source를 1초마다 기록한다. 분단 후에도 0인 구간이 요점이다.
( : > "$OUT/async-sbs.csv"
  echo "ts,seconds_behind,io_running" >> "$OUT/async-sbs.csv"
  for _ in $(seq 1 60); do
    LINE=$(docker exec r01-replica mysql -uroot -plab -e "SHOW REPLICA STATUS\G" 2>/dev/null \
           | awk '/Seconds_Behind_Source/{s=$2} /Replica_IO_Running:/{io=$2} END{print s","io}')
    echo "$(date +%s.%N | cut -c1-14),$LINE" >> "$OUT/async-sbs.csv"
    sleep 1
  done ) &
MON=$!

log "쓰기 시작 (40초 예정)"
"$PY" "$ROOT/scripts/writer.py" 40 "$OUT/async-writer.csv" > "$OUT/async-writer-summary.txt" 2>&1 &
WRITER=$!

sleep 10
log "복제망 분단 (docker network disconnect)"
docker network disconnect r01-repl-net r01-replica

sleep 15
log "소스 강제 종료 (docker kill)"
docker kill r01-source >/dev/null
wait $WRITER || true
log "쓰기 종료: $(cat "$OUT/async-writer-summary.txt")"

sleep 3
log "레플리카 승격 (STOP REPLICA)"
R "STOP REPLICA;"
PROMOTED_ROWS=$(R "SELECT COUNT(*), COALESCE(MAX(seq),0), COALESCE(SUM(amount),0) FROM spoon.sponsor;")
log "승격본 상태: 행수/최대seq/합계 = $PROMOTED_ROWS"
echo "$PROMOTED_ROWS" > "$OUT/async-promoted.txt"
R "SELECT @@gtid_executed;" > "$OUT/async-replica-gtid.txt"

wait $MON 2>/dev/null || true

log "옛 소스를 다시 살려 무엇이 유실됐는지 확인"
docker network connect r01-repl-net r01-replica 2>/dev/null || true
docker start r01-source >/dev/null
for _ in $(seq 1 40); do docker exec r01-source mysqladmin ping -plab >/dev/null 2>&1 && break; sleep 2; done
sleep 3
S "SELECT @@gtid_executed;" > "$OUT/async-source-gtid.txt"
OLD=$(cat "$OUT/async-source-gtid.txt")
NEW=$(cat "$OUT/async-replica-gtid.txt")
S "SELECT GTID_SUBTRACT('$OLD','$NEW') AS lost_gtids;" > "$OUT/async-gtid-subtract.txt"
log "GTID 차집합(옛 소스에만 있는 트랜잭션): $(cat "$OUT/async-gtid-subtract.txt")"
S "SELECT COUNT(*), MAX(seq), SUM(amount) FROM spoon.sponsor;" > "$OUT/async-oldsource-rows.txt"
log "옛 소스의 행수/최대seq/합계: $(cat "$OUT/async-oldsource-rows.txt")"

log "실험 A 종료"
