#!/usr/bin/env bash
# 실험 4. 보정 자체가 잘못됐을 때 되돌린다.
#
# 회수 대상 목록이 틀릴 수 있다. A24 의 통계 이탈이 정상 헤비 이용자 40개를 함께
# 지목한 것을 그대로 회수했다면 그렇다. 그때 되돌릴 방법이 있어야 한다.
#
# 벽시계 시각으로 되돌리면 경계에서 샌다. A23 이 네 엔진에서 확인한 성질이다.
# SQL Server 에는 지점에 이름을 붙이는 방법이 있다. BEGIN TRAN ... WITH MARK 로
# 표시를 남기고 RESTORE ... WITH STOPATMARK 로 그 지점까지만 되돌린다.
#
# 이 실험은 잘못된 목록으로 보정한 뒤 표시 지점으로 되돌리고, 올바른 목록으로
# 다시 보정한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
MARK='before_reclaim'
RDB="${DB}_restored"

wait_ready || exit 2
docker exec -u 0 "$CT" sh -c 'mkdir -p /var/opt/mssql/backup && chown -R 10001:0 /var/opt/mssql/backup' >/dev/null 2>&1

bal_sum(){ num "$(QD "SELECT ISNULL(SUM(balance),0) FROM account_currency")"; }
bal_sum_db(){ num "$(Q "SELECT ISNULL(SUM(balance),0) FROM [$1].dbo.account_currency")"; }

