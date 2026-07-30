#!/usr/bin/env bash
# 앱 인스턴스를 N대 띄우고 같은 부하를 나눠 보낸다.
#   사용법: ./run-multi.sh <mode> <slots> <인스턴스수> <label>
#
# JVM 안의 자물쇠는 그 JVM만 지킨다. 인스턴스를 늘리면 각자 자기 자물쇠만 보므로
# 단일 인스턴스에서 정확했던 구현이 다시 틀리기 시작한다. 그것을 실측으로 남긴다.
set -euo pipefail

MODE="${1:-jvm-lock}"
SLOTS="${2:-0}"
INSTANCES="${3:-2}"
LABEL="${4:-${MODE}-x${INSTANCES}}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JAVA_BIN="${JAVA_BIN:-/opt/homebrew/Cellar/openjdk@21/21.0.9/libexec/openjdk.jdk/Contents/Home/bin/java}"
OUT="$ROOT/results/multi"
mkdir -p "$OUT"

VUS="${VUS:-100}"
DURATION="${DURATION:-60s}"
WARMUP="${WARMUP:-20s}"
LIVES="${LIVES:-1000}"
# 총 힙을 고정한다. 기본 1024MB 를 인스턴스 수로 나눈다.
TOTAL_HEAP_MB="${TOTAL_HEAP_MB:-1024}"
HEAP_MB=$(( TOTAL_HEAP_MB / INSTANCES ))

echo "=============================================================="
echo " 다중 인스턴스: $LABEL (mode=$MODE slots=$SLOTS 인스턴스=$INSTANCES)"
echo " 총 힙 ${TOTAL_HEAP_MB}MB 를 나눠 인스턴스마다 -Xmx${HEAP_MB}m"
echo "=============================================================="

pkill -f 'sponsor-api.jar' 2>/dev/null || true
sleep 1

PIDS=()
URLS=""
for i in $(seq 0 $((INSTANCES - 1))); do
  PORT=$((8080 + i))
  # 총 힙을 인스턴스 수와 무관하게 고정한다. 인스턴스마다 1g 를 주면 2대일 때 총 2GB 가 되어
  # 처리량 차이에 힙 차이가 섞인다. TOTAL_HEAP_MB 를 인스턴스 수로 나눠 준다.
  PORT=$PORT MODE="$MODE" COUNTER_SLOTS="$SLOTS" LIVES="$LIVES" \
    "$JAVA_BIN" -Xms${HEAP_MB}m -Xmx${HEAP_MB}m -XX:+UseG1GC \
    -jar "$ROOT/app/build/libs/sponsor-api.jar" > "$OUT/${LABEL}.app${i}.log" 2>&1 &
  PIDS+=($!)
  URLS="${URLS:+$URLS,}http://127.0.0.1:$PORT"
done
trap 'kill "${PIDS[@]}" 2>/dev/null || true' EXIT

for i in $(seq 0 $((INSTANCES - 1))); do
  PORT=$((8080 + i))
  READY=0
  for _ in $(seq 1 90); do
    curl -sf "http://127.0.0.1:$PORT/verify" >/dev/null 2>&1 && { READY=1; break; }
    sleep 1
  done
  [ "$READY" = "1" ] || { echo "인스턴스 $PORT 가 뜨지 않았다." >&2; exit 1; }
done

# 초기화는 한 대에서만 한다. 여러 대가 동시에 TRUNCATE하면 서로의 초기화를 지운다.
curl -sf -X POST http://127.0.0.1:8080/reset >/dev/null
echo "[1/4] 인스턴스 $INSTANCES 대 기동 완료 ($URLS)"

echo "[2/4] 워밍업 ${WARMUP}"
BASE_URLS="$URLS" LIVES=$LIVES SCENARIO="${SCENARIO:-zipf}" VUS=$VUS DURATION=$WARMUP \
  k6 run --quiet --no-summary "$ROOT/scripts/load.js" >/dev/null 2>&1 || true
curl -sf -X POST http://127.0.0.1:8080/reset >/dev/null

echo "[3/4] 본 측정 ${DURATION}"
BASE_URLS="$URLS" LIVES=$LIVES SCENARIO="${SCENARIO:-zipf}" VUS=$VUS DURATION=$DURATION \
  k6 run --summary-export "$OUT/${LABEL}.k6.json" "$ROOT/scripts/load.js" \
  2>&1 | tee "$OUT/${LABEL}.k6.txt" | tail -14

echo "[4/4] 정합성 검증"
curl -s http://127.0.0.1:8080/verify | tee "$OUT/${LABEL}.verify.json"
echo

kill "${PIDS[@]}" 2>/dev/null || true
sleep 1
echo "→ 결과 저장: $OUT/${LABEL}.*"
