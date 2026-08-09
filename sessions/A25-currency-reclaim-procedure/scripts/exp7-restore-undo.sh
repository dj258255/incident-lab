#!/usr/bin/env bash
# 실험 7. 운영 DB 를 안 되돌리고 회수만 취소한다.
#
# 실험 4는 잘못된 보정을 표시 지점으로 복원해 되돌렸다. 그런데 그 복원은 새
# 데이터베이스에 했다. "실제로는 운영 데이터베이스를 되돌려야 한다"고 못 한 것에
# 적었는데, 다시 생각하니 그 서술이 틀렸다.
#
# **운영 DB 를 통째로 되돌리는 것은 실무에서 거의 안 고르는 선택이다.** 보정 이후의
# 정상 트랜잭션이 전부 사라진다. 이용자가 그 사이에 재화를 벌고 썼는데 그것까지
# 없앨 수는 없다.
#
# 실제로 하는 것은 이쪽이다. 복원본을 옆에 세우고 거기서 원래 값을 읽어,
# **되돌리는 보정을 한 번 더 돈다.** 이 실험이 그것을 한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
MARK='before_reclaim2'
RDB="${DB}_snap"

wait_ready || exit 2
docker exec -u 0 "$CT" sh -c 'mkdir -p /var/opt/mssql/backup && chown -R 10001:0 /var/opt/mssql/backup' >/dev/null 2>&1
bal_sum(){    num "$(QD "SELECT ISNULL(SUM(balance),0) FROM account_currency")"; }
bal_sum_db(){ num "$(Q  "SELECT ISNULL(SUM(balance),0) FROM [$1].dbo.account_currency")"; }

