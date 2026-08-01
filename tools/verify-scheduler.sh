#!/usr/bin/env bash
# 백업 검증 파이프라인을 주기적으로 돌리고 실패하면 알린다.
#
# 12절이 체크리스트를 파이프라인으로 옮겼지만 거기까지는 "시연"이다. GitLab 이 실제로
# 고친 것은 백업 기술이 아니라 **소유자와 알림**이었다. 파이프라인은 짜면 되지만
# 그것이 실패했을 때 누가 받는가가 코드 밖의 문제다. 그 코드 안쪽 절반을 만든다.
#
#   주기 실행 + 실패 시 알림 + 알림이 실제로 나가는지 검증
#
# GitLab 사고의 핵심이 여기 있다. pg_dump 는 에러를 냈고 크론은 메일을 보냈는데
# 그 메일이 DMARC 로 반려됐다. **알림 경로 자체를 검증하지 않으면 알림은 없는 것과 같다.**
# 그래서 이 스케줄러는 일부러 실패를 하나 끼워 넣어 알림이 실제로 나가는지 확인한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SESSION="$ROOT/sessions/A23-backup-pitr"
OUT="$SESSION/results"; mkdir -p "$OUT"
ALERTS="$OUT/alerts.log"; STATE="$OUT/verify-state.csv"
ROUNDS=${ROUNDS:-6}; INTERVAL=${INTERVAL:-5}
BREAK_AT=${BREAK_AT:-4}    # 이 회차에 일부러 백업을 망가뜨린다

: > "$ALERTS"
echo "round,ts,verdict,failed_checks,alerted" > "$STATE"

# 알림 채널. 실무에서는 Slack·PagerDuty·메일이고 여기서는 파일과 종료 코드다.
# 중요한 것은 채널이 무엇인가가 아니라 **보냈다는 것을 확인할 수 있는가**다.
notify(){ # $1 = 회차, $2 = 사유
  local ts="[회차 $1]"
  printf '%s %s\n' "$ts" "$2" >> "$ALERTS"
  # 보낸 것이 실제로 남았는지 즉시 되읽어 확인한다. GitLab 의 DMARC 반려가 이 자리다.
  if grep -qF "$2" "$ALERTS"; then echo "sent"; else echo "LOST"; fi
}

# 파이프라인 한 회. 정상 백업과 망가진 백업을 함께 넣어 각 검사가 실제로 걸리는지 본다.
run_once(){ # $1 = 회차
  local r="$1" C=a23-sched fails=0 detail=""
  docker rm -f "$C" >/dev/null 2>&1
  docker run -d --name "$C" -e MYSQL_ROOT_PASSWORD=lab -e MYSQL_DATABASE=lab mysql:8.4.3 >/dev/null
  M(){ docker exec -i "$C" mysql -uroot -plab -N -B -e "$1" 2>/dev/null; }
  for _ in $(seq 1 90); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
  # **검사가 실패한 것과 검사를 돌리지도 못한 것을 구분한다.**
  # 1차 실행에서 컨테이너가 안 떠 전 회차가 "실패"로 나왔고, 스케줄러는 "알림 경로가
  # 살아 있습니다"라고 보고했다. 알림은 실제로 나갔으니 그 말이 틀린 것은 아닌데,
  # 정작 검사는 한 번도 안 돌았다. 운영에서 이 둘을 같은 알림으로 묶으면
  # "백업이 깨졌다"와 "검사 장비가 죽었다"를 구분할 수 없다.
  [ "$(M 'SELECT 1')" = "1" ] || { echo "-1|환경 실패: 검사 컨테이너가 안 떴습니다"; docker rm -f "$C" >/dev/null; return; }

  local ROWS=50000
  M "CREATE DATABASE v; CREATE TABLE v.t(id INT AUTO_INCREMENT PRIMARY KEY, a INT);
     SET SESSION cte_max_recursion_depth=$((ROWS+10));
     INSERT INTO v.t(a) SELECT n%997 FROM (
       WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<$ROWS) SELECT n FROM s) q;" >/dev/null
  local SRC; SRC=$(M "SELECT COUNT(*) FROM v.t")
  if [ "${SRC:-0}" -ne "$ROWS" ]; then
    echo "-1|환경 실패: 원본 적재가 ${SRC:-0}행(기대 $ROWS). 이 상태로 검사하면 전부 걸림으로 나온다"
    docker rm -f "$C" >/dev/null; return
  fi
  local SUM; SUM=$(M "SELECT SUM(a) FROM v.t")
  docker exec "$C" sh -c "mysqldump -uroot -plab --single-transaction --databases v > /tmp/b.sql" 2>/dev/null

  # 지정한 회차에 백업을 망가뜨린다. 알림이 실제로 나가는지 보기 위해서다.
  if [ "$r" = "$BREAK_AT" ]; then
    docker exec "$C" sh -c "sed -i 's/^INSERT/-- INSERT/' /tmp/b.sql" 2>/dev/null
    detail="${detail}백업을 일부러 손상시킴(INSERT 주석 처리). "
  fi

  # 검사 1. 크기
  local SZ; SZ=$(docker exec "$C" sh -c "wc -c < /tmp/b.sql" 2>/dev/null | tr -d ' ')
  [ "${SZ:-0}" -lt 100000 ] && { fails=$((fails+1)); detail="${detail}크기 걸림. "; }
  # 검사 2. 복원 실행
  M "DROP DATABASE v;" >/dev/null
  local RERR; RERR=$(docker exec "$C" sh -c "mysql -uroot -plab < /tmp/b.sql" 2>&1 | grep -ci "^ERROR")
  [ "${RERR:-0}" -gt 0 ] && { fails=$((fails+1)); detail="${detail}복원 실행 걸림. "; }
  # 검사 3. 데이터 대조. **0보다 큰가가 아니라 원본과 같은가로 본다.**
  local GOT GSUM; GOT=$(M "SELECT COUNT(*) FROM v.t"); GSUM=$(M "SELECT COALESCE(SUM(a),0) FROM v.t")
  if [ "${GOT:-0}" != "$SRC" ] || [ "${GSUM:-0}" != "$SUM" ]; then
    fails=$((fails+1)); detail="${detail}데이터 대조 걸림(${GOT:-0}행/기대 ${SRC}행). "
  fi
  docker rm -f "$C" >/dev/null 2>&1
  echo "${fails}|${detail:-전 검사 통과}"
}

