#!/usr/bin/env bash
# 실험 3. 20만 계정을 보정하되 서비스를 세우지 않는 법.
#
# 실험 2는 승격이 무관한 조회를 막는다는 것을 보였다. 그런데 보정은 해야 한다.
# 같은 일을 세 방법으로 하고 무엇을 내주는지 본다.
#
#   1) 한 방      트랜잭션 하나로 20만행
#   2) 배치 분할  4,000행씩 끊어 커밋
#   3) 승격 끔    LOCK_ESCALATION = DISABLE 로 두고 한 방
#
# 보정은 UPDATE 한 문장이 전부가 아니다. 감사 로그를 남기고 합계를 검산하는
# 뒷일이 붙는다. 그 뒷일을 대기로 모사해 트랜잭션이 실제로 열려 있는 시간을 만든다.
# 세 방법의 총 작업량은 같게 맞춘다. 1번과 3번은 뒷일 ${HOLD_S}초를 한 번에,
# 2번은 같은 ${HOLD_S}초를 배치 수로 나눠서 진다. 다른 것은 락을 언제 놓느냐뿐이다.
#
# 세 방법 모두 결과는 같아야 한다. 20만 계정의 잔액이 정확히 1씩 줄어야 하고,
# 그것을 확인하지 않으면 "아무 일도 안 해서 빨랐던" 회차가 표에 들어간다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
# 20만행에서는 엔진이 행 락을 잡아 승격이 일어난다. 100만행에서는 처음부터
# 페이지 락을 잡아 승격이 아예 안 일어난다(실험 4). 이 실험의 주제는 승격이므로
# 승격이 나는 규모에서 잰다.
ROWS=${ROWS:-200000}          # 보정 대상 계정 수
SPARE=${SPARE:-50000}         # 보정 대상이 **아닌** 계정 수
TOTAL=$(( ROWS + SPARE ))
BATCH=${BATCH:-4000}
HOLD_S=${HOLD_S:-6}
# 탐침은 보정 대상 밖의 계정이어야 한다. 처음엔 테이블 전체를 보정하면서
# 마지막 계정을 탐침으로 썼는데, 그 행이 보정 대상이라 승격과 무관하게 막혔다.
# 승격을 끈 3번이 조회를 막은 것이 그 때문이었고, 그러면 이 실험은 승격이
# 무엇을 막는지가 아니라 자기 행이 잠겼는지를 잰 것이 된다.
PROBE_ID=$TOTAL

wait_ready || exit 2
now_ms(){ python3 -c 'import time;print(int(time.time()*1000))'; }

reader_start(){
  rm -f "$OUT/.stop"; : > "$OUT/.reader"
  ( while [ ! -f "$OUT/.stop" ]; do
      t0=$(now_ms)
      docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
          -Q "SELECT balance FROM $TBL WHERE account_id = $PROBE_ID" >/dev/null 2>&1
      echo $(( $(now_ms) - t0 )) >> "$OUT/.reader"
    done ) &
  READER_PID=$!
}
reader_stop(){ touch "$OUT/.stop"; wait "$READER_PID" 2>/dev/null; rm -f "$OUT/.stop"; }

# 락 개수를 표본한다. 락 메모리(OBJECTSTORE_LOCK_MANAGER)로 재려다 그만뒀다.
# 그 클럭은 한 번 늘면 반납해도 안 줄어서 조건마다 같은 최댓값이 찍혔다.
# 앞 조건의 값을 다음 조건이 물려받는 자리였다.
locks_start(){
  rm -f "$OUT/.lockstop"; : > "$OUT/.locks"
  ( while [ ! -f "$OUT/.lockstop" ]; do
      # 락 수와 "보정이 락을 든 채 대기 중인가"를 한 번에 읽는다. 둘을 따로 읽으면
      # 그 사이에 상태가 바뀌어 짝이 안 맞는다.
      num "$(Q "SELECT CAST((SELECT COUNT(*) FROM sys.dm_tran_locks
                              WHERE resource_database_id = DB_ID('$DB')) AS varchar(20))
                     + ',' + CAST((SELECT COUNT(*) FROM sys.dm_exec_requests r
                                     JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
                                    WHERE s.is_user_process = 1 AND r.wait_type = 'WAITFOR') AS varchar(4))")" \
        | grep -E '^[0-9]+,[0-9]+$' >> "$OUT/.locks"
    done ) &
  LOCK_PID=$!
}
locks_stop(){ touch "$OUT/.lockstop"; wait "$LOCK_PID" 2>/dev/null; rm -f "$OUT/.lockstop"; }

