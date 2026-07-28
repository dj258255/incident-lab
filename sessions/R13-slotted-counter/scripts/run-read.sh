#!/usr/bin/env bash
# 읽기 비용을 잰다. 쓰기로 데이터를 채운 뒤 같은 데이터를 읽는다.
#   사용법: ./run-read.sh <mode> <slots> <label>
#
# 슬롯 카운터의 대가는 조회다. 쓰기 처리량만 비교하면 슬롯이 공짜처럼 보인다.
# 채우는 단계는 모든 변형이 같은 시간(SEED) 동안 돌리고, 그 뒤 읽기만 잰다.
set -euo pipefail

MODE="${1:-atomic}"
SLOTS="${2:-0}"
LABEL="${3:-$MODE}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JAVA_BIN="${JAVA_BIN:-/opt/homebrew/Cellar/openjdk@21/21.0.9/libexec/openjdk.jdk/Contents/Home/bin/java}"
OUT="$ROOT/results/read"
mkdir -p "$OUT"

SEED="${SEED:-30s}"
VUS="${VUS:-50}"
DURATION="${DURATION:-30s}"
LIVES="${LIVES:-1000}"

echo "=============================================================="
echo " 읽기 측정: $LABEL (mode=$MODE slots=$SLOTS)"
echo "=============================================================="

pkill -f 'sponsor-api.jar' 2>/dev/null || true
sleep 1

MODE="$MODE" COUNTER_SLOTS="$SLOTS" LIVES="$LIVES" \
  "$JAVA_BIN" -Xms1g -Xmx1g -XX:+UseG1GC \
  -jar "$ROOT/app/build/libs/sponsor-api.jar" > "$OUT/${LABEL}.app.log" 2>&1 &
APP_PID=$!
trap 'kill $APP_PID 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
  curl -sf -X POST http://127.0.0.1:8080/reset >/dev/null 2>&1 && break
  sleep 1
done
curl -sf -X POST http://127.0.0.1:8080/sponsor -H 'Content-Type: application/json' \
  -d '{"liveId":1,"userId":1,"amount":100}' >/dev/null || { echo "후원 요청 실패" >&2; exit 1; }
curl -sf -X POST http://127.0.0.1:8080/reset >/dev/null

echo "[1/3] 데이터 채우기 ${SEED}"
LIVES=$LIVES SCENARIO=zipf VUS=100 DURATION=$SEED \
  k6 run --quiet --no-summary "$ROOT/scripts/load.js" >/dev/null 2>&1 || true

# 슬롯이 실제로 몇 행이나 찼는지 남긴다. 읽기 비용의 근거가 되는 숫자다.
docker exec r13-mysql mysql -uroot -plab spoon -N -B -e "
  SELECT '방송1_카운터행수', COUNT(*) FROM live_counter_slot WHERE live_id = 1
  UNION ALL SELECT '전체_카운터행수', COUNT(*) FROM live_counter_slot
  UNION ALL SELECT '원장행수', COUNT(*) FROM sponsor_log;" > "$OUT/${LABEL}.rows.txt" 2>/dev/null || true
cat "$OUT/${LABEL}.rows.txt" 2>/dev/null || true

echo "[2/3] 읽기 측정 ${DURATION}"
LIVES=$LIVES SCENARIO="${SCENARIO:-hotspot}" VUS=$VUS DURATION=$DURATION \
  k6 run --summary-export "$OUT/${LABEL}.k6.json" "$ROOT/scripts/read-bench.js" \
  2>&1 | tee "$OUT/${LABEL}.k6.txt" | tail -12

echo "[3/3] 읽은 값 확인"
curl -s http://127.0.0.1:8080/total/1 | tee "$OUT/${LABEL}.total.json"
echo

kill $APP_PID 2>/dev/null || true
sleep 1
echo "→ 결과 저장: $OUT/${LABEL}.*"
