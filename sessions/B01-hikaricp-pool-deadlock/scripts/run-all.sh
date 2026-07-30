#!/usr/bin/env bash
# 네 조건을 같은 부하로 잰다.
#   jpa-10   : 우아한형제들 사례 재현. save() 한 번인데 커넥션 2개를 요구, 풀 10
#   jpa-24   : 같은 코드에 풀만 24로. 우형이 실제로 적용한 값
#   two-10   : 커넥션 두 개를 명시적으로 잡는 코드, 풀 10 (원인을 눈으로 보기 위한 대조군)
#   one-10   : 한 번에 하나만 잡도록 고친 코드, 풀 10
#
# 동시 요청은 16으로 둔다. 원문의 컨슈머 스레드 수와 같다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# MySQL이 실제로 쿼리를 받을 때까지 기다린다. 이걸 빼면 첫 조건의 앱이 못 떠서
# run.sh가 "앱이 뜨지 않았다"로 끝나고, 그 실패가 회차 결과에서는 파일 부재로만 보인다.
for _ in $(seq 1 120); do
  docker exec b01-mysql mysql -uroot -plab spoon -N -e "SELECT 1" 2>/dev/null | grep -q 1 && break
  sleep 2
done
docker exec b01-mysql mysql -uroot -plab spoon -N -e "SELECT 1" 2>/dev/null | grep -q 1 || {
  echo "중단: MySQL이 쿼리를 받지 못합니다." >&2; exit 2; }

for spec in "jpa-10:jpa:10" "jpa-24:jpa:24" "two-10:two:10" "one-10:one:10"; do
  IFS=: read -r label mode pool <<< "$spec"
  DURATION="${DURATION:-40}" CONCURRENCY="${CONCURRENCY:-16}" \
    bash "$ROOT/scripts/run.sh" "$label" "$mode" "$pool" HOLD_MS="${HOLD_MS:-50}" 2>&1 | tail -2
done
