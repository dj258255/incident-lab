#!/usr/bin/env bash
# 복제를 붙이고 슬롯 유무에 따라 복제 지연이 어떻게 달라지는지 잰다.
#
# README 의 "못 한 것"에 이렇게 적어 두었다.
#   슬롯을 꺼내는 이유가 원본의 쓰기 처리량을 올리는 것이라서 복제본이 따라가야 할 양도
#   같이 늘어납니다. 그 지연이 실제로 얼마나 벌어지는지는 재지 않았습니다.
#
# 그 가설을 잰다. 두 조건에 같은 부하를 주고 원본 처리량과 복제 지연을 함께 본다.
#   single  단일 행 카운터 (원자 UPDATE)
#   slot64  슬롯 64개
#
# Seconds_Behind_Source 는 초 단위라 이 규모에서 대부분 0 으로 찍힌다. 그래서 판정을
# 그 값에만 걸지 않고 세 가지를 함께 본다.
#   1) 부하가 끝난 직후 복제본의 합계가 원본과 같은가 (같으면 이미 따라잡은 것)
#   2) 따라잡기까지 걸린 시간 (0.05초 간격으로 폴링)
#   3) 원본 binlog 위치와 복제본이 적용한 위치의 차이 (바이트)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
JAVA_BIN="${JAVA_BIN:-/opt/homebrew/Cellar/openjdk@21/21.0.9/libexec/openjdk.jdk/Contents/Home/bin/java}"

S(){ docker exec r13-mysql   mysql -uroot -plab spoon -N -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }
R(){ docker exec r13-replica mysql -uroot -plab spoon -N -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }
RV(){ docker exec r13-replica mysql -uroot -plab       -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }

VUS="${VUS:-100}"
DURATION="${DURATION:-30s}"
LIVES="${LIVES:-1000}"

for _ in $(seq 1 90); do [ "$(S 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(S 'SELECT 1')" = "1" ] || { echo "중단: r13-mysql 이 쿼리를 받지 못합니다" >&2; exit 2; }
for _ in $(seq 1 90); do [ "$(docker exec r13-replica mysql -uroot -plab -N -e 'SELECT 1' 2>/dev/null)" = "1" ] && break; sleep 2; done

setup_replication() {
  # 복제본 스키마를 원본과 맞춘다. GTID 를 쓰므로 덤프로 초기 상태를 맞춘다.
  docker exec r13-replica mysql -uroot -plab -e "STOP REPLICA; RESET REPLICA ALL" >/dev/null 2>&1
  docker exec r13-mysql mysqldump -uroot -plab --single-transaction --set-gtid-purged=ON \
    --databases spoon > /tmp/r13-dump.sql 2>/dev/null
  docker exec -i r13-replica mysql -uroot -plab -e "RESET BINARY LOGS AND GTIDS" >/dev/null 2>&1
  docker exec -i r13-replica mysql -uroot -plab < /tmp/r13-dump.sql 2>/dev/null
  docker exec r13-replica mysql -uroot -plab -e "
    CHANGE REPLICATION SOURCE TO
      SOURCE_HOST='r13-mysql', SOURCE_PORT=3306,
      SOURCE_USER='root', SOURCE_PASSWORD='lab',
      SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1,
      SOURCE_HEARTBEAT_PERIOD=0.5;
    START REPLICA;" 2>&1 | grep -v "^mysql: \[Warning\]"
  for _ in $(seq 1 60); do
    st=$(RV "SHOW REPLICA STATUS\G" | grep -E "Replica_(IO|SQL)_Running:" | awk '{print $2}' | paste -sd, -)
    [ "$st" = "Yes,Yes" ] && { echo "  복제 상태: $st"; return 0; }
    sleep 1
  done
  echo "  복제가 시작되지 않았습니다:" >&2
  RV "SHOW REPLICA STATUS\G" | grep -E "Last_(IO|SQL)_Error|Replica_(IO|SQL)_Running" | sed 's/^/    /' >&2
  return 1
}

# 모드마다 집계 대상 테이블이 다르다. atomic 은 live_counter, slot 은 live_counter_slot 이다.
sum_sql() { # $1=mode
  case "$1" in
    slot) echo "SELECT COALESCE(SUM(total_amount),0) FROM live_counter_slot";;
    *)    echo "SELECT COALESCE(SUM(total_amount),0) FROM live_counter";;
  esac
}