{
echo "# 백업 검증을 주기적으로 돌리고 실패하면 알린다"
echo "# ${ROUNDS}회차 · ${INTERVAL}초 간격 · ${BREAK_AT}회차에 일부러 백업을 손상시킵니다"
echo "# 알림 경로 자체를 검증합니다. 보냈다고 믿는 것과 도착한 것은 다릅니다."
echo
printf "  %6s %10s %8s %10s  %s\n" "회차" "판정" "실패검사" "알림" "내용"
EXIT=0; ENVFAIL=0; CHKFAIL=0
for r in $(seq 1 "$ROUNDS"); do
  IFS='|' read -r F D <<< "$(run_once "$r")"
  if [ "${F:-0}" -eq 0 ]; then
    V="정상"; A="-"
  elif [ "${F:-0}" -lt 0 ]; then
    V="**환경**"; A=$(notify "$r" "[환경] $D"); ENVFAIL=$((ENVFAIL+1)); EXIT=4
  else
    V="**실패**"; A=$(notify "$r" "[검사] $D"); CHKFAIL=$((CHKFAIL+1)); EXIT=1
  fi
  printf "  %6s %10s %8s %10s  %s\n" "$r" "$V" "${F:-?}" "$A" "$D"
  echo "$r,$(date +%H:%M:%S),$V,${F:-0},$A" >> "$STATE"
  [ "$r" -lt "$ROUNDS" ] && sleep "$INTERVAL"
done
echo
echo "  알림 로그(${ALERTS##*/}):"
if [ -s "$ALERTS" ]; then sed 's/^/    /' "$ALERTS"; else echo "    (비어 있음)"; fi
echo
N=$(grep -c . "$ALERTS" 2>/dev/null || echo 0)
TOTFAIL=$((ENVFAIL+CHKFAIL))
echo "  검사 실패 ${CHKFAIL}건, 환경 실패 ${ENVFAIL}건, 알림 ${N}건"
if [ "${N:-0}" -ne "$TOTFAIL" ]; then
  echo "  **실패 ${TOTFAIL}건인데 알림이 ${N}건입니다. 알림이 유실됐습니다.**"; EXIT=3
elif [ "$ENVFAIL" -gt 0 ] && [ "$CHKFAIL" -eq 0 ]; then
  echo "  **전부 환경 실패입니다. 백업 검사는 한 번도 안 돌았습니다.**"
  echo "  알림이 나간 것과 백업이 검증된 것은 다릅니다. 이 회차는 백업에 대해"
  echo "  아무것도 말해 주지 않습니다."; EXIT=4
elif [ "$CHKFAIL" -eq 0 ]; then
  echo "  **검사 실패가 한 건도 안 났습니다.** ${BREAK_AT}회차에 일부러 망가뜨렸는데도"
  echo "  통과가 나왔다면 검사 자체를 의심해야 합니다."; EXIT=2
else
  echo "  **일부러 망가뜨린 회차에서 검사가 걸렸고 알림이 나갔습니다. 경로가 살아 있습니다.**"
fi
echo
echo "  이 스크립트의 종료 코드는 ${EXIT} 입니다. cron 이나 systemd timer 에 걸면"
echo "  0 이 아닌 종료가 그대로 실패 신호가 됩니다. 실무 배치 예시:"
echo "    */30 * * * * /opt/lab/tools/verify-scheduler.sh || /opt/lab/tools/page-oncall.sh"
exit $EXIT
} 2>&1 | tee "$OUT/verify-scheduler.txt"
