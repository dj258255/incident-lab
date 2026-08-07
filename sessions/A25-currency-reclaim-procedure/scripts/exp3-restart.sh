#!/usr/bin/env bash
# 실험 3. 보정 중간에 죽으면 어떻게 되는가. 그리고 그 사이 이용자가 재화를 쓰면.
#
# 배치를 쪼개면 승격을 피하는 대신 원자성을 내준다. 보정 전체가 한 트랜잭션이
# 아니므로 중간에 죽으면 앞 배치는 이미 커밋돼 있다. 그 상태에서 두 가지를 묻는다.
#
#   1) 이어서 돌 수 있는가. 같은 계정을 두 번 빼거나 건너뛰지 않는가.
#   2) 보정이 도는 동안 이용자가 재화를 쓰면 어느 쪽이 이기는가.
#
# 2번이 이 실험의 무서운 쪽이다. 보정과 이용자 트랜잭션이 같은 행을 만지면
# 나중에 커밋한 쪽이 앞의 결과를 덮을 수 있다. 그러면 회수는 성공으로 기록되는데
# 실제 잔액은 안 줄어 있다. 실패가 성공과 같은 모양으로 남는 자리다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

wait_ready || exit 2
TOTAL=$(grep '^reclaim_total,' "$OUT/dataset.csv" | cut -d, -f2)
[ -n "$TOTAL" ] || { echo "중단: dataset.csv 가 없습니다" >&2; exit 2; }

reset_state(){
  QDX "SET NOCOUNT ON;
  DELETE FROM correction_detail;
  DELETE FROM correction_batch;
  DBCC CHECKIDENT('correction_batch', RESEED, 0) WITH NO_INFOMSGS;
  UPDATE account_currency SET balance = 50000 + (account_id % 37) * 1000, debt = 0;"
}

