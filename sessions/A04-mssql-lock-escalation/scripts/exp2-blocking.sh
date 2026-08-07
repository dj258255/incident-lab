#!/usr/bin/env bash
# 실험 2. 승격이 일어나면 무엇이 막히는가.
#
# 실험 1은 락의 모양만 봤다. 모양이 바뀌는 것 자체는 사고가 아니다. 사고는
# 그 다음이다. 보정 배치가 건드리지도 않은 계정의 조회가 같이 멈추는가.
#
# 조건은 셋이다. 보정 대상 행 수와 격리 설정만 다르고 나머지는 같다.
#   A 3,000행  승격 없음
#   B 10,000행 승격 있음
#   C 10,000행 승격 있음 + 읽기 커밋 스냅샷(RCSI) 켬
#
# 조회 대상은 보정이 건드리지 않은 계정이다. 클러스터드 인덱스 순서로 앞에서부터
# 갱신하므로 마지막 account_id 는 어느 조건에서도 갱신 대상이 아니다.
#
# 이 스크립트를 두 번 고쳤다. 둘 다 조건 사이가 새는 문제였다.
#   1) sleep 4 로 갱신이 끝나기를 기다렸더니 에뮬레이션에서 안 끝나는 회차가 있었다.
#      시간이 아니라 상태(WAITFOR 진입)를 기다리도록 바꿨다.
#   2) pid=$(hold_update ...) 로 배경 작업을 띄웠더니 그 작업이 명령 치환의
#      서브셸에 붙어 부모의 wait 이 못 거뒀다. 앞 조건의 보정 트랜잭션이 살아 있는
#      채로 다음 조건이 시작돼 판정이 뒤엉켰다. 배경 작업은 현재 셸에서 직접 띄운다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
HOLD=${HOLD:-20}     # 보정 트랜잭션을 열어 두는 초
PROBE_ID=200000      # 보정이 건드리지 않는 계정

wait_ready || exit 2
now_ms(){ python3 -c 'import time;print(int(time.time()*1000))'; }

