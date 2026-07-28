#!/usr/bin/env bash
# 세션 전체를 한 번에 다시 잰다. 모든 수치가 같은 바이너리, 같은 환경에서 나오도록 순서를 고정한다.
#
# 표 하나에 서로 다른 빌드의 수치가 섞이면 "같은 조건에서 쟀나"라는 질문에 답할 수 없다.
# 그래서 앱을 먼저 빌드하고, 그 뒤로는 빌드하지 않는다.
#
#   1) zipf 시나리오 9변형 3회
#   2) hotspot 시나리오 7변형 2회
#   3) 읽기 비용 3변형
#   4) 다중 인스턴스 4조합
#   5) Redis 장애와 원장 복구
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== 0. 빌드 =="
./scripts/build.sh || exit 1

echo
echo "== 1. zipf 9변형 x 3회 =="
rm -rf results/zipf
REPEAT=3 SCENARIO=zipf bash ./scripts/repeat.sh

echo
echo "== 2. hotspot 7변형 x 2회 =="
rm -rf results/hotspot
HOT=(
  "jpa-naive:0:jpa-naive"
  "jvm-lock:0:jvm-lock"
  "jpa-pessimistic:0:jpa-pessimistic"
  "atomic:0:atomic"
  "slot:16:slot16"
  "slot:64:slot64"
  "redis-pipe:0:redis-pipe"
)
for i in 1 2; do
  for spec in "${HOT[@]}"; do
    IFS=: read -r mode slots label <<< "$spec"
    ./scripts/run.sh "$mode" "$slots" hotspot "${label}-r${i}" >/dev/null 2>&1 \
      && echo "완료 hotspot/${label} 회차${i}" || echo "실패 hotspot/${label} 회차${i}"
  done
done

echo
echo "== 3. 커넥션 풀 없는 파이프라인 =="
SPRING_DATA_REDIS_LETTUCE_POOL_ENABLED=false \
  ./scripts/run.sh redis-pipe 0 zipf redis-pipe-nopool >/dev/null 2>&1 \
  && echo "완료 redis-pipe-nopool" || echo "실패 redis-pipe-nopool"

echo
echo "== 4. 읽기 비용 =="
rm -rf results/read
READ=(
  "atomic:0:single-row"
  "slot:16:slot16"
  "slot:64:slot64"
)
for spec in "${READ[@]}"; do
  IFS=: read -r mode slots label <<< "$spec"
  ./scripts/run-read.sh "$mode" "$slots" "$label" >/dev/null 2>&1 \
    && echo "완료 read/${label}" || echo "실패 read/${label}"
done

echo
echo "== 5. 다중 인스턴스 =="
rm -rf results/multi
MULTI=(
  "jvm-lock:0:1:jvm-lock-x1"
  "jvm-lock:0:2:jvm-lock-x2"
  "jpa-naive:0:2:jpa-naive-x2"
  "atomic:0:2:atomic-x2"
)
for spec in "${MULTI[@]}"; do
  IFS=: read -r mode slots n label <<< "$spec"
  ./scripts/run-multi.sh "$mode" "$slots" "$n" "$label" >/dev/null 2>&1 \
    && echo "완료 multi/${label}" || echo "실패 multi/${label}"
done

echo
echo "== 6. Redis 장애와 원장 복구 =="
rm -rf results/failure
./scripts/run-redis-failure.sh redis-kill >/dev/null 2>&1 \
  && echo "완료 failure/redis-kill" || echo "실패 failure/redis-kill"

echo
echo "전체 측정 종료: $(date '+%Y-%m-%d %H:%M:%S')"
