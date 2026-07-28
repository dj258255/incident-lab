#!/usr/bin/env bash
# Redis를 부하 도중에 죽였다가 되살리고, 카운터를 원장에서 복구한다.
#
# 4절에서 "카운터는 파생 데이터라 원장에서 다시 만들 수 있다"고 적었다.
# 적었으면 보여야 한다. 이 스크립트가 그 주장을 실행으로 확인한다.
#
# 흐름: 부하 시작 → 20초에 Redis 강제 종료 → 35초에 재기동(데이터 없음)
#       → 부하 종료 → 정합성 깨진 것 확인 → /rebuild → 다시 확인
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JAVA_BIN="${JAVA_BIN:-/opt/homebrew/Cellar/openjdk@21/21.0.9/libexec/openjdk.jdk/Contents/Home/bin/java}"
OUT="$ROOT/results/failure"
mkdir -p "$OUT"
LABEL="${1:-redis-kill}"

VUS="${VUS:-50}"
DURATION="${DURATION:-60s}"
KILL_AT="${KILL_AT:-20}"
REVIVE_AT="${REVIVE_AT:-35}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$OUT/${LABEL}.timeline.txt"; }

: > "$OUT/${LABEL}.timeline.txt"

pkill -f 'sponsor-api.jar' 2>/dev/null || true
docker start r13-redis >/dev/null 2>&1 || true
sleep 2

MODE=redis COUNTER_SLOTS=0 LIVES=1000 \
  "$JAVA_BIN" -Xms1g -Xmx1g -XX:+UseG1GC \
  -jar "$ROOT/app/build/libs/sponsor-api.jar" > "$OUT/${LABEL}.app.log" 2>&1 &
APP_PID=$!
trap 'kill $APP_PID 2>/dev/null || true; docker start r13-redis >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 60); do
  curl -sf -X POST http://127.0.0.1:8080/reset >/dev/null 2>&1 && break
  sleep 1
done
log "앱 기동 완료"

# Redis를 죽이고 되살리는 일정을 따로 돌린다.
(
  sleep "$KILL_AT"
  echo "[$(date '+%H:%M:%S')] Redis 강제 종료" >> "$OUT/${LABEL}.timeline.txt"
  docker kill r13-redis >/dev/null 2>&1 || true
  sleep $((REVIVE_AT - KILL_AT))
  echo "[$(date '+%H:%M:%S')] Redis 재기동 (저장 설정이 없어 데이터는 비어 있다)" >> "$OUT/${LABEL}.timeline.txt"
  docker start r13-redis >/dev/null 2>&1 || true
) &
SCHED_PID=$!

log "부하 시작 ${DURATION} (VU $VUS)"
LIVES=1000 SCENARIO=zipf VUS=$VUS DURATION=$DURATION \
  k6 run --summary-export "$OUT/${LABEL}.k6.json" "$ROOT/scripts/load.js" \
  2>&1 | tee "$OUT/${LABEL}.k6.txt" | tail -14
wait $SCHED_PID 2>/dev/null || true

# Redis가 다시 붙을 시간을 준다. 반영 주기가 2초라 그보다 넉넉히 기다린다.
sleep 6
log "복구 전 정합성"
curl -s http://127.0.0.1:8080/verify | tee "$OUT/${LABEL}.before.json"
echo

log "원장에서 카운터 재구성"
curl -s -X POST http://127.0.0.1:8080/rebuild | tee "$OUT/${LABEL}.rebuild.json"
echo

log "복구 후 정합성"
curl -s http://127.0.0.1:8080/verify | tee "$OUT/${LABEL}.after.json"
echo

kill $APP_PID 2>/dev/null || true
sleep 1
log "종료"
echo "→ 결과 저장: $OUT/${LABEL}.*"
