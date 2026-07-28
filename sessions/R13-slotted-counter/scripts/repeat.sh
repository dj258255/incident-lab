#!/usr/bin/env bash
# 전 변형을 N회 반복 측정한다.
# 한 번 재고 끝내면 두 변형의 10% 차이가 실제 차이인지 실행 편차인지 구분할 수 없다.
# 실제로 1회차만 봤을 때 원자적 UPDATE와 비관적 락의 순위가 회차마다 뒤집혔다.
#
# 문자열 하나를 for에 넣고 set -- 로 쪼개는 방식은 쓰지 않는다. 그 방식이 인자를
# 분리하지 못해 앱이 알 수 없는 모드를 받고도 측정이 정상처럼 끝난 적이 있다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCENARIO="${SCENARIO:-zipf}"
REPEAT="${REPEAT:-3}"

# mode:slots:label
SPECS=(
  "jpa-naive:0:jpa-naive"
  "jvm-lock:0:jvm-lock"
  "jpa-optimistic:0:jpa-optimistic"
  "jpa-pessimistic:0:jpa-pessimistic"
  "atomic:0:atomic"
  "slot:16:slot16"
  "slot:64:slot64"
  "redis:0:redis"
  "redis-pipe:0:redis-pipe"
)

for i in $(seq 1 "$REPEAT"); do
  for spec in "${SPECS[@]}"; do
    IFS=: read -r mode slots label <<< "$spec"
    if "$ROOT/scripts/run.sh" "$mode" "$slots" "$SCENARIO" "${label}-r${i}" >/dev/null 2>&1; then
      echo "완료 ${label} 회차${i}"
    else
      echo "실패 ${label} 회차${i}"
    fi
  done
done
