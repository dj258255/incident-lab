#!/usr/bin/env bash
# 실험 3: 히트율이 같은데 속도가 다른 경우.
# 버퍼 풀에서 miss가 나면 InnoDB는 파일에서 읽는다. 그 읽기가 진짜 디스크로 가는지, 호스트
# 페이지 캐시에서 끝나는지는 innodb_flush_method가 정한다. O_DIRECT면 페이지 캐시를 건너뛰고
# 기본값(fsync)이면 커널이 한 번 더 캐시한다.
#
# 버퍼 풀 지표는 둘을 구분하지 못한다. Innodb_buffer_pool_reads는 "버퍼 풀에 없어서 파일에서
# 읽었다"까지만 세기 때문이다. 그래서 같은 히트율에 다른 지연이 나올 수 있다.
# 같은 풀 크기(256M), 같은 부하로 flush_method만 바꿔 그 차이를 잰다.
#
# 컨테이너 블록 I/O를 측정 창에 맞춰 잰다. 컨테이너 생애 전체로 재면 워밍업과 기동 구간이
# 섞여서 InnoDB가 세는 읽기량과 대조할 수 없다. workload.py의 일정(워밍업 뒤 측정)을 알고
# 있으므로 그 경계에서 두 번 찍는다.
set -euo pipefail
cd "$(dirname "$0")/.."

SIZE=${SIZE:-256M}
WARMUP=${WARMUP:-30}
DURATION=${DURATION:-60}

blkio() { docker stats --no-stream --format '{{.BlockIO}}' a08-mysql; }

for fm in O_DIRECT fsync; do
  echo "=============== flush_method ${fm} / 버퍼 풀 ${SIZE} ==============="
  BP_SIZE=$SIZE FLUSH_METHOD=$fm docker compose down >/dev/null 2>&1 || true
  BP_SIZE=$SIZE FLUSH_METHOD=$fm docker compose up -d --wait mysql

  BP_SIZE=$SIZE FLUSH_METHOD=$fm docker compose run --rm load python workload.py \
    --dist uniform --warmup "$WARMUP" --duration "$DURATION" \
    --label "${fm}-${SIZE}" --out "/results/pagecache-${fm}.json" &
  wpid=$!

  # 워밍업이 끝나는 시점(측정 시작)과 측정이 끝나는 시점에 각각 찍는다.
  # docker stats --no-stream 자체가 1~2초 걸리므로 그만큼 당겨서 잰다.
  sleep $((WARMUP + 6)); blkio > "results/pagecache-${fm}-blkio-t0.txt"
  sleep $((DURATION - 2)); blkio > "results/pagecache-${fm}-blkio-t1.txt"
  wait $wpid

  echo "측정 창 블록 I/O: $(cat results/pagecache-${fm}-blkio-t0.txt) -> $(cat results/pagecache-${fm}-blkio-t1.txt)"
done

echo "페이지 캐시 실험 완료"
