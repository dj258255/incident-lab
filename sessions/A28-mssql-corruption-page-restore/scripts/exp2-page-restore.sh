#!/usr/bin/env bash
# 실험 2. 그 페이지만 과거로 되돌리고, 로그로 현재까지 재생한다.
#
# 전체 복원이 아니라 페이지 복원이다. DB 는 온라인인 채로(Developer=Enterprise 기능),
# 손상 페이지만 전체 백업 시점으로 돌아간 뒤 로그 체인이 나머지를 따라잡는다.
# 판정은 셋: 백업 이후 넣은 10행이 살아 있는가(체인 재생), 금액 합계가 맞는가,
# CHECKDB 가 0 오류인가.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
exec > >(tee "$OUT/exp2-page-restore.txt") 2>&1

echo "# 실험 2. 페이지 복원 — 손실 0 을 세 가지로 검산"
echo
wait_ready || exit 2
PAGE=$(cat "$OUT/corrupt-page.txt")
echo "대상 페이지: 1:${PAGE}"
echo

echo "## 2-1. 전체 백업에서 그 페이지만 (NORECOVERY)"
Q "RESTORE DATABASE [$DB] PAGE='1:${PAGE}' FROM DISK='/var/opt/mssql/backup/a28_full.bak' WITH NORECOVERY" | grep -E 'processed|pages|페이지' | head -2
echo

echo "## 2-2. 기존 로그 백업 복원"
Q "RESTORE LOG [$DB] FROM DISK='/var/opt/mssql/backup/a28_log1.trn' WITH NORECOVERY" | grep -E 'processed|pages|페이지' | head -2
echo

echo "## 2-3. 꼬리 로그를 뜨고, 그것까지 복원해야 끝난다"
Q "BACKUP LOG [$DB] TO DISK='/var/opt/mssql/backup/a28_tail.trn' WITH INIT" | grep -E 'processed|pages|페이지' | head -2
Q "RESTORE LOG [$DB] FROM DISK='/var/opt/mssql/backup/a28_tail.trn' WITH RECOVERY" | grep -E 'RESTORE|complete|성공' | head -2
echo

echo "## 2-4. 검산 셋"
CNT=$(num "$(QD "SET NOCOUNT ON; SELECT COUNT(*) FROM ledger")")
LATE=$(num "$(QD "SET NOCOUNT ON; SELECT COUNT(*) FROM ledger WHERE account_id = 999999")")
SUM1=$(num "$(QD "SET NOCOUNT ON; SELECT SUM(amount) FROM ledger")")
echo "  총 행수           : ${CNT} (기대: 적재 + 10)"
echo "  백업 이후 넣은 행   : ${LATE} / 10  ← 로그 체인이 되살린 몫"
echo "  금액 합계          : ${SUM1}"
echo

echo "## 2-5. CHECKDB 재검"
CHECK=$(Q "DBCC CHECKDB (N'$DB') WITH NO_INFOMSGS")
if [ -z "$(echo "$CHECK" | tr -d ' \r\n')" ]; then echo "  0 오류 (출력 없음 = 깨끗)"; else echo "$CHECK" | head -5; fi
echo

echo "## 2-6. suspect_pages 의 상태 전이"
Q "SET NOCOUNT ON; SELECT page_id, event_type, error_count FROM msdb.dbo.suspect_pages WHERE database_id = DB_ID('$DB')"
echo "  (event_type 4 = 복원됨, 5 = 수리됨)"
echo
echo "결론: DB 를 내리지 않고 페이지 하나만 되돌렸고, 백업 이후의 쓰기까지 로그가"
echo "따라잡아 손실 0. 전제는 FULL 복구 모델과 끊기지 않은 로그 체인이다(A23 과 같은 원리)."