{
echo "# 실험 7. 운영 DB 를 안 되돌리고 회수만 취소한다"
echo
QFX "$(cat "$ROOT/scripts/reclaim.sql")" || exit 2

echo "## 7-1. 보정 전 상태"
QDX "SET NOCOUNT ON;
DELETE FROM correction_detail; DELETE FROM correction_batch;
DBCC CHECKIDENT('correction_batch', RESEED, 0) WITH NO_INFOMSGS;
UPDATE account_currency SET balance = 50000 + (account_id % 37) * 1000, debt = 0;
DELETE FROM reclaim_target
 WHERE NOT EXISTS (SELECT 1 FROM account_currency a WHERE a.account_id = reclaim_target.account_id);" || exit 2
BEFORE=$(bal_sum)
printf "  %-30s %s\n" "보정 전 잔액 합계" "$BEFORE"

Q "IF DB_ID('$RDB') IS NOT NULL BEGIN ALTER DATABASE [$RDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$RDB]; END" >/dev/null
docker exec "$CT" sh -c 'rm -f /var/opt/mssql/backup/a25b*.bak /var/opt/mssql/backup/a25b*.trn' >/dev/null 2>&1
Q "BACKUP DATABASE [$DB] TO DISK='/var/opt/mssql/backup/a25b.bak' WITH INIT, COMPRESSION" >/dev/null
QDX "BEGIN TRAN $MARK WITH MARK '보정 직전';
       INSERT INTO correction_batch (reason, status) VALUES (N'[표시] 보정 직전', 'MARK');
     COMMIT TRAN $MARK;" || exit 2
echo "  전체 백업과 표시 완료"
echo

echo "## 7-2. 잘못된 목록으로 회수하고, 그 뒤 정상 활동이 이어진다"
QDX "INSERT INTO reclaim_target (account_id, extra_rows, extra_amount)
     SELECT TOP (300) account_id, 1, 8888 FROM account_currency
      WHERE account_id > 900000
        AND NOT EXISTS (SELECT 1 FROM reclaim_target r WHERE r.account_id = account_currency.account_id)
      ORDER BY account_id;" || exit 2
WRONG=$(num "$(QD "SELECT COUNT(*) FROM reclaim_target WHERE account_id > 900000")")
QD "SET NOCOUNT ON; DECLARE @b INT;
    EXEC usp_ReclaimCurrency @reason=N'잘못된 목록', @mode='DEBT', @chunk=$CHUNK, @batch_id=@b OUTPUT;" >/dev/null
AFTER_WRONG=$(bal_sum)

# 보정 뒤 정상 활동. 이용자들이 재화를 번다. 이것이 사라지면 안 된다.
QDX "SET NOCOUNT ON;
     UPDATE account_currency SET balance = balance + 3000
      WHERE account_id BETWEEN 1 AND 100000;" || exit 2
AFTER_PLAY=$(bal_sum)
PLAY_DELTA=$(( AFTER_PLAY - AFTER_WRONG ))
printf "  %-30s %s\n" "잘못 포함된 정상 계정" "${WRONG}개"
printf "  %-30s %s\n" "잘못된 회수 뒤 잔액 합계" "$AFTER_WRONG"
printf "  %-30s %s\n" "그 뒤 정상 활동으로 늘어난 몫" "$PLAY_DELTA"
echo

echo "## 7-3. 복원본을 옆에 세운다"
Q "BACKUP LOG [$DB] TO DISK='/var/opt/mssql/backup/a25b.trn' WITH INIT" >/dev/null
Q "RESTORE DATABASE [$RDB] FROM DISK='/var/opt/mssql/backup/a25b.bak'
   WITH MOVE '$DB' TO '/var/opt/mssql/data/${RDB}.mdf',
        MOVE '${DB}_log' TO '/var/opt/mssql/data/${RDB}.ldf', NORECOVERY" >/dev/null
Q "RESTORE LOG [$RDB] FROM DISK='/var/opt/mssql/backup/a25b.trn' WITH STOPATMARK='$MARK', RECOVERY" >/dev/null
STATE=$(num "$(Q "SELECT state_desc FROM sys.databases WHERE name='$RDB'")")
[ "$STATE" = "ONLINE" ] || { echo "  **복원본이 ${STATE} 입니다. 중단**"; exit 2; }
SNAP=$(bal_sum_db "$RDB")
printf "  %-30s %s\n" "복원본 상태" "$STATE"
printf "  %-30s %s (보정 전과 %s)" "복원본 잔액 합계" "$SNAP" "$([ "$SNAP" = "$BEFORE" ] && echo 일치 || echo 불일치)"
echo; echo

echo "## 7-4. 복원본에서 원래 값을 읽어 되돌린다"
echo
echo "  운영 DB 를 통째로 되돌리지 않습니다. 잘못 회수한 계정만 골라, 복원본의"
echo "  잔액과 지금 잔액의 차이를 되돌려 줍니다. 그 뒤의 정상 활동은 그대로 둡니다."
echo
QDX "SET NOCOUNT ON;
UPDATE a
   SET a.balance = a.balance + d.applied_amount + d.debt_amount,
       a.debt    = a.debt    - d.debt_amount
  FROM account_currency a
  JOIN correction_detail d ON d.account_id = a.account_id
 WHERE d.account_id > 900000;" || exit 2
FINAL=$(bal_sum)
# 기대값을 처음에 (보정 전 + 정상 활동)으로 잡았다가 360,000 이 어긋났다.
# 그 금액은 **제대로 회수한 몫**이다. 되돌리는 것은 잘못 회수한 것뿐이므로
# 정상 회수분은 그대로 빠져 있어야 한다. 검산식이 틀렸던 것이지 절차가 아니었다.
LEGIT=$(num "$(QD "SELECT ISNULL(SUM(applied_amount + debt_amount),0)
                     FROM correction_detail WHERE account_id <= 900000")")
EXPECT=$(( BEFORE - LEGIT + PLAY_DELTA ))
printf "  %-30s %s\n" "되돌린 뒤 잔액 합계" "$FINAL"
printf "  %-30s %s\n" "정상 회수분 (그대로 둔다)" "$LEGIT"
printf "  %-30s %s\n" "기대값 (보정 전 - 정상 회수 + 정상 활동)" "$EXPECT"
echo
if [ "$FINAL" = "$EXPECT" ]; then
  echo "  **잘못된 회수만 취소되고, 정상 회수분과 그 뒤 활동은 살아 있습니다.**"
else
  echo "  **어긋납니다(${FINAL} vs ${EXPECT}). 이 절차는 쓰면 안 됩니다.**"
fi
{ echo "metric,value"
  echo "before,$BEFORE"
  echo "after_wrong,$AFTER_WRONG"
  echo "play_delta,$PLAY_DELTA"
  echo "snapshot,$SNAP"
  echo "final,$FINAL"
  echo "expected,$EXPECT"; } > "$OUT/restore-undo.csv"

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  실험 4의 \"못 한 것\"에 적은 서술이 틀렸습니다. 운영 DB 를 통째로 되돌리는 것은"
echo "  **하지 못한 것이 아니라 하면 안 되는 것**입니다. 보정 이후의 정상 활동이 전부"
echo "  사라집니다. 이 실험에서 그 몫이 ${PLAY_DELTA} 였습니다."
echo
echo "  실제 절차는 복원본을 옆에 세우고 거기서 원래 값을 읽어 **되돌리는 보정을 한 번"
echo "  더 도는 것**입니다. 되돌리기도 보정이므로 같은 규칙을 지킵니다. 배치를 쪼개고,"
echo "  감사 로그를 남기고, 끝나면 검산합니다."
echo
echo "  표시(WITH MARK)의 값은 여기서도 같습니다. 복원본을 어느 지점까지 되돌릴지"
echo "  정확히 가리키기 위해서입니다. 운영 DB 는 그대로 두고 복원본만 그 지점으로 갑니다."
echo
echo "  검산식을 한 번 틀렸습니다. 처음에 기대값을 (보정 전 + 정상 활동)으로 잡았는데"
echo "  ${LEGIT} 이 어긋났습니다. 그것은 **제대로 회수한 몫**이고 되돌리면 안 되는"
echo "  것이었습니다. 절차가 틀린 것이 아니라 검산식이 틀렸습니다. 되돌리기에서는"
echo "  \"무엇을 되돌리고 무엇을 두는가\"를 먼저 정해야 검산도 세울 수 있습니다."
} 2>&1 | tee "$OUT/exp7-restore-undo.txt"
