#!/usr/bin/env bash
# 페일오버를 일으키고 앱이 언제 새 인스턴스로 넘어가는지 잰다.
#
#   사용법: ./failover.sh <라벨> [JVM 옵션...]
#   예:     ./failover.sh default
#           ./failover.sh ttl0 -Dsun.net.inetaddr.ttl=0
#           ./failover.sh ttl0-life MAX_LIFETIME=15000 -Dsun.net.inetaddr.ttl=0
#
# 타임라인
#   0초   앱 기동, db.internal → A. 0.5초마다 /probe 를 찍는다
#   10초  페일오버: A를 정지하고 DNS 레코드를 B로 바꾼다 (RDS가 하는 일과 같다)
#   ~60초 앱이 언제 B로 넘어가는지 관측
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JAVA_BIN="${JAVA_BIN:-/opt/homebrew/Cellar/openjdk@21/21.0.9/libexec/openjdk.jdk/Contents/Home/bin/java}"
OUT="$ROOT/results"
mkdir -p "$OUT"

LABEL="${1:-default}"; shift || true
ENVS=()
JOPTS=()
for a in "$@"; do
  case "$a" in
    -D*) JOPTS+=("$a") ;;
    *=*) ENVS+=("$a") ;;
  esac
done

# 서버 구분용. A는 1, B는 2로 둔다.
docker exec r02-db-a mysql -uroot -plab -e "SET GLOBAL server_id=1;" 2>/dev/null
docker exec r02-db-b mysql -uroot -plab -e "SET GLOBAL server_id=2;" 2>/dev/null

echo "address=/db.internal/172.31.0.11" > "$ROOT/dnsmasq.address"
cat > "$ROOT/dnsmasq.conf" <<EOF
address=/db.internal/172.31.0.11
local-ttl=5
log-queries
no-resolv
server=1.1.1.1
EOF
docker compose -f "$ROOT/compose.yml" restart dns >/dev/null 2>&1
docker start r02-db-a >/dev/null 2>&1 || true
for _ in $(seq 1 40); do docker exec r02-db-a mysqladmin ping -plab >/dev/null 2>&1 && break; sleep 1; done
docker exec r02-db-a mysql -uroot -plab -e "SET GLOBAL server_id=1;" 2>/dev/null

pkill -f 'probe.jar' 2>/dev/null || true
sleep 1

# 앱은 컨테이너 밖(호스트)에서 돌지만 DNS는 컨테이너 네트워크에 있다.
# 그래서 앱도 같은 네트워크에 넣어 db.internal을 해석할 수 있게 한다.
docker rm -f r02-app >/dev/null 2>&1 || true
# 빈 배열을 "${ARR[@]:-}"로 펼치면 빈 문자열 인자 하나가 생겨 java가 죽는다.
# 원소가 있을 때만 펼친다.
DOCKER_ENV=()
for e in ${ENVS[@]+"${ENVS[@]}"}; do DOCKER_ENV+=(-e "$e"); done
JAVA_ARGS=()
for j in ${JOPTS[@]+"${JOPTS[@]}"}; do JAVA_ARGS+=("$j"); done

docker run -d --name r02-app --network r02-lab --dns 172.31.0.53 \
  -p 18080:8080 -v "$ROOT/app/build/libs:/app:ro" \
  ${DOCKER_ENV[@]+"${DOCKER_ENV[@]}"} \
  eclipse-temurin:21-jre java ${JAVA_ARGS[@]+"${JAVA_ARGS[@]}"} -jar /app/probe.jar >/dev/null

READY=0
for _ in $(seq 1 60); do
  curl -sf http://127.0.0.1:18080/probe >/dev/null 2>&1 && { READY=1; break; }
  sleep 1
done
if [ "$READY" != "1" ]; then
  echo "앱이 뜨지 않았다. 측정을 중단한다." >&2
  docker logs r02-app 2>&1 | tail -15 >&2
  docker rm -f r02-app >/dev/null 2>&1
  exit 1
fi
echo "[$(date '+%H:%M:%S')] 앱 기동 완료 ($LABEL)"
docker logs r02-app 2>&1 | grep "networkaddress.cache" | tee "$OUT/$LABEL-jvm.txt"

: > "$OUT/$LABEL.jsonl"
( for _ in $(seq 1 120); do
    echo "$(date +%s.%N) $(curl -s --max-time 4 http://127.0.0.1:18080/probe 2>/dev/null)" >> "$OUT/$LABEL.jsonl"
    sleep 0.5
  done ) &
POLL=$!

sleep 10
T_FO=$(date +%s.%N)
echo "$T_FO" > "$OUT/$LABEL-failover-ts.txt"
echo "[$(date '+%H:%M:%S')] 페일오버: A 정지 + DNS를 B로 교체"
docker stop r02-db-a >/dev/null
sed -i '' 's|/db.internal/172.31.0.11|/db.internal/172.31.0.12|' "$ROOT/dnsmasq.conf"
docker compose -f "$ROOT/compose.yml" restart dns >/dev/null 2>&1

wait $POLL
docker logs r02-app > "$OUT/$LABEL-app.log" 2>&1 || true
docker rm -f r02-app >/dev/null 2>&1 || true
echo "[$(date '+%H:%M:%S')] 측정 종료 → $OUT/$LABEL.jsonl"