set_escalation(){
  QD "ALTER TABLE $TBL SET (LOCK_ESCALATION = $1)" >/dev/null
  num "$(QD "SELECT lock_escalation_desc FROM sys.tables WHERE name = '$TBL'")"
}

{
echo "# 실험 3. ${ROWS} 계정 보정을 서비스를 세우지 않고 끝내기"
echo
echo "  테이블에는 계정이 ${TOTAL} 개 있고 그중 ${ROWS} 개만 보정 대상입니다."
echo "  세 방법 모두 같은 일을 합니다. 대상 ${ROWS} 계정의 잔액을 1씩 줄이고,"
echo "  보정의 뒷일(감사 로그·검산)을 ${HOLD_S}초로 모사해 함께 집니다."
echo "  총 작업량은 같습니다. 다른 것은 락을 언제 놓느냐뿐입니다."
echo
echo "  보정이 도는 동안 **보정 대상이 아닌** 계정 ${PROBE_ID} 의 조회를 계속 던져"
echo "  몇 번이나 막혔는지 셉니다."
echo
echo "  총 소요 시간은 적지 않습니다. ARM 에뮬레이션이라 이 호스트의 값이 아닙니다."
echo "  승격 횟수, 막힌 조회 비율, 유지 락 수를 봅니다. 셋 다 시간이 아닙니다."
echo "  유지 락은 보정이 락을 든 채 뒷일을 하는 동안의 락 수입니다."
echo

: > "$OUT/mitigation.csv"
echo "method,escalations,probes,blocked_probes,max_probe_ms,held_locks,peak_locks_all,corrected/spared" >> "$OUT/mitigation.csv"
printf "  %-24s %-7s %-12s %-11s %-11s %s\n" "방법" "승격" "막힌 조회" "최대 지연" "유지 락" "결과"

run_method(){
  local label=$1 esc_mode=$2 sql=$3
  local desc n_esc probes blocked maxms peak verified done_rows

  reset_table "$TOTAL" || return
  desc=$(set_escalation "$esc_mode")
  if [ "$desc" != "$esc_mode" ]; then
    echo "  ${label}: LOCK_ESCALATION 을 ${esc_mode} 로 못 바꿨습니다(${desc}). 버립니다"; return
  fi
  xe_reset
  reader_start; locks_start
  QD "SET NOCOUNT ON; $sql" >/dev/null
  locks_stop; reader_stop

  n_esc=$(xe_count)
  probes=$(awk 'END{print NR+0}'            "$OUT/.reader")
  blocked=$(awk '$1>2000{c++} END{print c+0}' "$OUT/.reader")
  maxms=$(sort -n "$OUT/.reader" | tail -1); maxms=${maxms:-0}
  # 유지 락 = 보정이 락을 든 채 뒷일을 하는 동안의 락 수. 이것이 그 방법이 서비스에
  # 물리는 실제 비용이다. 전체 표본의 최댓값은 method 1 에서 승격 직전의 과도 상태를
  # 표본이 잡느냐 마느냐로 4 와 980 사이를 오갔다. 정상 상태를 재야 비교가 성립한다.
  peak=$(awk -F, '$2 > 0 {print $1}' "$OUT/.locks" | sort -n | tail -1); peak=${peak:-0}
  local peak_all; peak_all=$(awk -F, '{print $1}' "$OUT/.locks" | sort -n | tail -1); peak_all=${peak_all:-0}

  # 대상은 정확히 1 줄고, 대상 밖은 한 행도 건드려지지 않아야 한다.
  done_rows=$(num "$(QD "SELECT COUNT(*) FROM $TBL WHERE balance = 99999 AND account_id <= $ROWS")")
  local spared;  spared=$(num "$(QD "SELECT COUNT(*) FROM $TBL WHERE balance = 100000 AND account_id > $ROWS")")
  if [ "$done_rows" = "$ROWS" ] && [ "$spared" = "$SPARE" ]; then
    verified="대상 ${ROWS} 정확"
  else
    verified="**대상 ${done_rows}/${ROWS}, 대상밖 ${spared}/${SPARE}**"
  fi

  printf "  %-24s %-7s %-12s %-11s %-11s %s\n" \
    "$label" "${n_esc}회" "${blocked}/${probes}회" "${maxms}ms" "${peak}개" "$verified"
  echo "$label,$n_esc,$probes,$blocked,$maxms,$peak,$peak_all,$done_rows/$spared" >> "$OUT/mitigation.csv"
}

run_method "1) 한 방" AUTO \
  "BEGIN TRAN;
     UPDATE $TBL SET balance = balance - 1 WHERE account_id <= $ROWS;
     WAITFOR DELAY '00:00:0${HOLD_S}';
   COMMIT;"

# 배치마다 뒷일을 나눠 진다. 총 대기는 1번과 같다.
PER_MS=$(python3 -c "print(int(${HOLD_S}*1000/(${ROWS}/${BATCH})))")
PER=$(python3 -c "print('00:00:%06.3f' % (${PER_MS}/1000))")
run_method "2) ${BATCH}행씩 배치" AUTO \
  "DECLARE @lo INT = 0;
   WHILE @lo < $ROWS
   BEGIN
     BEGIN TRAN;
       UPDATE $TBL SET balance = balance - 1
        WHERE account_id > @lo AND account_id <= @lo + $BATCH;
       WAITFOR DELAY '$PER';
     COMMIT;
     SET @lo += $BATCH;
   END"

run_method "3) 승격 끄고 한 방" DISABLE \
  "BEGIN TRAN;
     UPDATE $TBL SET balance = balance - 1 WHERE account_id <= $ROWS;
     WAITFOR DELAY '00:00:0${HOLD_S}';
   COMMIT;"

rm -f "$OUT/.reader" "$OUT/.locks"
set_escalation AUTO >/dev/null

echo
echo "  (2번의 배치당 뒷일은 ${PER} 입니다. 배치 $(( ROWS / BATCH ))개를 합하면 1번과 같은 ${HOLD_S}초입니다)"
echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  세 방법 다 전 행을 정확히 보정합니다. 다른 것은 그동안 서비스가 어땠는가입니다."
echo
echo "  1) 한 방은 승격이 일어나고, 보정이 끝날 때까지 그 테이블을 쓰는 조회가"
echo "     전부 줄을 섭니다. 유지 락은 몇 개뿐인데 그중 하나가 테이블 전체입니다."
echo
echo "  2) 배치 분할은 승격이 한 번도 안 일어납니다. 배치마다 커밋해 락을 놓으므로"
echo "     조회가 배치 사이로 지나갑니다. 대신 보정 전체가 하나의 트랜잭션이 아니라서"
echo "     중간에 실패하면 앞 배치는 이미 커밋돼 있습니다. 원자성을 내주고 가용성을 삽니다."
echo
echo "  3) 승격을 끄면 테이블 락은 안 잡히지만 행 락을 대상 수만큼 들고 있어야 합니다."
echo "     대상 밖 조회는 지나갑니다. 대신 락 매니저가 그만큼을 인스턴스 전체와 나눠 씁니다."
echo
echo "  운영에서 고를 것은 2번입니다. 원자성이 꼭 필요하면 보정 단위를 계정 묶음으로"
echo "  잘게 잡고 묶음마다 원자적으로 도는 쪽이 낫습니다. 3번은 배치를 못 쪼개는"
echo "  상황의 임시 수단이고, 켜 두고 잊으면 다음 사고의 재료가 됩니다."
} 2>&1 | tee "$OUT/exp3-mitigation.txt"
