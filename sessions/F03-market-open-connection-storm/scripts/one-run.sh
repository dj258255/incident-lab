#!/usr/bin/env bash
# 한 조건을 재는 스크립트. 조건마다 컨테이너를 새로 띄워 앱 로그와 계측 카운터를 깨끗하게 갈라 둔다.
#
#   usage: scripts/one-run.sh <라벨> <buggy|fixed>
#   env  : TOMCAT_MAX_THREADS(기본 200) VUS RATE RAMP HOLD DOWN
#
# 남기는 파일(results/raw/<라벨>-*)
#   -load.txt   측정 직전 uptime. 이 호스트는 다른 작업과 코어를 나눠 쓰므로 필수 기록이다
#   -k6.txt     k6 요약 전문(상태코드별 지연 Trend 포함)
#   -stats.txt  앱이 잰 계층별 시간과 100ms 간격 큐 길이
#   -app.log    앱 로그 전문. 발췌가 아니라 docker logs 원문이다
set -euo pipefail

LABEL="${1:?라벨을 주세요}"
ROUTE="${2:?buggy 또는 fixed}"

cd "$(dirname "$0")/.."
OUT="results/raw"
mkdir -p "$OUT"

export TOMCAT_MAX_THREADS="${TOMCAT_MAX_THREADS:-200}"
RATE="${RATE:-400}"
VUS="${VUS:-2600}"
RAMP="${RAMP:-5s}"
HOLD="${HOLD:-20s}"
DOWN="${DOWN:-5s}"

echo "== [$LABEL] route=$ROUTE threads=$TOMCAT_MAX_THREADS rate=$RATE vus=$VUS ramp=$RAMP hold=$HOLD down=$DOWN"

docker compose down -v >/dev/null 2>&1 || true
docker compose up -d >/dev/null

# 기동 대기. 관측용 포트 18083은 부하 경로가 아니다.
for _ in $(seq 1 90); do
  if curl -fsS --max-time 2 http://127.0.0.1:18083/health >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS --max-time 5 http://127.0.0.1:18083/health >/dev/null

NET="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' lab-f03-app)"

# 측정 직전 로드. 이 호스트는 2코어인데 상주 프로세스와 다른 작업이 코어를 나눠 쓰므로
# 이 값 없이는 지연 수치를 읽을 수 없다. 부하 테스트 세션에서는 필수 기록이다.
{
  echo "# [$LABEL] 측정 직전 호스트 상태"
  date -Is
  uptime
  uname -srm; echo "nproc=$(nproc)"; free -g | sed -n '1,2p'
  echo "-- CPU 상위 5 --"
  top -bn1 | sed -n '8,12p'
  echo "route=$ROUTE TOMCAT_MAX_THREADS=$TOMCAT_MAX_THREADS RATE=$RATE VUS=$VUS PREVUS=${PREVUS:-$VUS} RAMP=$RAMP HOLD=$HOLD DOWN=$DOWN"
} | tee "$OUT/$LABEL-load.txt"

docker run --rm --network "$NET" \
  -e TARGET="http://app:8080/quote/$ROUTE" \
  -e RATE="$RATE" -e VUS="$VUS" -e PREVUS="${PREVUS:-$VUS}" -e RAMP="$RAMP" -e HOLD="$HOLD" -e DOWN="$DOWN" \
  -v "$PWD/scripts":/scripts \
  grafana/k6 run /scripts/spike.js > "$OUT/$LABEL-k6.txt" 2>&1 || true

{
  echo "# [$LABEL] route=$ROUTE TOMCAT_MAX_THREADS=$TOMCAT_MAX_THREADS RATE=$RATE VUS=$VUS PREVUS=${PREVUS:-$VUS} RAMP=$RAMP HOLD=$HOLD DOWN=$DOWN"
  curl -fsS --max-time 30 http://127.0.0.1:18083/stats
} > "$OUT/$LABEL-stats.txt" 2>&1 || true

docker logs lab-f03-app > "$OUT/$LABEL-app.log" 2>&1

{
  echo "# [$LABEL] 측정 직후 호스트 상태"
  date -Is
  uptime
} >> "$OUT/$LABEL-load.txt"

docker compose down -v >/dev/null 2>&1 || true

echo "-- [$LABEL] 앱 로그에서 센 HikariCP 획득 타임아웃"
grep -c "Connection is not available" "$OUT/$LABEL-app.log" || true
echo "-- [$LABEL] k6 상태코드별 건수"
grep -E "^\s+cnt_(200|500|503|noresp|other)" "$OUT/$LABEL-k6.txt" || true
grep -E "dropped_iterations|http_reqs" "$OUT/$LABEL-k6.txt" || true