{
echo "# 실험 4. 잘못된 보정을 되돌린다"
echo
QFX "$(cat "$ROOT/scripts/reclaim.sql")" || exit 2

echo "## 4-1. 보정 전 상태와 전체 백업"
QDX "SET NOCOUNT ON;
DELETE FROM correction_detail;
DELETE FROM correction_batch;
DBCC CHECKIDENT('correction_batch', RESEED, 0) WITH NO_INFOMSGS;
UPDATE account_currency SET balance = 50000 + (account_id % 37) * 1000, debt = 0;" || exit 2
BEFORE=$(bal_sum)
printf "  %-26s %s\n" "보정 전 잔액 합계" "$BEFORE"

Q "IF DB_ID('$RDB') IS NOT NULL BEGIN ALTER DATABASE [$RDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$RDB]; END" >/dev/null
docker exec "$CT" sh -c 'rm -f /var/opt/mssql/backup/a25*.bak /var/opt/mssql/backup/a25*.trn' >/dev/null 2>&1
Q "BACKUP DATABASE [$DB] TO DISK='/var/opt/mssql/backup/a25full.bak' WITH INIT, COMPRESSION" >/dev/null
echo "  전체 백업 완료"
echo

echo "## 4-2. 되돌릴 지점에 이름을 붙인다"
# 표시는 트랜잭션 이름으로 남는다. 이 트랜잭션 자체는 아무 데이터도 안 바꿔도 된다.
QDX "SET NOCOUNT ON;
BEGIN TRAN $MARK WITH MARK '보정 직전';
  INSERT INTO correction_batch (reason, status) VALUES (N'[표시] 보정 직전 지점', 'MARK');
COMMIT TRAN $MARK;" || exit 2
echo "  BEGIN TRAN ${MARK} WITH MARK '보정 직전'"
echo

echo "## 4-3. 잘못된 목록으로 보정한다"
# 정상 계정 200개를 대상에 잘못 넣는다. A24 의 통계 이탈이 오탐한 것과 같은 모양이다.
QDX "SET NOCOUNT ON;
INSERT INTO reclaim_target (account_id, extra_rows, extra_amount)
SELECT TOP (200) account_id, 1, 9999
  FROM account_currency
 WHERE account_id > 900000
   AND NOT EXISTS (SELECT 1 FROM reclaim_target r WHERE r.account_id = account_currency.account_id)
 ORDER BY account_id;" || exit 2
WRONG_N=$(num "$(QD "SELECT COUNT(*) FROM reclaim_target WHERE account_id > 900000")")
QD "SET NOCOUNT ON;
    DECLARE @b INT;
    EXEC usp_ReclaimCurrency @reason = N'잘못된 목록으로 회수', @mode = 'DEBT',
                             @chunk = $CHUNK, @batch_id = @b OUTPUT;" >/dev/null
AFTER_WRONG=$(bal_sum)
printf "  %-26s %s\n" "잘못 포함된 정상 계정" "${WRONG_N}개"
printf "  %-26s %s\n" "잘못된 보정 뒤 잔액 합계" "$AFTER_WRONG"
echo

echo "## 4-4. 로그 백업 후 표시 지점으로 되돌린다"
Q "BACKUP LOG [$DB] TO DISK='/var/opt/mssql/backup/a25log.trn' WITH INIT" >/dev/null
Q "RESTORE DATABASE [$RDB] FROM DISK='/var/opt/mssql/backup/a25full.bak'
   WITH MOVE '$DB' TO '/var/opt/mssql/data/${RDB}.mdf',
        MOVE '${DB}_log' TO '/var/opt/mssql/data/${RDB}.ldf', NORECOVERY" >/dev/null
RES=$(Q "RESTORE LOG [$RDB] FROM DISK='/var/opt/mssql/backup/a25log.trn'
         WITH STOPATMARK='$MARK', RECOVERY")
STATE=$(num "$(Q "SELECT state_desc FROM sys.databases WHERE name='$RDB'")")
if [ "$STATE" != "ONLINE" ]; then
  echo "  **복원한 데이터베이스가 ${STATE} 입니다. 되돌리기 실패.**"
  echo "$RES" | grep -E '^(Msg|메시지)' | head -3
  exit 2
fi
RESTORED=$(bal_sum_db "$RDB")
printf "  %-26s %s\n" "복원 상태" "$STATE"
printf "  %-26s %s\n" "복원본의 잔액 합계" "$RESTORED"
echo
if [ "$RESTORED" = "$BEFORE" ]; then
  echo "  **보정 직전 상태로 정확히 돌아왔습니다.** 표시 지점 이후의 회수가 전부 사라졌습니다."
else
  echo "  **복원본이 보정 전과 다릅니다(${RESTORED} vs ${BEFORE}).**"
fi
echo

echo "## 4-5. 벽시계로 가리키면"
echo
echo "  같은 로그 백업을 시각으로 되돌려 봅니다. 표시가 아니라 초 단위 시각을 씁니다."
Q "IF DB_ID('${RDB}_ts') IS NOT NULL BEGIN ALTER DATABASE [${RDB}_ts] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${RDB}_ts]; END" >/dev/null
# 날짜와 시간 사이의 공백을 살려야 한다. num() 을 쓰면 붙어 버려 STOPAT 이 죽는다.
MARKTIME=$(numsp "$(Q "SELECT CONVERT(varchar(23), MAX(mark_time), 121) FROM msdb.dbo.logmarkhistory WHERE mark_name = '$MARK'")")
if [ -z "$MARKTIME" ] || echo "$MARKTIME" | grep -qE '^(Msg|메시지)'; then
  echo "  표시 시각을 못 읽어 이 절은 건너뜁니다."
else
  Q "RESTORE DATABASE [${RDB}_ts] FROM DISK='/var/opt/mssql/backup/a25full.bak'
     WITH MOVE '$DB' TO '/var/opt/mssql/data/${RDB}_ts.mdf',
          MOVE '${DB}_log' TO '/var/opt/mssql/data/${RDB}_ts.ldf', NORECOVERY" >/dev/null
  TS_ERR=$(Q "RESTORE LOG [${RDB}_ts] FROM DISK='/var/opt/mssql/backup/a25log.trn'
              WITH STOPAT='$MARKTIME', RECOVERY" | grep -E '^(Msg|메시지)' | head -1)
  TS_STATE=$(num "$(Q "SELECT state_desc FROM sys.databases WHERE name='${RDB}_ts'")")
  if [ "$TS_STATE" = "ONLINE" ]; then
    TS_SUM=$(bal_sum_db "${RDB}_ts")
    printf "  표시 시각 %s 로 복원: 잔액 합계 %s\n" "$MARKTIME" "$TS_SUM"
    if [ "$TS_SUM" = "$BEFORE" ]; then
      echo "  이 회차에서는 시각으로도 같은 결과가 나왔습니다. 표시가 남긴 시각을 그대로"
      echo "  썼기 때문입니다. 실무에서는 그 시각을 모르는 채 어림해야 하고, 초 단위"
      echo "  반올림 때문에 같은 초에 커밋된 것이 함께 딸려 옵니다."
    else
      echo "  **시각으로 되돌리니 결과가 다릅니다(${TS_SUM} vs ${BEFORE}).** 초 단위 경계에서 샙니다."
    fi
  else
    echo "  시각 복원이 ${TS_STATE} 로 남았습니다. ${TS_ERR}"
  fi
fi

{ echo "metric,value"
  echo "before_balance,$BEFORE"
  echo "after_wrong_reclaim,$AFTER_WRONG"
  echo "restored_stopatmark,$RESTORED"
  echo "wrong_accounts,$WRONG_N"
  echo "mark_time,${MARKTIME:-}"; } > "$OUT/undo.csv"

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  보정은 되돌릴 수 있어야 합니다. 회수 대상 목록이 틀릴 수 있기 때문입니다."
echo "  A24 의 통계 이탈이 정상 계정 40개를 지목한 것을 그대로 회수했다면 그 상황입니다."
echo
echo "  되돌릴 지점은 이름으로 잡습니다. 보정을 시작하기 전에 BEGIN TRAN ... WITH MARK"
echo "  로 표시를 남기면 그 이름으로 정확히 그 지점까지만 복원할 수 있습니다."
echo
echo "  **표시의 이점은 시각이 안 통해서가 아닙니다.** 이 실험에서 표시가 남긴 시각을"
echo "  그대로 STOPAT 에 넣으니 같은 결과가 나왔습니다. 이점은 **그 시각을 안다**는"
echo "  것입니다. 표시가 없으면 사고 뒤에 \"보정을 몇 시 몇 분에 시작했더라\"를 로그에서"
echo "  어림해야 하고, 초 단위 반올림 때문에 같은 초의 다른 커밋이 함께 딸려 옵니다."
echo
echo "  전제가 둘 있습니다. 복구 모델이 FULL 이어야 하고 로그 백업 체인이 이어져"
echo "  있어야 합니다. 둘 중 하나라도 없으면 표시를 남겨도 쓸 수 없습니다."
} 2>&1 | tee "$OUT/exp4-undo.txt"
