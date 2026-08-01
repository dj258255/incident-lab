#!/usr/bin/env bash
# run.sh 는 psql 을 직접 부르므로 러너 안에서 돌아야 한다. 호스트에서 실행하면
# 소켓을 못 찾아 첫 줄에서 죽는다.
#
# 그런데 러너는 상주 컨테이너가 아니다. postgres:16-alpine 에 장기 실행 명령이 없어
# 곧 종료되고, 그 컨테이너에 docker exec 로 붙으면 컨테이너가 죽는 순간 exec 도
# 137(SIGKILL)로 끊긴다. 세 회차가 전부 그 모양이었고 OOM 으로 오해했다.
# compose run 으로 매번 새로 띄운다.
set -uo pipefail
D="$(cd "$(dirname "$0")/.." && pwd)"
cd "$D"
docker compose up -d db >/dev/null 2>&1
for _ in $(seq 1 40); do docker exec lab-b43-pg pg_isready -U lab >/dev/null 2>&1 && break; sleep 3; done
docker exec lab-b43-pg pg_isready -U lab >/dev/null 2>&1 || { echo "중단: lab-b43-pg 가 준비되지 않았습니다" >&2; exit 2; }
docker compose run --rm -e ROWS="${ROWS:-3000000}" runner bash /scripts/run.sh "$@"
