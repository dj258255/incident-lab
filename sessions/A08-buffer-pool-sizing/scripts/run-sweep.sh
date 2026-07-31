#!/usr/bin/env bash
# 실험 1: 크기축 스윕.
# 버퍼 풀만 128M에서 2G까지 바꿔 가며 같은 부하를 건다. 접근 분포는 두 가지다.
#   uniform  전체 id를 균등하게 조회. 워킹셋 = 테이블 전체
#   hot      조회의 95%가 id 하위 25%로. 워킹셋 = 테이블의 25%(약 356MB)
#            비율은 workload.py의 --hot-prob 0.95, --hot-frac 0.25 기본값이고 이 스크립트는
#            그 값을 덮어쓰지 않는다.
# 같은 데이터, 같은 부하인데 분포만 다르면 곡선이 어떻게 갈리는지가 이 실험의 질문이다.
#
# 조건마다 컨테이너를 새로 띄운다. 다만 이것으로 콜드에서 출발하지는 않는다. workload.py가
# 임포트 시점에 COUNT(*)로 클러스터드 인덱스(1424MB)를 통째로 훑기 때문에, 워밍업은 풀 스캔
# 직후 상태에서 시작한다. 큰 풀 조건의 100%/0페이지는 그 스캔이 만들어 준 값이다.
set -euo pipefail
cd "$(dirname "$0")/.."

SIZES=${SIZES:-"128M 256M 512M 1G 1536M 2G"}
DISTS=${DISTS:-"uniform hot"}
# 반복 측정용 접두어. 회차마다 파일 이름을 처음부터 다르게 쓴다.
#
# 원래는 회차가 끝난 뒤 sweep-*.json 을 run<N>-* 로 옮기는 방식이었는데,
# 3회 반복에서 run2 의 hot-2G 파일이 run3 의 내용으로 덮인 채 run2 이름을 달고
# 있었다(실행 로그와 전수 대조해 발견). 원인은 짚지 못했고, 사후에 이름을 바꾸는
# 방식 자체를 없앤다. 로그와 파일이 어긋나면 로그가 원본이다.
PREFIX=${OUT_PREFIX:-}
WARMUP=${WARMUP:-30}
DURATION=${DURATION:-60}

for sz in $SIZES; do
  for dist in $DISTS; do
    echo "=============== 버퍼 풀 ${sz} / ${dist} ==============="
    BP_SIZE=$sz docker compose down >/dev/null 2>&1 || true
    BP_SIZE=$sz docker compose up -d --wait mysql
    BP_SIZE=$sz docker compose run --rm load python workload.py \
      --dist "$dist" --warmup "$WARMUP" --duration "$DURATION" \
      --label "${dist}-${sz}" \
      --out "/results/${PREFIX}sweep-${dist}-${sz}.json"
  done
done

echo "스윕 완료"
