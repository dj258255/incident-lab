#!/usr/bin/env bash
# 풀을 24로 올리는 해소책의 대가를 잰다.
#
# 해소책은 인스턴스 하나를 기준으로 계산된 값이다. 인스턴스를 늘리면 DB 커넥션이
# 인스턴스 수만큼 곱해지고, 어느 지점에서 max_connections가 새 상한이 된다.
# 그 상한이 실제로 어디인지, 그리고 넘으면 무엇이 보이는지를 본다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
N="${1:-3}"; POOL="${2:-24}"; MAXCONN="${3:-}"
# 8080번대는 이 호스트에서 다른 컨테이너가 쓰고 있어 충돌한다. 실패가 조용히 지나가지
# 않게 기동 확인을 넣었지만, 애초에 비어 있는 대역을 쓰는 편이 낫다.
BASE_PORT="${BASE_PORT:-8090}"
MQ(){ docker exec b01-mysql mysql -uroot -plab spoon -N -e "$1" 2>/dev/null; }

if [ -n "$MAXCONN" ]; then
  MQ "SET GLOBAL max_connections = $MAXCONN" >/dev/null
  echo "max_connections=$MAXCONN 로 낮춤. 풀 $POOL x $N = $((POOL * N)) 이므로 상한에 닿는다"
fi

for i in $(seq 1 "$N"); do docker rm -f "b01-app$i" >/dev/null 2>&1; done
sleep 3
BASE=$(MQ "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Threads_connected'")
echo "앱 없을 때 기준 접속 = ${BASE:-?}"
UP=0
for i in $(seq 1 "$N"); do
  docker run -d --name "b01-app$i" --network b01-lab -p "$((BASE_PORT + i)):8080" \
    -e DB_HOST=b01-mysql -e DB_PORT=3306 -e POOL="$POOL" \
    -v "$ROOT/app/build/libs:/app:ro" eclipse-temurin:21-jre java -jar /app/pool.jar >/dev/null
  # 각 인스턴스가 실제로 붙었는지 확인한다. 안 붙으면 그 자리에서 알아야 한다.
  ok=0
  for _ in $(seq 1 60); do curl -sf "http://127.0.0.1:$((BASE_PORT + i))/pool" >/dev/null 2>&1 && { ok=1; break; }; sleep 1; done
  if [ "$ok" = "1" ]; then UP=$((UP + 1)); else echo "  인스턴스 $i 기동 실패"; fi
  NOW=$(MQ "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Threads_connected'")
  printf '  인스턴스 %d대 → 접속 %s (기준 제외 %s)  풀 %s x %d = %s 기대\n' \
    "$i" "${NOW:-?}" "$((${NOW:-0} - ${BASE:-0}))" "$POOL" "$i" "$((POOL * i))"
done

echo
echo "max_connections=$(MQ 'SELECT @@max_connections')  실제 접속=$(MQ "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Threads_connected'")  기동 성공=$UP/$N"
echo "누적 최대 접속=$(MQ "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Max_used_connections'")"
echo "거부된 접속(Aborted_connects)=$(MQ "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Aborted_connects'")"
for i in $(seq 1 "$N"); do
  L=$(docker logs "b01-app$i" 2>&1 | grep -cE "Too many connections|Data source rejected" || true)
  [ "$L" != "0" ] && echo "  인스턴스 $i 로그에 접속 거부 $L건"
done
