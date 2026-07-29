#!/usr/bin/env bash
# 풀 안의 커넥션이 세 리플리카에 어떻게 나뉘는지 시간에 따라 관측한다.
#
#   사용법: ./run.sh <라벨> [환경변수...]
#   예:     ./run.sh short   MAXLIFE=30000
#           ./run.sh long    MAXLIFE=600000
#
# maxLifetime이 짧으면 풀 전체가 자주 재생성된다. 그때마다 분포가 다시 뽑히는데,
# 재생성이 뭉쳐서 일어나면 그 순간의 DNS 응답에 몰릴 수 있다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"
mkdir -p "$OUT"
LABEL="${1:-default}"; shift || true

ENVS=()
for a in "$@"; do ENVS+=(-e "$a"); done

docker rm -f r03-app >/dev/null 2>&1 || true
docker run -d --name r03-app --network r03-lab --dns 172.32.0.53 \
  -p 18081:8080 -v "$ROOT/app/build/libs:/app:ro" \
  ${ENVS[@]+"${ENVS[@]}"} \
  eclipse-temurin:21-jre java -jar /app/skew.jar >/dev/null

READY=0
for _ in $(seq 1 60); do
  curl -sf http://127.0.0.1:18081/one >/dev/null 2>&1 && { READY=1; break; }
  sleep 1
done
[ "$READY" = "1" ] || { echo "앱이 뜨지 않았다" >&2; docker logs r03-app 2>&1 | tail -10 >&2; exit 1; }
echo "[$(date '+%H:%M:%S')] 앱 기동 ($LABEL)"

# 같은 커넥션이 쿼리마다 인스턴스를 바꾸는지 먼저 확인한다.
echo "  같은 풀에서 20번 조회: $(for _ in $(seq 1 20); do curl -s http://127.0.0.1:18081/one | sed -n 's/.*"server_id":"\([0-9]*\)".*/\1/p'; done | sort | uniq -c | tr '\n' ' ')"

: > "$OUT/$LABEL.jsonl"
for i in $(seq 1 40); do
  echo "$(date +%s.%N) $(curl -s --max-time 5 http://127.0.0.1:18081/distribution)" >> "$OUT/$LABEL.jsonl"
  sleep 3
done
docker logs r03-app > "$OUT/$LABEL-app.log" 2>&1 || true
docker rm -f r03-app >/dev/null 2>&1 || true
echo "[$(date '+%H:%M:%S')] 측정 종료 → $OUT/$LABEL.jsonl"
