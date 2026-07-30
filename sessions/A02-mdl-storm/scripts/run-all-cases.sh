#!/usr/bin/env bash
# 적재부터 네 조건까지 한 번에 돈다. reproduce.md의 절차를 그대로 옮긴 것이다.
# tools/repeat-runs.sh 가 이 파일을 여러 회차 반복해 부른다.
#
# 적재를 반드시 포함해야 한다. mdl.py는 테이블에 데이터가 있다고 가정하고
# randrange(1, 행수)로 조회하므로, 빈 테이블에서는 randrange(1, 1)에서
# ValueError로 죽는다. 회차마다 볼륨을 새로 만드는 반복 측정에서는 이 단계가
# 빠지면 첫 회차만 우연히 성공하고 둘째부터 조용히 깨진다.
set -uo pipefail

echo "=============== 적재 (200만 행, 약 145초) ==============="
docker compose run --rm load python seed.py

ROWS=$(docker exec a02-mysql mysql -uroot -plab -N -e "SELECT COUNT(*) FROM lab.orders" 2>/dev/null | tr -d '[:space:]')
echo "적재 확인: ${ROWS:-0}행"
if [ "${ROWS:-0}" -lt 1000000 ]; then
  echo "중단: 적재가 100만 행에 못 미칩니다. 이 상태로 재면 조회 대상이 없어 결과가 무의미합니다." >&2
  exit 4
fi

for c in control ddl-default ddl-timeout ddl-alone; do
  echo "=============== $c ==============="
  docker compose run --rm load python mdl.py --case "$c" --out "/results/case-$c.json"
done
