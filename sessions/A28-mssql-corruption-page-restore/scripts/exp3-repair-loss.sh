#!/usr/bin/env bash
# 실험 3. 백업이 없다면 — REPAIR_ALLOW_DATA_LOSS 는 이름이 곧 경고다.
#
# 같은 손상을 백업 없는 DB 사본에 만들고 repair 로 고친다. 고쳐지긴 한다.
# 질문은 "몇 행이 사라졌고, 그걸 누가 알려 주는가"다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
exec > >(tee "$OUT/exp3-repair-loss.txt") 2>&1
DB2=corruption_lab_norepair

echo "# 실험 3. repair 의 값 — 사라진 행 수 실측"
echo
wait_ready || exit 2

echo "## 3-1. 백업 없는 사본을 같은 방식으로 손상"
Q "IF DB_ID('$DB2') IS NOT NULL BEGIN ALTER DATABASE [$DB2] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DB2]; END" >/dev/null
Q "CREATE DATABASE [$DB2]" >/dev/null
docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB2" -Q "SET NOCOUNT ON;
CREATE TABLE ledger (id INT IDENTITY(1,1) PRIMARY KEY, account_id INT NOT NULL, amount BIGINT NOT NULL, memo CHAR(80) NOT NULL DEFAULT 'x');
DECLARE @b INT = 0;
WHILE @b < 3
BEGIN
  WITH n AS (SELECT TOP ($ROWS / 3) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) i
               FROM sys.all_objects a CROSS JOIN sys.all_objects b)
  INSERT INTO ledger (account_id, amount) SELECT i % 50000, 100 + i % 900 FROM n;
  SET @b += 1;
END" >/dev/null
BEFORE=$(num "$(docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB2" -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM ledger")")
PAGE2=$(num "$(docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB2" -Q "SET NOCOUNT ON;
SELECT MAX(p) FROM (SELECT TOP 100 allocated_page_page_id AS p FROM sys.dm_db_database_page_allocations(DB_ID('$DB2'), OBJECT_ID('ledger'), 1, NULL, 'DETAILED')
 WHERE page_type = 1 AND is_allocated = 1 ORDER BY allocated_page_page_id) x;")")
Q "ALTER DATABASE [$DB2] SET OFFLINE WITH ROLLBACK IMMEDIATE" >/dev/null
docker exec -u root "$CT" dd if=/dev/zero of="/var/opt/mssql/data/${DB2}.mdf" bs=1 count=32 seek=$((PAGE2*8192+2048)) conv=notrunc status=none
Q "ALTER DATABASE [$DB2] SET ONLINE" >/dev/null
echo "  ${BEFORE}행 적재, 페이지 1:${PAGE2} 손상, 백업은 없다"
echo

echo "## 3-2. 단일 사용자 모드에서 REPAIR_ALLOW_DATA_LOSS"
Q "ALTER DATABASE [$DB2] SET SINGLE_USER WITH ROLLBACK IMMEDIATE" >/dev/null
Q "DBCC CHECKDB (N'$DB2', REPAIR_ALLOW_DATA_LOSS) WITH NO_INFOMSGS" | grep -iE 'repair|deallocat|Msg|메시지' | head -6
Q "ALTER DATABASE [$DB2] SET MULTI_USER" >/dev/null
echo

echo "## 3-3. 무엇이 사라졌나"
AFTER=$(num "$(docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB2" -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM ledger")")
CHECK=$(Q "DBCC CHECKDB (N'$DB2') WITH NO_INFOMSGS")
[ -z "$(echo "$CHECK" | tr -d ' \r\n')" ] && STATE="0 오류 (일관성은 회복됨)" || STATE="오류 잔존"
echo "  전: ${BEFORE}행 → 후: ${AFTER}행  =  사라진 행 $((BEFORE-AFTER))"
echo "  CHECKDB: ${STATE}"
echo
echo "결론: repair 는 페이지를 지워서 일관성을 산다. 사라진 $((BEFORE-AFTER))행은 어디에도"
echo "안 남는다 — 실험 2 의 페이지 복원(손실 0)과 이것의 차이가 로그 체인 하나다."
Q "DROP DATABASE [$DB2]" >/dev/null
