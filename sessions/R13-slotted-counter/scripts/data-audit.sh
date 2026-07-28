#!/usr/bin/env bash
# 부하가 실제로 넣은 데이터를 감사한다.
#
# "Zipf로 쏠리게 했다", "소액 95% 고액 5%"는 부하 스크립트의 의도다.
# 의도대로 들어갔는지는 원장을 집계해 봐야 안다. 여기서 새로  60초를 채우고
# sponsor_log를 그대로 덤프해 분포 검증의 입력으로 남긴다.
#
# 주의: 측정이 도는 중에 실행하면 안 된다. 측정이 끝난 뒤에만 돌린다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JAVA_BIN="${JAVA_BIN:-/opt/homebrew/Cellar/openjdk@21/21.0.9/libexec/openjdk.jdk/Contents/Home/bin/java}"
OUT="$ROOT/results/data-audit"
mkdir -p "$OUT"

SEED="${SEED:-60s}"
LIVES="${LIVES:-1000}"

pkill -f 'sponsor-api.jar' 2>/dev/null || true
sleep 1

# 카운터 전략은 원장 내용과 무관하다. 표본을 많이 쌓으려고 빠른 slot 모드를 쓴다.
MODE=slot COUNTER_SLOTS=16 LIVES=$LIVES \
  "$JAVA_BIN" -Xms1g -Xmx1g -XX:+UseG1GC \
  -jar "$ROOT/app/build/libs/sponsor-api.jar" > "$OUT/app.log" 2>&1 &
APP_PID=$!
trap 'kill $APP_PID 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
  curl -sf -X POST http://127.0.0.1:8080/reset >/dev/null 2>&1 && break
  sleep 1
done

echo "[1/3] 데이터 적재 ${SEED}"
LIVES=$LIVES SCENARIO=zipf VUS=100 DURATION=$SEED \
  k6 run --quiet --no-summary "$ROOT/scripts/load.js" > "$OUT/seed.k6.txt" 2>&1 || true

echo "[2/3] 원장 집계 덤프"
Q() { docker exec r13-mysql mysql -uroot -plab spoon -N -B -e "$1"; }

# 방송별 건수·금액. 순위-빈도 그래프의 입력이다.
Q "SELECT live_id, COUNT(*), SUM(amount) FROM sponsor_log GROUP BY live_id ORDER BY COUNT(*) DESC" \
  > "$OUT/per-live.tsv"
# 금액값별 건수. 소액·고액 비중 검증의 입력이다.
Q "SELECT amount, COUNT(*) FROM sponsor_log GROUP BY amount ORDER BY amount" \
  > "$OUT/per-amount.tsv"
# 초 단위 유입량. 부하가 측정 구간 내내 고르게 들어갔는지 본다.
Q "SELECT DATE_FORMAT(created_at, '%H:%i:%s'), COUNT(*) FROM sponsor_log GROUP BY 1 ORDER BY 1" \
  > "$OUT/per-second.tsv"
# 전체 요약
Q "SELECT COUNT(*), COUNT(DISTINCT live_id), COUNT(DISTINCT user_id), SUM(amount), MIN(amount), MAX(amount) FROM sponsor_log" \
  > "$OUT/summary.tsv"

echo "[3/3] 완료"
wc -l "$OUT"/*.tsv
kill $APP_PID 2>/dev/null || true
sleep 1