# 복제본이 원본을 따라잡을 때까지 걸린 시간을 잰다.
catch_up() { # $1=목표합계 $2=mode
  local want="$1" q; q=$(sum_sql "$2")
  local t0 now got
  t0=$(date +%s.%N)
  for _ in $(seq 1 1200); do
    got=$(R "$q" 2>/dev/null | head -1)
    [ "${got:-x}" = "$want" ] && { now=$(date +%s.%N); echo "$(echo "$now-$t0" | bc)"; return 0; }
    sleep 0.05
  done
  echo "-1"
}

run_case() { # $1=라벨 $2=mode $3=slots
  local label="$1" mode="$2" slots="$3"
  echo
  echo "## $label (mode=$mode slots=$slots)"
  pkill -f 'sponsor-api.jar' 2>/dev/null || true
  sleep 1
  PORT=8080 MODE="$mode" COUNTER_SLOTS="$slots" LIVES="$LIVES" \
    "$JAVA_BIN" -Xms1g -Xmx1g -XX:+UseG1GC \
    -jar "$ROOT/app/build/libs/sponsor-api.jar" > "$OUT/replica-$label.app.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 90); do curl -sf http://127.0.0.1:8080/verify >/dev/null 2>&1 && break; sleep 1; done
  curl -sf -X POST http://127.0.0.1:8080/reset >/dev/null

  setup_replication || { kill $pid 2>/dev/null; return 1; }

  echo "  부하 ${DURATION} (VU ${VUS})"
  BASE_URLS="http://127.0.0.1:8080" LIVES=$LIVES SCENARIO="${SCENARIO:-zipf}" \
    VUS=$VUS DURATION=$DURATION \
    k6 run --quiet --summary-export "$OUT/replica-$label.k6.json" "$ROOT/scripts/load.js" \
    > "$OUT/replica-$label.k6.txt" 2>&1 || true

  local rps src_sum
  rps=$(python3 -c "
import json;d=json.load(open('$OUT/replica-$label.k6.json'))
m=d.get('metrics',{}).get('http_reqs',{})
print(round(m.get('rate',0),1))" 2>/dev/null)
  src_sum=$(S "$(sum_sql "$mode")")
  echo "  원본 처리량 초당 ${rps}건, 원본 합계 ${src_sum}"

  # 부하가 끝난 직후 복제본이 얼마나 뒤처져 있는가
  local rep_now behind sbs
  rep_now=$(R "$(sum_sql "$mode")")
  behind=$(( ${src_sum:-0} - ${rep_now:-0} ))
  sbs=$(RV "SHOW REPLICA STATUS\G" | grep "Seconds_Behind_Source" | awk '{print $2}')
  sbs="${sbs:-?}"
  echo "  부하 직후 복제본 합계 ${rep_now}  → 뒤처진 양 ${behind}"
  echo "  Seconds_Behind_Source = ${sbs}"

  local secs
  secs=$(catch_up "$src_sum" "$mode")
  if [ "$secs" = "-1" ]; then
    echo "  따라잡기: 60초 안에 못 따라잡음"
  else
    printf "  따라잡기까지 %.2f초\n" "$secs"
  fi
  kill $pid 2>/dev/null || true
  sleep 1
  echo "$label,$rps,$src_sum,$rep_now,$behind,$sbs,$secs" >> "$OUT/replica-summary.csv"
}

{
echo "# 복제를 붙이고 슬롯 유무에 따른 복제 지연을 잰다"
echo "# 원본 $(S 'SELECT VERSION()'), 복제본 $(docker exec r13-replica mysql -uroot -plab -N -e 'SELECT VERSION()' 2>/dev/null)"
echo "# 복제본은 read-only, SOURCE_AUTO_POSITION=1, SOURCE_HEARTBEAT_PERIOD=0.5"
echo "# 부하 VU ${VUS}, ${DURATION}, 방송 ${LIVES}개, zipf 분포"
echo
echo "판정을 Seconds_Behind_Source 하나에 걸지 않습니다. 이 규모에서는 대부분 0 으로 찍힙니다."
echo "부하 직후 복제본이 뒤처진 양과 따라잡기까지 걸린 시간을 함께 봅니다."
: > "$OUT/replica-summary.csv"
echo "label,rps,src_sum,rep_sum_at_end,behind,seconds_behind_source,catchup_s" >> "$OUT/replica-summary.csv"
run_case single atomic 0
run_case slot64 slot   64
echo
echo "## 정리"
column -s, -t "$OUT/replica-summary.csv" 2>/dev/null || cat "$OUT/replica-summary.csv"
echo
echo "  각 조건 1회 실행입니다."
pkill -f 'sponsor-api.jar' 2>/dev/null || true
} 2>&1 | tee "$OUT/replica.txt"
