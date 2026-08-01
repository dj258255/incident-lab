#!/usr/bin/env bash
# 미분류 활성 세션이 언제 생기는지 찾는다.
# 본문은 첫 실행에서 활성 세션의 21%를 분류하지 못했고, 재실행에서는 미분류가 0건이라
# 그 조건을 재현하지 못했다고 적었다. 무엇이 미분류를 만드는지 조건을 갈라 본다.
#
# 샘플러는 threads 에서 활성 세션을 세고 events_waits_current 로 분류한다.
# 둘이 안 맞는 자리가 미분류다. 후보는 셋이다.
#   1) 대기 소비자가 꺼져 있으면 events_waits_current 가 비어 전부 미분류
#   2) 대기 없이 CPU 만 쓰는 세션은 원래 대기 행이 없다(PI 도 CPU 로 친다)
#   3) 샘플 시점에 대기가 막 끝나 END_EVENT_ID 가 채워지는 찰나
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
C=a20-unc; SECS=${SECS:-20}; LOAD=${LOAD:-8}

echo "condition,samples,active_total,classified,unclassified,pct" > "$OUT/unclassified.csv"
{
echo "# 미분류 활성 세션이 언제 생기는가"
echo
printf "  %-40s %10s %12s %10s\n" "조건" "활성 합" "미분류" "비율"
for CASE in "on lock" "off lock" "on cpu"; do
  set -- $CASE; CONS=$1; KIND=$2
  docker rm -f "$C" >/dev/null 2>&1
  docker run -d --name "$C" -e MYSQL_ROOT_PASSWORD=lab -e MYSQL_DATABASE=lab mysql:8.4.3 >/dev/null
  M(){ docker exec -i "$C" mysql -uroot -plab -N -B lab -e "$1" 2>/dev/null; }
  for _ in $(seq 1 90); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
  if [ "$CONS" = on ]; then
    M "UPDATE performance_schema.setup_consumers SET ENABLED='YES' WHERE NAME LIKE 'events_waits%';
       UPDATE performance_schema.setup_instruments SET ENABLED='YES', TIMED='YES' WHERE NAME LIKE 'wait/%';" >/dev/null
  else
    M "UPDATE performance_schema.setup_consumers SET ENABLED='NO' WHERE NAME LIKE 'events_waits%';" >/dev/null
  fi
  M "CREATE TABLE t(id INT PRIMARY KEY, v INT); INSERT INTO t VALUES (1,0),(2,0);" >/dev/null
  # 부하를 건다
  if [ "$KIND" = lock ]; then
    for i in $(seq 1 $LOAD); do
      docker exec -d "$C" mysql -uroot -plab lab -e \
        "SET SESSION innodb_lock_wait_timeout=60;
         BEGIN; UPDATE t SET v=v+1 WHERE id=1; SELECT SLEEP($SECS); COMMIT;"
    done
  else
    for i in $(seq 1 $LOAD); do
      docker exec -d "$C" mysql -uroot -plab lab -e \
        "SELECT BENCHMARK(200000000, MD5(RAND()));"
    done
  fi
  sleep 3
  # 샘플러를 흉내 낸다. 활성 세션 수와 대기로 분류된 수를 함께 센다.
  TOT=0; CLS=0; SMP=0
  for s in $(seq 1 10); do
    R=$(M "SELECT
        (SELECT COUNT(*) FROM performance_schema.threads
           WHERE TYPE='FOREGROUND' AND PROCESSLIST_COMMAND<>'Sleep' AND PROCESSLIST_ID<>CONNECTION_ID()),
        (SELECT COUNT(*) FROM performance_schema.threads th
           JOIN performance_schema.events_waits_current w ON w.THREAD_ID=th.THREAD_ID
           WHERE th.TYPE='FOREGROUND' AND th.PROCESSLIST_COMMAND<>'Sleep'
             AND th.PROCESSLIST_ID<>CONNECTION_ID() AND w.END_EVENT_ID IS NULL)")
    a=$(echo "$R" | awk '{print $1}'); c=$(echo "$R" | awk '{print $2}')
    TOT=$((TOT+${a:-0})); CLS=$((CLS+${c:-0})); SMP=$((SMP+1)); sleep 1
  done
  UNC=$((TOT-CLS)); PCT=0; [ "$TOT" -gt 0 ] && PCT=$((UNC*100/TOT))
  LBL="소비자 $([ $CONS = on ] && echo 켬 || echo 끔) / 부하 $([ $KIND = lock ] && echo '행 락 대기' || echo 'CPU 만')"
  printf "  %-40s %10s %12s %9s%%\n" "$LBL" "$TOT" "$UNC" "$PCT"
  echo "$LBL,$SMP,$TOT,$CLS,$UNC,$PCT" >> "$OUT/unclassified.csv"
  docker rm -f "$C" >/dev/null 2>&1
done
echo
echo "  소비자를 끄면 대기 행이 아예 없어 전부 미분류가 됩니다."
echo "  CPU 만 쓰는 부하도 대기 행이 없습니다. 다만 이쪽은 PI 도 CPU 로 치므로"
echo "  '미분류'가 아니라 'CPU'로 읽는 것이 맞습니다. 두 경우를 구분해야 합니다."
} 2>&1 | tee "$OUT/exp3-unclassified.txt"
