#!/usr/bin/env bash
# 추가 실험: 단발 스캔(2.7초)은 오염 창이 짧아 지연 피해가 거의 없었다.
# 정산 배치가 쿼리 여러 개를 연달아 돌리는 상황을 흉내 내 60초간 스캔을 반복한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/../../.venv/bin/python"
OUT="$ROOT/results"
SQL() { docker exec r16-mysql mysql -uroot -plab spoon -e "$1" 2>/dev/null; }

run_case() {
  local name="$1" obt="$2"
  echo "== 지속 스캔 $name (old_blocks_time=$obt) $(date '+%H:%M:%S') =="
  SQL "SET GLOBAL innodb_old_blocks_time = $obt;"
  SQL "SELECT COUNT(*), SUM(amount) FROM orders_hot;" >/dev/null   # 예열
  sleep 3
  "$PY" "$ROOT/scripts/workload.py" 240 "$OUT/$name-lat.csv" "$OUT/$name-bp.csv" &
  local W=$!
  sleep 60
  date +%s.%N > "$OUT/$name-batch-start.txt"
  END=$(( $(date +%s) + 60 ))
  N=0
  while [ "$(date +%s)" -lt "$END" ]; do
    SQL "SELECT COUNT(*), SUM(amount), SUM(fee) FROM settlement_history;" >/dev/null
    N=$((N+1))
  done
  date +%s.%N > "$OUT/$name-batch-done.txt"
  echo "스캔 ${N}회 반복"
  wait $W
}

run_case sustained-off 0
run_case sustained-default 1000
SQL "SET GLOBAL innodb_old_blocks_time = 1000;"
echo "지속 스캔 실험 종료"
