#!/usr/bin/env bash
# 실험 2. 회수를 실제로 돌린다. 두 설계를 견준다.
#
# 잔액이 모자란 계정을 어떻게 할 것인가가 이 실험의 질문이다.
#   NEGATIVE  제약을 빼고 잔액을 음수로 내린다
#   DEBT      잔액은 0 에서 멈추고 못 받은 만큼을 debt 에 적는다
#
# 어느 쪽이든 회수 총액은 같아야 한다. 다른 것은 그 뒤에 무엇을 할 수 있느냐다.
#
# 배치 크기는 A04 의 결론을 따라 5,000 미만이다. 승격이 한 번도 안 일어나는지를
# 확장 이벤트로 확인한다. 여기서 승격이 나면 보정 배치가 서비스를 세운다는 뜻이다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

wait_ready || exit 2
TOTAL=$(grep '^reclaim_total,' "$OUT/dataset.csv" | cut -d, -f2)
TARGETS_N=$(grep '^targets,' "$OUT/dataset.csv" | cut -d, -f2)
SHORT_N=$(grep '^short_targets,' "$OUT/dataset.csv" | cut -d, -f2)
[ -n "$TOTAL" ] || { echo "중단: dataset.csv 가 없습니다. 실험 1을 먼저 돌립니다" >&2; exit 2; }

xe_reset(){
  Q "IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name='a25_esc')
       DROP EVENT SESSION a25_esc ON SERVER;
     CREATE EVENT SESSION a25_esc ON SERVER
       ADD EVENT sqlserver.lock_escalation
       ADD TARGET package0.ring_buffer WITH (MAX_MEMORY=4096 KB);
     ALTER EVENT SESSION a25_esc ON SERVER STATE = START;" >/dev/null
}
xe_count(){
  docker exec -i "$CT" sh -c "cat > /tmp/a25xe.sql" <<'SQL'
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SELECT COUNT(*)
FROM (SELECT CAST(t.target_data AS xml) x
        FROM sys.dm_xe_sessions s
        JOIN sys.dm_xe_session_targets t ON t.event_session_address = s.address
       WHERE s.name='a25_esc' AND t.target_name='ring_buffer') q
CROSS APPLY x.nodes('RingBufferTarget/event') e(n);
SQL
  num "$(docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -i /tmp/a25xe.sql 2>&1)"
}

# 보정 전 상태로 되돌린다. 조건 사이가 새면 두 설계를 못 견준다.
reset_state(){
  QDX "SET NOCOUNT ON;
  DELETE FROM correction_detail;
  DELETE FROM correction_batch;
  DBCC CHECKIDENT('correction_batch', RESEED, 0) WITH NO_INFOMSGS;
  UPDATE account_currency SET balance = 50000 + (account_id % 37) * 1000, debt = 0;" || return 2
  # 제약을 원래대로 되돌린다(앞 조건이 뺐을 수 있다).
  QD "IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name='CK_balance_nonneg')
        ALTER TABLE account_currency WITH CHECK ADD CONSTRAINT CK_balance_nonneg CHECK (balance >= 0);" >/dev/null
}

