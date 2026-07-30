#!/usr/bin/env bash
# 프라이머리 매트릭스 6조건. repeat-runs.sh가 회차마다 이걸 부른다.
#
# 회차 사이에 대기를 둔다. B01 반복에서 앞 회차의 부하가 남은 상태로 다음 회차가
# 시작해(load average 3.71 → 11.26) 편차에 그 몫이 섞였다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
boot() {
  SUBTRANS_BUFFERS="$1" docker compose -f "$ROOT/compose.yml" up -d --force-recreate >/dev/null 2>&1
  for _ in $(seq 1 90); do docker exec a19-standby psql -U postgres -d spoon -qAt -c "SELECT 1" 2>/dev/null | grep -q 1 && break; sleep 2; done
  docker exec a19-primary psql -U postgres -d spoon -qAt -c "SELECT 1" 2>/dev/null | grep -q 1 || {
    echo "중단: 프라이머리가 쿼리를 받지 못합니다." >&2; exit 2; }
  docker exec -i a19-primary psql -U postgres -d spoon -q < "$ROOT/schema.sql" 2>&1 | grep -v NOTICE || true
  echo "[$(date '+%H:%M:%S')] 기동: subtransaction_buffers=$(docker exec a19-primary psql -U postgres -qAt -c 'SHOW subtransaction_buffers')"
}
# 부하가 가라앉을 때까지 기다린다. 코어 수의 절반 아래로 내려가면 시작한다.
settle() {
  local half=$(( $(sysctl -n hw.ncpu 2>/dev/null || nproc) / 2 ))
  for _ in $(seq 1 30); do
    L=$(uptime | sed -E 's/.*averages?: *([0-9.]+).*/\1/')
    awk -v l="$L" -v h="$half" 'BEGIN{exit !(l+0 < h+0)}' && return 0
    sleep 10
  done
}
settle
boot 32
for c in "none:0" "sub64:64" "sub10k:10000" "sub500k:500000"; do
  bash "$ROOT/scripts/run-primary.sh" "${c%%:*}" "${c##*:}" 64 20
done
boot 512
for c in "none-buf:0" "sub500k-buf:500000"; do
  bash "$ROOT/scripts/run-primary.sh" "${c%%:*}" "${c##*:}" 64 20
done
