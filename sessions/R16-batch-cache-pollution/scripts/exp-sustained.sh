#!/usr/bin/env bash
# 추가 실험: 단발 스캔(2.7초)은 오염 창이 짧아 지연 피해가 거의 없었다.
# 정산 배치가 쿼리 여러 개를 연달아 돌리는 상황을 흉내 내 60초간 스캔을 반복한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/../../.venv/bin/python"
OUT="$ROOT/results"
SQL() { docker exec r16-mysql mysql -uroot -plab spoon -e "$1" 2>/dev/null; }

# 시드가 안 돼 있으면 이 실험 전체가 무의미하다. 실제로 컨테이너를 새로 띄운
# 회차에서 settlement_history 가 1페이지짜리 빈 테이블이었고, "스캔 947회"가
# 빈 테이블을 947번 훑은 값으로 남았다. 크기를 먼저 확인하고 모자라면 멈춘다.
check_seeded() {
  local pages
  pages=$(docker exec r16-mysql mysql -uroot -plab spoon -N -B -e \
    "SELECT COALESCE(ROUND(DATA_LENGTH/16384),0) FROM information_schema.TABLES
     WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='settlement_history'" 2>/dev/null)
  if [ "${pages:-0}" -lt 10000 ]; then
    echo "중단: settlement_history 가 ${pages:-0}페이지입니다. 먼저 시드를 돌리십시오." >&2
    echo "       docker compose run --rm load python seed.py" >&2
    exit 2
  fi
  echo "시드 확인: settlement_history ${pages}페이지"
}
check_seeded

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
  # 반복 횟수를 파일로 남긴다. 화면에만 찍던 탓에 지속 조건의 총 read I/O 를
  # 계산하지 못했다("지속 스캔의 반복 횟수를 남기지 않았습니다"). 테이블 페이지 수를
  # 함께 적어 두면 곱해서 총 read I/O 를 낼 수 있다.
  PAGES=$(docker exec r16-mysql mysql -uroot -plab spoon -N -B -e \
    "SELECT ROUND(DATA_LENGTH/16384) FROM information_schema.TABLES
     WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='settlement_history'" 2>/dev/null)
  {
    echo "scans=${N}"
    echo "table_pages=${PAGES:-0}"
    echo "read_io_estimate=$(( N * ${PAGES:-0} ))"
    echo "window_s=60"
  } > "$OUT/$name-scan-count.txt"
  echo "스캔 ${N}회 반복 (테이블 ${PAGES:-?}페이지, 추정 read I/O $(( N * ${PAGES:-0} ))페이지)"
  wait $W
}

run_case sustained-off 0
run_case sustained-default 1000
SQL "SET GLOBAL innodb_old_blocks_time = 1000;"
echo "지속 스캔 실험 종료"
