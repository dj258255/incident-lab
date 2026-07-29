#!/usr/bin/env bash
# 실험 2: 최적점으로 옮기는 값.
# 실험 1이 "얼마로 잡아야 하는가"를 말해 준다면, 이 실험은 "그 값으로 바꾸는 순간 무슨 일이
# 벌어지는가"를 잰다. 공식 문서가 온라인 리사이즈 중에는 버퍼 풀 접근이 필요한 신규 트랜잭션이
# 리사이즈가 끝날 때까지 기다린다고 적어 두었다. 그 대기가 실제로 얼마인지를 부하 중에 잰다.
#
# 두 방향을 다 잰다. 키우는 쪽과 줄이는 쪽은 하는 일이 다르다.
set -euo pipefail
cd "$(dirname "$0")/.."

WARMUP=${WARMUP:-30}
DURATION=${DURATION:-90}
AT=${AT:-30}

run() {
  local name=$1 start=$2 target=$3
  echo "=============== 리사이즈 ${start} -> ${target} ==============="
  BP_SIZE=$start docker compose down >/dev/null 2>&1 || true
  BP_SIZE=$start docker compose up -d --wait mysql
  BP_SIZE=$start docker compose run --rm load python workload.py \
    --dist hot --warmup "$WARMUP" --duration "$DURATION" \
    --label "$name" \
    --action-at "$AT" \
    --action-sql "SET GLOBAL innodb_buffer_pool_size = $(numfmt --from=iec "$target")" \
    --out "/results/resize-${name}.json" \
    --timeline "/results/resize-${name}-timeline.csv"
}

# 대조군: 같은 부하를 같은 시간 동안 걸되 리사이즈를 하지 않는다.
# 리사이즈 구간의 스파이크가 리사이즈 때문인지 그냥 부하의 요동인지 구분하려면 이게 있어야 한다.
echo "=============== 대조군 (리사이즈 없음, 128M 고정) ==============="
BP_SIZE=128M docker compose down >/dev/null 2>&1 || true
BP_SIZE=128M docker compose up -d --wait mysql
BP_SIZE=128M docker compose run --rm load python workload.py \
  --dist hot --warmup "$WARMUP" --duration "$DURATION" \
  --label "control-128M" \
  --out "/results/resize-control.json" \
  --timeline "/results/resize-control-timeline.csv"

run "grow-128M-to-2G" 128M 2G
run "shrink-2G-to-128M" 2G 128M

echo "리사이즈 실험 완료"