{
echo "# 실험 3. 중간에 죽었을 때와 동시에 썼을 때"
echo

QFX "$(cat "$ROOT/scripts/reclaim.sql")" || exit 2

echo "## 3-1. 다섯 번째 배치에서 죽인다"
echo
reset_state || exit 2
OUT1=$(QD "SET NOCOUNT ON;
           DECLARE @b INT;
           EXEC usp_ReclaimCurrency @reason = N'실패 주입 시험', @mode = 'DEBT',
                                    @chunk = $CHUNK, @fail_at = 5, @batch_id = @b OUTPUT;
           SELECT @b;")
ERRMSG=$(echo "$OUT1" | grep -E '^(Msg|메시지) 50001' | head -1)
BID=$(num "$(QD "SELECT TOP 1 CAST(batch_id AS varchar(12)) FROM correction_batch ORDER BY batch_id DESC")")
DONE1=$(num "$(QD "SELECT COUNT(*) FROM correction_detail")")
LAST1=$(num "$(QD "SELECT last_done FROM correction_batch WHERE batch_id = $BID")")
STAT1=$(num "$(QD "SELECT status FROM correction_batch WHERE batch_id = $BID")")
SUM1=$(num "$(QD "SELECT ISNULL(SUM(applied_amount + debt_amount),0) FROM correction_detail")")

if [ -n "$ERRMSG" ]; then echo "  주입한 실패가 던져졌습니다: ${ERRMSG}"; else echo "  **실패가 안 던져졌습니다. 이 절은 성립하지 않습니다.**"; exit 2; fi
printf "  %-24s %s\n" "처리된 계정" "${DONE1}개"
printf "  %-24s %s\n" "진행 지점(last_done)" "$LAST1"
printf "  %-24s %s\n" "배치 상태" "$STAT1"
printf "  %-24s %s\n" "여기까지 회수한 금액" "$SUM1"
echo
echo "  앞 배치는 커밋돼 남아 있습니다. 원자성을 내준 대가입니다."
echo "  대신 진행 지점이 같은 트랜잭션에서 옮겨졌으므로 어디까지 했는지는 정확합니다."
echo

echo "## 3-2. 같은 배치를 이어서 돌린다"
echo
OUT2=$(QD "SET NOCOUNT ON;
           DECLARE @b INT = $BID;
           EXEC usp_ReclaimCurrency @reason = N'이어 돌리기', @mode = 'DEBT',
                                    @chunk = $CHUNK, @batch_id = @b OUTPUT;")
if echo "$OUT2" | grep -qE '^(Msg|메시지) [0-9]+'; then
  echo "  **이어 돌리기가 실패했습니다.**"; echo "$OUT2" | grep -E '^(Msg|메시지)' | head -2; exit 2
fi
DONE2=$(num "$(QD "SELECT COUNT(*) FROM correction_detail")")
SUM2=$(num "$(QD "SELECT ISNULL(SUM(applied_amount + debt_amount),0) FROM correction_detail")")
DUP=$(num "$(QD "SELECT COUNT(*) FROM (SELECT account_id FROM correction_detail
                                        GROUP BY account_id HAVING COUNT(*) > 1) q")")
MISS=$(num "$(QD "SELECT COUNT(*) FROM reclaim_target r
                   WHERE NOT EXISTS (SELECT 1 FROM correction_detail d WHERE d.account_id = r.account_id)")")
STAT2=$(num "$(QD "SELECT status FROM correction_batch WHERE batch_id = $BID")")
printf "  %-24s %s\n" "처리된 계정" "${DONE2}개"
printf "  %-24s %s\n" "두 번 처리된 계정" "${DUP}개"
printf "  %-24s %s\n" "빠진 계정" "${MISS}개"
printf "  %-24s %s\n" "회수 총액" "$SUM2"
printf "  %-24s %s\n" "배치 상태" "$STAT2"
echo
if [ "$DUP" = "0" ] && [ "$MISS" = "0" ] && [ "$SUM2" = "$TOTAL" ]; then
  echo "  **두 번 뺀 계정도, 빠진 계정도 없습니다.** 진행 지점을 배치와 같은 트랜잭션에서"
  echo "  옮긴 것이 여기서 값을 합니다. 밖에서 옮겼으면 커밋과 기록 사이에 죽었을 때"
  echo "  같은 배치를 두 번 돌아 이중 회수가 됩니다."
else
  echo "  **이어 돌리기가 정확하지 않습니다. 이 절차는 쓰면 안 됩니다.**"
fi
{ echo "phase,accounts,dup,missing,total,status"
  echo "after_fail,$DONE1,,,$SUM1,$STAT1"
  echo "after_resume,$DONE2,$DUP,$MISS,$SUM2,$STAT2"; } > "$OUT/restart.csv"
echo

echo "## 3-3. 보정 중에 이용자가 재화를 쓰면"
echo
echo "  보정이 도는 동안 같은 계정의 잔액을 이용자가 바꿉니다."
echo "  회수는 성공으로 기록되는데 실제 잔액은 안 줄어 있을 수 있습니다."
echo
reset_state || exit 2
# 보정 대상 중 앞쪽 계정 하나를 골라 그 계정에만 부하를 준다.
VICTIM=$(num "$(QD "SELECT TOP 1 CAST(account_id AS varchar(12)) FROM reclaim_target ORDER BY account_id DESC")")
V_AMT=$(num "$(QD "SELECT CAST(extra_amount AS varchar(20)) FROM reclaim_target WHERE account_id = $VICTIM")")
V_BEFORE=$(num "$(QD "SELECT CAST(balance AS varchar(20)) FROM account_currency WHERE account_id = $VICTIM")")

# 이용자 쪽: 보정이 도는 동안 계속 500 씩 쓴다.
SPEND=0
( for i in $(seq 1 40); do
    docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
      -Q "SET NOCOUNT ON;
          UPDATE account_currency SET balance = balance - 500
           WHERE account_id = $VICTIM AND balance >= 500;" >/dev/null 2>&1
  done; echo done > "$OUT/.spender" ) &
SP_PID=$!

QD "SET NOCOUNT ON;
    DECLARE @b INT;
    EXEC usp_ReclaimCurrency @reason = N'동시성 시험', @mode = 'DEBT',
                             @chunk = $CHUNK, @batch_id = @b OUTPUT;" >/dev/null
wait "$SP_PID" 2>/dev/null
rm -f "$OUT/.spender"

V_AFTER=$(num "$(QD "SELECT CAST(balance AS varchar(20)) FROM account_currency WHERE account_id = $VICTIM")")
V_DEBT=$(num "$(QD "SELECT CAST(debt AS varchar(20)) FROM account_currency WHERE account_id = $VICTIM")")
V_LOG=$(num "$(QD "SELECT CAST(applied_amount AS varchar(20)) + '/' + CAST(debt_amount AS varchar(20))
                     + '/' + CAST(balance_before AS varchar(20)) + '/' + CAST(balance_after AS varchar(20))
                     FROM correction_detail WHERE account_id = $VICTIM")")
IFS=/ read -r L_APP L_DEBT L_BEF L_AFT <<<"$V_LOG"
printf "  %-30s %s\n" "대상 계정" "$VICTIM"
printf "  %-30s %s\n" "회수해야 할 금액" "$V_AMT"
printf "  %-30s %s\n" "보정 전 잔액" "$V_BEFORE"
printf "  %-30s %s\n" "감사 로그의 전/후 잔액" "${L_BEF} → ${L_AFT}"
printf "  %-30s %s\n" "감사 로그의 적용액/빚" "${L_APP}/${L_DEBT}"
printf "  %-30s %s\n" "최종 잔액/빚" "${V_AFTER}/${V_DEBT}"
echo
echo "  감사 로그는 보정 시점의 전후를 그대로 적습니다. 그 뒤 이용자가 더 쓴 것은"
echo "  로그에 안 남고 최종 잔액에만 반영됩니다. 로그의 사후 잔액과 지금 잔액이"
echo "  다른 것은 그래서이고, 회수 자체가 새는 것과는 다릅니다."
echo
echo "  **회수가 새는지는 갱신이 원자적인가로 갈립니다.** 이 프로시저는"
echo "  balance = balance - amount 로 읽고 쓰기를 한 문장에 두었습니다. 값을 먼저"
echo "  읽어 애플리케이션에서 뺀 뒤 써 넣었다면 그 사이의 사용이 덮여 사라집니다."
LEAK=$(num "$(QD "SELECT COUNT(*) FROM correction_detail d JOIN reclaim_target r ON r.account_id = d.account_id
                   WHERE d.applied_amount + d.debt_amount <> r.extra_amount")")
printf "\n  %-30s %s\n" "회수액이 대상과 다른 계정" "${LEAK}개"
if [ "$LEAK" = "0" ]; then
  echo "  동시 사용이 있어도 회수 금액은 대상과 정확히 같습니다."
else
  echo "  **동시 사용 때문에 회수가 샜습니다.**"
fi
echo "concurrency,$VICTIM,$V_AMT,$V_BEFORE,$L_BEF,$L_AFT,$V_AFTER,$V_DEBT,$LEAK" >> "$OUT/restart.csv"

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  배치를 쪼개면 원자성을 내줍니다. 중간에 죽으면 앞 배치는 남습니다."
echo "  그 대가를 감당할 수 있게 만드는 것이 **진행 지점을 배치와 같은 트랜잭션에서**"
echo "  옮기는 것입니다. 그러면 이어서 돌 때 두 번 빼지도 건너뛰지도 않습니다."
echo
echo "  동시 사용이 있어도 회수 금액은 정확했습니다. 갱신을 한 문장에 둔 덕입니다."
echo "  읽고 계산하고 쓰는 것을 나누면 그 사이의 사용이 조용히 사라집니다."
} 2>&1 | tee "$OUT/exp3-restart.txt"
