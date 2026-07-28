#!/usr/bin/env bash
# 세 조건에서 같은 실험을 반복한다.
#   실험 공통: OLTP 점조회 240초. 60초 지점에 정산 배치(콜드 테이블 풀 스캔 집계) 시작.
#
#   A) innodb_old_blocks_time=0     : midpoint 방어를 끈 상태 (2011년 이전 기본값과 같은 동작)
#   B) innodb_old_blocks_time=1000  : 8.4 기본값
#   C) innodb_old_blocks_time=1000 + 배치를 점조회와 다른 시간대로 (대조군, 배치 없음)
#
# 조건 간에는 버퍼 풀을 같은 상태로 만들기 위해 핫 테이블 전체를 한 번 훑어 예열한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/../../.venv/bin/python"
OUT="$ROOT/results"
mkdir -p "$OUT"

SQL() { docker exec r16-mysql mysql -uroot -plab spoon -e "$1" 2>/dev/null; }

warm() {
  # 핫 워킹셋을 버퍼 풀에 올린다. 이 예열이 없으면 첫 조건만 콜드 스타트 페널티를 진다.
  SQL "SELECT COUNT(*), SUM(amount) FROM orders_hot;" >/dev/null
  SQL "SELECT COUNT(*) FROM orders_hot WHERE user_id BETWEEN 1 AND 300000;" >/dev/null
}

run_case() {
  local name="$1" obt="$2" with_batch="$3"
  echo "== 조건 $name (old_blocks_time=$obt, 배치=$with_batch) $(date '+%H:%M:%S') =="
  SQL "SET GLOBAL innodb_old_blocks_time = $obt;"
  warm
  sleep 3

  "$PY" "$ROOT/scripts/workload.py" 240 "$OUT/$name-lat.csv" "$OUT/$name-bp.csv" &
  local W=$!
  sleep 60

  if [ "$with_batch" = "yes" ]; then
    date +%s.%N > "$OUT/$name-batch-start.txt"
    SQL "SELECT COUNT(*), SUM(amount), SUM(fee) FROM settlement_history;" > "$OUT/$name-batch-result.txt"
    date +%s.%N > "$OUT/$name-batch-done.txt"
    echo "배치 스캔 종료 $(date '+%H:%M:%S')"
  fi
  wait $W
}

echo "사전 상태" && SQL "SELECT @@innodb_buffer_pool_size/1024/1024/1024 AS bp_gb, @@innodb_old_blocks_pct, @@innodb_old_blocks_time;" | tee "$OUT/pre-state.txt"

run_case defense-off 0 yes
run_case default 1000 yes
run_case no-batch 1000 no

SQL "SET GLOBAL innodb_old_blocks_time = 1000;"
echo "실험 종료 $(date '+%H:%M:%S')"
