#!/usr/bin/env bash
# 커넥션 풀 데드락을 재현하고 해소를 검증한다.
#
#   사용법: ./run.sh <라벨> <mode:two|one> <풀크기> [환경변수...]
#
# 동시 요청은 20으로 고정한다. 풀이 10일 때 요청 하나가 커넥션 2개를 잡으면
# 10개 요청이 각각 첫 커넥션을 쥔 채 두 번째를 기다리게 되고, 아무도 내놓지 않는다.
# 그 상태에서 무엇이 관측되는지가 이 세션의 대상이다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"
mkdir -p "$OUT"

LABEL="$1"; MODE="$2"; POOL="$3"; shift 3
ENVS=(-e "POOL=$POOL")
for a in "$@"; do ENVS+=(-e "$a"); done

CONCURRENCY="${CONCURRENCY:-20}"
DURATION="${DURATION:-40}"

docker rm -f b01-app >/dev/null 2>&1 || true
# macOS의 Docker Desktop에서는 --network host가 기대대로 동작하지 않는다.
# DB와 같은 브리지 네트워크에 넣고 컨테이너 이름으로 붙인다.
docker run -d --name b01-app --network b01-lab -p 8080:8080 \
  -e DB_HOST=b01-mysql -e DB_PORT=3306 \
  -v "$ROOT/app/build/libs:/app:ro" "${ENVS[@]}" \
  eclipse-temurin:21-jre java -jar /app/pool.jar >/dev/null

READY=0
for _ in $(seq 1 60); do
  curl -sf "http://127.0.0.1:8080/pool" >/dev/null 2>&1 && { READY=1; break; }
  sleep 1
done
[ "$READY" = "1" ] || { echo "앱이 뜨지 않았다" >&2; docker logs b01-app 2>&1 | tail -10 >&2; exit 1; }
echo "[$(date '+%H:%M:%S')] 앱 기동 ($LABEL: mode=$MODE pool=$POOL 동시=$CONCURRENCY)"

# 풀 상태를 0.5초마다 기록한다. 대기 스레드 수가 핵심이다.
( : > "$OUT/$LABEL-pool.jsonl"
  END=$(( $(date +%s) + DURATION + 10 ))
  while [ "$(date +%s)" -lt "$END" ]; do
    echo "$(date +%s.%N) $(curl -s --max-time 3 http://127.0.0.1:8080/pool)" >> "$OUT/$LABEL-pool.jsonl"
    sleep 0.5
  done ) &
MON=$!

# 동시 요청. 각 워커가 순차로 계속 던진다.
: > "$OUT/$LABEL-req.csv"
echo "ts,ms,status" > "$OUT/$LABEL-req.csv"
END=$(( $(date +%s) + DURATION ))
for w in $(seq 1 "$CONCURRENCY"); do
  ( while [ "$(date +%s)" -lt "$END" ]; do
      T0=$(date +%s.%N)
      BODY=$(curl -s --max-time 60 "http://127.0.0.1:8080/sponsor?mode=$MODE" 2>/dev/null)
      T1=$(date +%s.%N)
      ST=$(echo "$BODY" | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p')
      ERR=$(echo "$BODY" | sed -n 's/.*"error":"\([A-Za-z]*\)".*/\1/p')
      echo "$T1,$(echo "($T1 - $T0) * 1000" | bc | cut -d. -f1),${ST:-timeout}${ERR:+:$ERR}" >> "$OUT/$LABEL-req.csv"
    done ) &
done
wait $(jobs -p | grep -v "$MON") 2>/dev/null || true
sleep 2
wait $MON 2>/dev/null || true

docker logs b01-app > "$OUT/$LABEL-app.log" 2>&1 || true
curl -s http://127.0.0.1:8080/pool | tee "$OUT/$LABEL-final.json"
echo
docker rm -f b01-app >/dev/null 2>&1 || true
echo "[$(date '+%H:%M:%S')] 측정 종료 → $OUT/$LABEL-*"