# 열려 있는 사용자 트랜잭션이 없을 때까지 기다린다. 조건 간 누수를 막는 관문이다.
wait_quiet(){
  local i
  for i in $(seq 1 120); do
    [ "$(num "$(Q "SELECT CAST(COUNT(*) AS varchar(4))
                     FROM sys.dm_tran_session_transactions st
                     JOIN sys.dm_exec_sessions s ON s.session_id = st.session_id
                    WHERE s.is_user_process = 1")")" = "0" ] && return 0
    sleep 1
  done
  return 1
}

set_rcsi(){
  Q "ALTER DATABASE [$DB] SET READ_COMMITTED_SNAPSHOT $1 WITH ROLLBACK IMMEDIATE" >/dev/null
  num "$(Q "SELECT CASE WHEN is_read_committed_snapshot_on = 1 THEN 'ON' ELSE 'OFF' END
              FROM sys.databases WHERE name = '$DB'")"
}

{
echo "# 실험 2. 승격이 무관한 행의 조회를 막는가"
echo
echo "  조회 대상 계정 ${PROBE_ID} 은 어느 조건에서도 갱신 대상이 아닙니다."
echo "  보정 트랜잭션은 ${HOLD}초 동안 열어 둡니다. 조회가 그 안에 끝나면 안 막힌 것이고,"
echo "  트랜잭션이 닫힐 때까지 기다렸다 끝나면 막힌 것입니다."
echo
echo "  걸린 시간은 에뮬레이션의 성능이 아니라 우리가 정한 ${HOLD}초 대기가 만든 값입니다."
echo "  그래서 이 절의 밀리초는 성능 수치가 아니라 막혔는지 아닌지의 증거로만 씁니다."
echo

reset_table 200000 || exit 2
RCSI=$(set_rcsi OFF)
[ "$RCSI" = "OFF" ] || { echo "중단: RCSI 를 끄지 못했습니다($RCSI)"; exit 2; }

: > "$OUT/blocking.csv"
echo "case,rows,rcsi,escalated,probe_ms,blocked,wait_type" >> "$OUT/blocking.csv"

printf "  %-34s %-6s %-8s %-10s %s\n" "조건" "승격" "조회" "걸린시간" "대기유형"

run_case(){
  local label=$1 rows=$2 rcsi=$3
  local esc ms blocked wt i held=0 hold_pid probe_pid

  wait_quiet || { echo "  ${label}: 앞 조건의 트랜잭션이 안 닫혀 버립니다"; return; }
  xe_reset

  # 배경 작업을 현재 셸에서 직접 띄운다. 명령 치환 안에서 띄우면 wait 이 못 거둔다.
  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
      -Q "SET NOCOUNT ON;
          BEGIN TRAN;
          UPDATE TOP ($rows) $TBL SET balance = balance - 1;
          WAITFOR DELAY '00:00:${HOLD}';
          ROLLBACK;" >/dev/null 2>&1 &
  hold_pid=$!

  # 갱신이 끝나고 락이 최종 모양이 된 것을 상태로 확인한다.
  for i in $(seq 1 90); do
    if [ "$(num "$(Q "SELECT CAST(COUNT(*) AS varchar(4))
                        FROM sys.dm_exec_requests r
                        JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
                       WHERE s.is_user_process = 1 AND r.wait_type = 'WAITFOR'")")" -gt 0 ] 2>/dev/null; then
      held=1; break
    fi
    sleep 1
  done
  if [ "$held" != 1 ]; then
    echo "  ${label}: 보정 트랜잭션이 열린 것을 확인하지 못해 이 조건은 버립니다"
    wait "$hold_pid" 2>/dev/null; return
  fi

  esc=$(num "$(Q "SELECT CAST(COUNT(*) AS varchar(4)) FROM sys.dm_tran_locks
                   WHERE resource_type='OBJECT' AND request_mode='X'
                     AND resource_database_id = DB_ID('$DB')")")

  # 조회를 배경에서 던지고, 그 사이 대기 유형을 본다.
  ( t0=$(now_ms)
    docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
        -Q "SELECT balance FROM $TBL WHERE account_id = $PROBE_ID" >/dev/null 2>&1
    echo $(( $(now_ms) - t0 )) > "$OUT/.probe" ) &
  probe_pid=$!
  sleep 3
  wt=$(num "$(Q "SELECT TOP 1 w.wait_type
                   FROM sys.dm_os_waiting_tasks w
                   JOIN sys.dm_exec_sessions s ON s.session_id = w.session_id
                  WHERE s.is_user_process = 1 AND w.wait_type LIKE 'LCK%'")")
  case "$wt" in ''|*Msg*) wt="없음" ;; esac
  wait "$probe_pid" 2>/dev/null
  ms=$(cat "$OUT/.probe" 2>/dev/null || echo -1)
  wait "$hold_pid" 2>/dev/null

  # 안 막힌 조회는 수백 밀리초, 막힌 조회는 초 단위다. 사이가 넓어 2초로 가른다.
  if [ "$ms" -gt 2000 ]; then blocked="막힘"; else blocked="안 막힘"; fi
  printf "  %-34s %-6s %-8s %-10s %s\n" "$label" \
         "$([ "${esc:-0}" -gt 0 ] && echo 있음 || echo 없음)" "$blocked" "${ms}ms" "$wt"
  # 라벨에 쉼표가 들어간다("A 3,000행 보정"). 감싸지 않으면 열이 밀린다.
  echo "\"$label\",$rows,$rcsi,$esc,$ms,$blocked,$wt" >> "$OUT/blocking.csv"
}

run_case "A 3,000행 보정"        3000  OFF
run_case "B 10,000행 보정"       10000 OFF

wait_quiet || true
RCSI=$(set_rcsi ON)
if [ "$RCSI" = "ON" ]; then
  run_case "C 10,000행 보정 + RCSI"  10000 ON
else
  echo "  RCSI 를 켜지 못했습니다($RCSI). C 조건은 건너뜁니다"
fi
wait_quiet || true
set_rcsi OFF >/dev/null
rm -f "$OUT/.probe"

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  A 는 보정이 3,000행을 잡고 있어도 나머지 197,000행의 조회가 지나갑니다."
echo "  B 는 같은 조회가 보정이 끝날 때까지 막힙니다. 갱신 대상이 아닌 계정인데도"
echo "  테이블 락 하나가 테이블 전체를 덮기 때문입니다."
echo
echo "  **보정 배치 하나가 그 테이블을 쓰는 모든 요청을 세웁니다.** 게임 운영으로"
echo "  옮기면 재화 보정을 도는 동안 보정 대상이 아닌 이용자의 조회까지 멈춥니다."
echo
echo "  C 는 같은 승격이 일어나는데도 조회가 지나갑니다. 스냅샷이 있으면 읽기가"
echo "  X 락을 기다리지 않기 때문입니다. 다만 이것은 읽기만 구제합니다."
echo "  같은 테이블에 쓰기를 하려는 트랜잭션은 RCSI 와 무관하게 그대로 막힙니다."
} 2>&1 | tee "$OUT/exp2-blocking.txt"
