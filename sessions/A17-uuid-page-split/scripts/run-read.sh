#!/usr/bin/env bash
# 조건마다 깨끗하게 적재한 뒤 조회와 페이지 충전율을 잰다.
# bench.py 가 만든 테이블에 read-bench.py 를 이어 붙인다. 볼륨을 지우고 시작하므로
# 앞 조건의 페이지가 버퍼 풀에 남아 결과를 흐리는 일이 없다.
set -euo pipefail
cd "$(dirname "$0")/.."
ROWS=${1:-1200000}; shift || true
ARMS=${@:-seq uuid7_bin uuid7_counter uuid4_bin uuid4_char}
for arm in $ARMS; do
  echo "=============== ${arm} / ${ROWS}행 ==============="
  docker compose down -v >/dev/null 2>&1 || true
  docker compose up -d --wait mysql
  docker compose run --rm load python bench.py --arm "$arm" --rows "$ROWS" --chunk 100000 \
    --out "/results/read-load-${arm}.json" >/dev/null
  docker compose run --rm load python read-bench.py --arm "$arm" --rows "$ROWS" \
    --out "/results/read-${arm}.json"
done
