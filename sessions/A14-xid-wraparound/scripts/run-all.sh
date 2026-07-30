#!/usr/bin/env bash
# repeat-runs.sh가 회차마다 부르는 진입점. 시드 후 본 측정을 돌린다.
#
# 이 세션의 수치 대부분은 상수에서 계산되어 편차가 없다(경고 임계, 정지 임계, 랩 임계).
# 반복이 필요한 것은 자가 복구 시간 하나다. autovacuum_naptime 기본값이 60초이고
# 이 세션의 샘플링 간격이 20초라, 원인을 제거한 시점이 naptime 주기의 어디였는지에
# 따라 값이 흔들린다. 한 번 재고 "40초"라고 적으면 안 되는 수치다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for _ in $(seq 1 90); do
  docker exec a14-pg psql -U postgres -d spoon -qAt -c "SELECT 1" 2>/dev/null | grep -q 1 && break
  sleep 2
done
docker exec a14-pg psql -U postgres -d spoon -qAt -c "SELECT 1" 2>/dev/null | grep -q 1 || {
  echo "중단: spoon 데이터베이스가 쿼리를 받지 못합니다." >&2; exit 2; }
docker exec -i a14-pg psql -U postgres -d spoon -q < "$ROOT/schema.sql" 2>&1 | grep -v NOTICE || true
bash "$ROOT/scripts/run.sh"
