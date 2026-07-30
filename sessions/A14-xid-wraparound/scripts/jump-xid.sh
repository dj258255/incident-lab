#!/usr/bin/env bash
# XID 카운터를 지정한 값으로 점프시킨다.
#
#   사용법: ./jump-xid.sh <다음_XID>
#
# 32비트 XID는 21억 개다. 부하로 태우면 초당 5만 개여도 정지 지점까지 12시간이다.
# pg_resetwal -x는 카운터만 옮기고 datfrozenxid는 건드리지 않으므로
# age(datfrozenxid)가 즉시 커진다. 실제 사고에서 벌어지는 상태와 같다.
#
# pg_resetwal은 깨끗하게 종료된 데이터 디렉터리만 다룬다. 그래서 컨테이너를
# 멈추고, 같은 볼륨을 붙인 임시 컨테이너에서 실행한 뒤 다시 띄운다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$1"
# oldestXid를 함께 지정하지 않으면 pg_resetwal이 nextXid - 20억으로 강제한다.
# 그 간격은 정지 임계(2^31 - 300만)에 못 미치므로, 그대로 두면 절대 멈추지 않는다.
# pg_resetwal이 사용자를 정지 상태에 빠뜨리지 않으려고 일부러 그렇게 한다.
OLDEST="${2:-731}"
VOL="$(basename "$ROOT" | tr '[:upper:]' '[:lower:]')_a14data"
# compose가 만든 볼륨 이름을 직접 찾는다. 디렉터리 이름 규칙에 의존하지 않는다.
VOL="$(docker volume ls --format '{{.Name}}' | grep -m1 'a14data')"

docker compose -f "$ROOT/compose.yml" stop >/dev/null 2>&1
docker run --rm -u postgres -v "$VOL:/var/lib/postgresql/data" postgres:17.5 \
  pg_resetwal -x "$TARGET" -u "$OLDEST" -D /var/lib/postgresql/data 2>&1 | sed 's/^/  /'

# 점프한 구간의 clog 세그먼트를 만들어 준다. 없으면 이 로그를 남기고 안 뜬다.
#   FATAL: could not access status of transaction <XID>
#   DETAIL: Could not open file "pg_xact/0773": No such file or directory.
#
# 8KB 페이지에 트랜잭션 상태가 2비트씩 32,768개 들어가고 SLRU 세그먼트는 32페이지라
# 세그먼트당 1,048,576개다. 세그먼트 이름은 XID / 1048576 을 16진수 네 자리로 쓴다.
# 0으로 채우면 그 구간이 전부 진행 중 상태가 되는데, 새로 발급되는 XID는
# 커밋될 때 자기 자리를 덮어쓰므로 랩 용도로는 문제가 없다.
SEG=$(printf '%04X' $((TARGET / 1048576)))
NEXT=$(printf '%04X' $((TARGET / 1048576 + 1)))
docker run --rm -u postgres -v "$VOL:/var/lib/postgresql/data" postgres:17.5 \
  bash -c "cd /var/lib/postgresql/data/pg_xact && for s in $SEG $NEXT; do
             [ -f \$s ] || dd if=/dev/zero of=\$s bs=8192 count=32 status=none; done; ls -la $SEG"
docker compose -f "$ROOT/compose.yml" start >/dev/null 2>&1
for _ in $(seq 1 60); do docker exec a14-pg pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
