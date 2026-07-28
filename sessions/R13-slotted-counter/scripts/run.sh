#!/usr/bin/env bash
# 변형 하나를 측정한다.
#   사용법: ./run.sh <mode> <slots> <scenario> <label>
#   예:     ./run.sh single 0  zipf    single
#           ./run.sh slot   16 zipf    slot16
#           ./run.sh redis  0  hotspot redis
#
# 순서: 앱 기동 → 초기화 → 워밍업 → 초기화 → 지표 스냅샷 → 본 측정 → 지표 스냅샷 → 정합성 검증
# 워밍업을 넣는 이유는 첫 실행에서 버퍼 풀이 비어 있어 변형 간 비교가 왜곡되기 때문이다.
set -euo pipefail

MODE="${1:-single}"
SLOTS="${2:-16}"
SCENARIO="${3:-zipf}"
LABEL="${4:-$MODE}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JAVA_BIN="${JAVA_BIN:-/opt/homebrew/Cellar/openjdk@21/21.0.9/libexec/openjdk.jdk/Contents/Home/bin/java}"
OUT="$ROOT/results/${SCENARIO}"
mkdir -p "$OUT"

VUS="${VUS:-100}"
DURATION="${DURATION:-60s}"
WARMUP="${WARMUP:-20s}"   # JIT 컴파일과 커넥션 풀 예열까지 감안한 값
LIVES="${LIVES:-1000}"

mysql_status() {
  docker exec r13-mysql mysql -uroot -plab -N -B -e \
    "SHOW GLOBAL STATUS WHERE Variable_name IN
     ('Innodb_row_lock_waits','Innodb_row_lock_time','Innodb_row_lock_time_max','Innodb_row_lock_current_waits');" 2>/dev/null
}

deadlock_count() {
  docker logs r13-mysql 2>&1 | grep -c "TRANSACTION.*DEADLOCK\|LATEST DETECTED DEADLOCK" || true
}

echo "=============================================================="
echo " 변형: $LABEL (mode=$MODE slots=$SLOTS scenario=$SCENARIO)"
echo " 부하: VU=$VUS duration=$DURATION lives=$LIVES"
echo "=============================================================="

pkill -f 'sponsor-api.jar' 2>/dev/null || true
sleep 1

# 힙을 고정한다. 변형마다 힙이 달라지면 GC 동작이 달라져 비교가 흔들린다.
MODE="$MODE" COUNTER_SLOTS="$SLOTS" LIVES="$LIVES" \
  "$JAVA_BIN" -Xms1g -Xmx1g -XX:+UseG1GC \
  -jar "$ROOT/app/build/libs/sponsor-api.jar" > "$OUT/${LABEL}.app.log" 2>&1 &
APP_PID=$!
trap 'kill $APP_PID 2>/dev/null || true' EXIT

READY=0
for _ in $(seq 1 60); do
  if curl -sf -X POST http://127.0.0.1:8080/reset >/dev/null 2>&1; then READY=1; break; fi
  sleep 1
done
if [ "$READY" != "1" ]; then
  echo "앱이 응답하지 않는다. 측정을 중단한다." >&2
  cat "$OUT/${LABEL}.app.log" >&2
  exit 1
fi
# 실제로 한 건이 성공하는지 확인한다. 여기서 막지 않으면 전량 실패한 측정이 결과처럼 남는다.
if ! curl -sf -X POST http://127.0.0.1:8080/sponsor -H 'Content-Type: application/json' \
      -d '{"liveId":1,"userId":1,"amount":100}' >/dev/null 2>&1; then
  echo "후원 요청이 실패한다. 모드 설정을 확인하라." >&2
  cat "$OUT/${LABEL}.app.log" >&2
  exit 1
fi
curl -sf -X POST http://127.0.0.1:8080/reset >/dev/null
echo "[1/5] 앱 기동·초기화 완료 (pid=$APP_PID)"

echo "[2/5] 워밍업 ${WARMUP}"
LIVES=$LIVES SCENARIO=$SCENARIO VUS=$VUS DURATION=$WARMUP \
  k6 run --quiet --no-summary "$ROOT/scripts/load.js" >/dev/null 2>&1 || true
curl -sf -X POST http://127.0.0.1:8080/reset >/dev/null

DL_BEFORE=$(deadlock_count)
mysql_status > "$OUT/${LABEL}.lock.before.txt"
echo "[3/5] 지표 스냅샷 완료"

echo "[4/5] 본 측정 ${DURATION}"
LIVES=$LIVES SCENARIO=$SCENARIO VUS=$VUS DURATION=$DURATION \
  k6 run --summary-export "$OUT/${LABEL}.k6.json" "$ROOT/scripts/load.js" \
  2>&1 | tee "$OUT/${LABEL}.k6.txt" | tail -25

mysql_status > "$OUT/${LABEL}.lock.after.txt"
DL_AFTER=$(deadlock_count)

echo "[5/5] 정합성 검증"
curl -s http://127.0.0.1:8080/verify | tee "$OUT/${LABEL}.verify.json"
echo
echo "데드락 로그 증가: $((DL_AFTER - DL_BEFORE))"
echo "$((DL_AFTER - DL_BEFORE))" > "$OUT/${LABEL}.deadlocks.txt"

kill $APP_PID 2>/dev/null || true
sleep 1
echo "→ 결과 저장: $OUT/${LABEL}.*"
