#!/usr/bin/env bash
# 조건 하나를 깨끗한 상태에서 잰다.
#
# 볼륨까지 지우고 새로 띄운다. 같은 인스턴스에 앞 조건의 테이블이 남아 있으면 버퍼 풀을
# 나눠 쓰게 되고, 데이터 파일이 이미 커져 있어 파일 확장 비용도 달라진다. 조건 간 비교가
# 목적이므로 매번 같은 출발선에서 시작해야 한다.
#
#   사용법: run-bench.sh <행수> <조건> [조건...]
set -euo pipefail
cd "$(dirname "$0")/.."

ROWS=${1:?행 수를 지정하세요}
shift

for arm in "$@"; do
  echo "=============== ${arm} / ${ROWS}행 ==============="
  docker compose down -v >/dev/null 2>&1 || true
  docker compose up -d --wait mysql
  docker compose run --rm load python bench.py \
    --arm "$arm" --rows "$ROWS" --chunk 100000 \
    --out "/results/bench-${arm}.json"
done

echo "완료: $*"