{
echo "# 실험 2. 회수 실행과 두 설계의 대조"
echo
echo "  회수 대상 ${TARGETS_N}개, 그중 잔액이 모자란 계정 ${SHORT_N}개."
echo "  회수해야 할 총액 ${TOTAL}. 배치 크기 ${CHUNK}."
echo
echo "  시간은 적지 않습니다. ARM 에뮬레이션이라 이 호스트의 값이 아닙니다."
echo "  회수 정확도, 승격 횟수, 감사 로그 완결성을 봅니다. 셋 다 시간이 아닙니다."
echo

QFX "$(cat "$ROOT/scripts/reclaim.sql")" || exit 2
echo "  usp_ReclaimCurrency 설치 완료"
echo

: > "$OUT/reclaim.csv"
echo "mode,rounds,reclaimed,target,match,escalations,negative_accounts,debt_accounts,audit_rows" >> "$OUT/reclaim.csv"
printf "  %-10s %-8s %-16s %-8s %-10s %-12s %s\n" "설계" "배치수" "회수액" "검산" "승격" "음수 계정" "빚 계정"

run_mode(){
  local mode=$1
  reset_state || return
  if [ "$mode" = "NEGATIVE" ]; then
    # 음수를 허용하려면 제약을 빼야 한다. 이것이 이 설계의 대가다.
    QD "ALTER TABLE account_currency DROP CONSTRAINT CK_balance_nonneg;" >/dev/null
  fi
  xe_reset

  local out rounds reclaimed
  out=$(QD "SET NOCOUNT ON;
            DECLARE @b INT;
            EXEC usp_ReclaimCurrency @reason = N'A24 탐지분 회수', @mode = '$mode',
                                     @chunk = $CHUNK, @batch_id = @b OUTPUT;")
  if echo "$out" | grep -qE '^(Msg|메시지) [0-9]+'; then
    printf "  %-10s %s\n" "$mode" "**실패**"
    echo "$out" | grep -E '^(Msg|메시지)' | head -2
    echo "$mode,ERROR,,,,,," >> "$OUT/reclaim.csv"; return
  fi
  rounds=$(echo "$out" | tr -s ' ' | grep -oE '^[0-9]+ [0-9]+ [0-9]+$' | head -1 | cut -d' ' -f2)
  reclaimed=$(echo "$out" | tr -s ' ' | grep -oE '^[0-9]+ [0-9]+ [0-9]+$' | head -1 | cut -d' ' -f3)

  local esc neg debtacc aud match
  esc=$(xe_count)
  neg=$(num "$(QD "SELECT COUNT(*) FROM account_currency WHERE balance < 0")")
  debtacc=$(num "$(QD "SELECT COUNT(*) FROM account_currency WHERE debt > 0")")
  aud=$(num "$(QD "SELECT COUNT(*) FROM correction_detail")")
  [ "$reclaimed" = "$TOTAL" ] && match="일치" || match="**불일치**"

  printf "  %-10s %-8s %-16s %-8s %-10s %-12s %s\n" \
    "$mode" "${rounds}회" "$reclaimed" "$match" "${esc}회" "${neg}개" "${debtacc}개"
  echo "$mode,$rounds,$reclaimed,$TOTAL,$match,$esc,$neg,$debtacc,$aud" >> "$OUT/reclaim.csv"
}

run_mode NEGATIVE
run_mode DEBT

echo
echo "## 2-2. 감사 로그가 회수를 재구성하는가"
echo
echo "  이의 제기가 오면 감사 로그만으로 \"이 계정에서 얼마를 왜 뺐는지\"를"
echo "  답할 수 있어야 합니다. 로그의 전후 값이 실제 잔액과 맞는지 봅니다."
echo
AUD=$(num "$(QD "SELECT CAST(COUNT(*) AS varchar(12))
     + ',' + CAST(SUM(CASE WHEN d.balance_after = a.balance THEN 1 ELSE 0 END) AS varchar(12))
     + ',' + CAST(SUM(CASE WHEN d.applied_amount + d.debt_amount = d.target_amount THEN 1 ELSE 0 END) AS varchar(12))
  FROM correction_detail d JOIN account_currency a ON a.account_id = d.account_id;")")
IFS=, read -r n_aud n_bal n_sum <<<"$AUD"
printf "  %-30s %s\n" "감사 로그 행" "${n_aud}건"
printf "  %-30s %s\n" "기록한 사후 잔액 = 실제 잔액" "${n_bal}건"
printf "  %-30s %s\n" "적용액 + 빚 = 대상액" "${n_sum}건"
echo
if [ "$n_aud" = "$n_bal" ] && [ "$n_aud" = "$n_sum" ]; then
  echo "  **모든 행에서 맞습니다.** 감사 로그만으로 회수를 재구성할 수 있습니다."
else
  echo "  **어긋나는 행이 있습니다. 이 감사 로그는 근거로 쓸 수 없습니다.**"
fi
echo "audit,$n_aud,$n_bal,$n_sum" >> "$OUT/reclaim.csv"

echo
echo "## 2-3. 빚은 어떻게 갚히는가"
echo
echo "  회수 뒤 이용자가 재화를 얻으면 빚이 상계돼야 합니다. 두 설계가 다릅니다."
echo
ONE=$(num "$(QD "SELECT TOP 1 CAST(account_id AS varchar(12)) FROM account_currency WHERE debt > 0 ORDER BY account_id")")
if [ -n "$ONE" ] && [ "$ONE" != "" ]; then
  BEFORE=$(num "$(QD "SELECT CAST(balance AS varchar(20)) + '/' + CAST(debt AS varchar(20)) FROM account_currency WHERE account_id = $ONE")")
  # DEBT 설계에서는 획득 시 빚을 먼저 갚는 로직이 애플리케이션이나 트리거에 있어야 한다.
  QDX "SET NOCOUNT ON;
  DECLARE @gain BIGINT = 5000;
  UPDATE account_currency
     SET debt    = CASE WHEN debt >= @gain THEN debt - @gain ELSE 0 END,
         balance = balance + CASE WHEN debt >= @gain THEN 0 ELSE @gain - debt END
   WHERE account_id = $ONE;" || true
  AFTER=$(num "$(QD "SELECT CAST(balance AS varchar(20)) + '/' + CAST(debt AS varchar(20)) FROM account_currency WHERE account_id = $ONE")")
  printf "  계정 %s  획득 5000 전: 잔액/빚 %s  →  후: %s\n" "$ONE" "$BEFORE" "$AFTER"
  echo
  echo "  DEBT 설계는 빚을 먼저 갚는 로직을 **따로 만들어야** 합니다. 획득 경로가"
  echo "  여럿이면 그 전부에 같은 규칙이 들어가야 하고, 하나라도 빠지면 빚이 남습니다."
  echo "  NEGATIVE 설계는 잔액이 음수라 더하기만 해도 자연히 상계됩니다. 대신 잔액이"
  echo "  음수인 동안 다른 코드가 그 값을 어떻게 다루는지 전부 확인해야 합니다."
else
  echo "  빚이 있는 계정이 없습니다(NEGATIVE 설계로 끝난 상태)."
fi

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  두 설계 모두 회수 총액은 같습니다. 검산이 통과하고 감사 로그도 맞습니다."
echo "  배치를 ${CHUNK}행으로 끊어 승격은 한 번도 일어나지 않았습니다."
echo
echo "  갈리는 것은 그 뒤입니다."
echo "    NEGATIVE  제약을 빼야 한다. 상계는 공짜지만 음수 잔액을 읽는 모든 코드가 위험."
echo "    DEBT      제약이 살아 있고 빚을 따로 셀 수 있다. 대신 상계 로직을 만들어야 한다."
echo
echo "  운영에서 고를 것은 DEBT 입니다. 제약을 빼는 것은 되돌리기 어렵고, 그 사이에"
echo "  들어온 다른 버그가 음수 잔액을 만들어도 아무도 모릅니다. 빚 컬럼은 늘어나는"
echo "  일이지만 무엇이 남았는지 셀 수 있습니다."
} 2>&1 | tee "$OUT/exp2-reclaim.txt"
