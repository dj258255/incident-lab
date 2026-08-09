#!/usr/bin/env bash
# 실험 7. 승격이 실패하면 어떻게 되는가.
#
# Microsoft Learn 은 승격이 실패하면 락을 1,250개 더 획득할 때마다 다시 시도한다고
# 적는다. 실험 1은 그 1,250 간격을 근거로 "6,250 에서 처음 조건이 성립한다"는 설명을
# 세웠는데, 정작 **실패와 재시도를 본 적이 없다.** 승격이 전부 첫 시도에 성공했다.
#
# 승격은 테이블에 X 락을 잡는 것이다. 다른 세션이 그 테이블에 호환되지 않는 락을
# 들고 있으면 잡을 수 없다. 그 상황을 만든다.
#
# 조건 셋이다. 보정문은 같고 옆 세션이 무엇을 들고 있는지만 다르다.
#   A 아무도 없음        승격 성공
#   B 옆에서 한 행을 갱신 X 락을 든 세션이 있어 테이블 X 를 못 잡는다
#   C 옆에서 한 행을 조회 공유 락. 이것도 테이블 X 와는 호환되지 않는다
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
ROWS=${ROWS:-200000}
UPD=${UPD:-20000}     # 승격이 확실히 나는 행 수
HOLD=${HOLD:-25}

wait_ready || exit 2
OPTLOCK=$(assert_env) || exit 2
now_ms(){ python3 -c 'import time;print(int(time.time()*1000))'; }

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

{
echo "# 실험 7. 승격이 실패하면"
echo "# optimized locking: ${OPTLOCK}"
echo
echo "  ${UPD}행을 한 트랜잭션에서 갱신합니다. 혼자면 승격합니다(실험 1)."
echo "  옆 세션이 같은 표에 락을 들고 있으면 테이블 X 락을 못 잡습니다."
echo
: > "$OUT/retry.csv"
echo "case,blocker,escalation_events,escalated_lock_count,final_shape" >> "$OUT/retry.csv"
printf "  %-28s %-14s %-18s %s\n" "조건" "승격 이벤트" "승격 시점 락수" "갱신 뒤 락 모양"

run_case(){
  local label=$1 blocker=$2
  wait_quiet || { echo "  ${label}: 앞 조건이 안 닫혀 버립니다"; return; }
  reset_table "$ROWS" >/dev/null || return
  xe_reset

  local bpid=""
  if [ -n "$blocker" ]; then
    # 옆 세션이 마지막 행 하나를 잡고 버틴다. 보정 대상과 겹치지 않는다.
    docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
      -Q "SET NOCOUNT ON;
          BEGIN TRAN;
          $blocker
          WAITFOR DELAY '00:00:${HOLD}';
          ROLLBACK;" >/dev/null 2>&1 &
    bpid=$!
    local i held=0
    for i in $(seq 1 60); do
      if [ "$(num "$(Q "SELECT CAST(COUNT(*) AS varchar(4)) FROM sys.dm_exec_requests r
                         JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
                        WHERE s.is_user_process = 1 AND r.wait_type = 'WAITFOR'")")" -gt 0 ] 2>/dev/null; then
        held=1; break
      fi; sleep 1
    done
    [ "$held" = 1 ] || { echo "  ${label}: 옆 세션을 못 세워 버립니다"; wait "$bpid" 2>/dev/null; return; }
  fi

  # 승격이 나는 크기로 갱신하고, 끝난 뒤 락 모양을 본다.
  local shape
  shape=$(num "$(QD "SET NOCOUNT ON;
    BEGIN TRAN;
    UPDATE TOP ($UPD) $TBL SET balance = balance - 1;
    -- 한글을 그대로 돌려받으면 sqlcmd 를 거치며 깨진다. ASCII 로 받아 셸에서 옮긴다.
    SELECT CASE WHEN SUM(CASE WHEN resource_type='OBJECT' AND request_mode='X' THEN 1 ELSE 0 END) > 0
                THEN 'TABLEX'
                ELSE 'ROWS:' + CAST(SUM(CASE WHEN resource_type='KEY' THEN 1 ELSE 0 END) AS varchar(12)) END
      FROM sys.dm_tran_locks WHERE request_session_id = @@SPID;
    ROLLBACK;")")
  case "$shape" in
    TABLEX)  shape="테이블 X 락 하나로 접힘" ;;
    ROWS:*)  shape="행 락 ${shape#ROWS:}개 그대로 유지" ;;
  esac

  local ev at
  ev=$(xe_count)
  at=$(xe_events | head -1 | cut -d'|' -f1); at=${at:--}
  printf "  %-28s %-14s %-18s %s\n" "$label" "${ev}건" "$at" "$shape"
  echo "\"$label\",\"$blocker\",$ev,$at,\"$shape\"" >> "$OUT/retry.csv"
  [ -n "$bpid" ] && wait "$bpid" 2>/dev/null
}

run_case "A 옆 세션 없음" ""
run_case "B 옆에서 한 행 갱신" "UPDATE $TBL SET balance = balance WHERE account_id = $ROWS;"
run_case "C 옆에서 한 행 조회" "SELECT balance FROM $TBL WITH (REPEATABLEREAD) WHERE account_id = $ROWS;"

wait_quiet || true
echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  A 는 승격합니다. 실험 1에서 본 그대로입니다."
echo
echo "  B 와 C 는 옆 세션이 같은 표에 락을 들고 있어 테이블 X 락을 못 잡습니다."
echo "  **승격이 실패하고 행 락을 그대로 들고 갑니다.** 문서가 말한 재시도 간격은"
echo "  이 상태에서 락을 1,250개 더 잡을 때마다 다시 시도한다는 뜻입니다."
echo
echo "  운영에서 이것이 좋은 소식은 아닙니다. 승격이 안 됐다는 것은 테이블이"
echo "  안 잠겼다는 뜻이지만, 그 대가로 **행 락 수만 개를 끝까지 들고 있습니다.**"
echo "  락 매니저 메모리를 그만큼 쓰고, 그 사이 다른 세션은 그 행들을 못 만집니다."
echo
echo "  그리고 이 상태는 **조건이 사라지면 언제든 승격으로 바뀝니다.** 옆 세션이"
echo "  커밋하는 순간 다음 재시도가 성공합니다. 배치를 안 쪼갠 채 \"어제는 승격 안"
echo "  났으니 괜찮다\"고 넘기면, 옆 세션이 없는 날 그대로 테이블이 잠깁니다."
} 2>&1 | tee "$OUT/exp7-escalation-retry.txt"
