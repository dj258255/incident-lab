#!/usr/bin/env bash
# 실험 1. 손상은 어떻게 드러나는가.
#
# 백업 검증(A23·DBTower)은 "백업이 온전한가"를 본다. 이 실험의 질문은 그 다음이다.
# 지금 돌고 있는 DB 가 조용히 손상됐다면, 무엇이 언제 알려 주는가.
#
# 순서: FULL 복구 모델 DB → 원장 적재 → 전체 백업 → 백업 이후 행 추가(로그 체인이
# 되살려야 할 몫) → 로그 백업 → 데이터 페이지 하나를 파일에서 직접 몇 바이트 손상
# → 읽기가 824 로 죽는지, suspect_pages 에 적히는지, CHECKDB 가 잡는지.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
exec > >(tee "$OUT/exp1-detect.txt") 2>&1

echo "# 실험 1. 손상 탐지 — 읽기 824, suspect_pages, CHECKDB"
echo
wait_ready || exit 2

echo "## 1-1. 준비: FULL 복구 모델 + 원장 ${ROWS}행 + 백업 체인"
Q "IF DB_ID('$DB') IS NOT NULL BEGIN ALTER DATABASE [$DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DB]; END" >/dev/null
Q "CREATE DATABASE [$DB]" >/dev/null
Q "ALTER DATABASE [$DB] SET RECOVERY FULL" >/dev/null
QDX "SET NOCOUNT ON;
CREATE TABLE ledger (
    id     INT IDENTITY(1,1) PRIMARY KEY,
    account_id INT NOT NULL,
    amount BIGINT NOT NULL,
    memo   CHAR(80) NOT NULL DEFAULT 'x'   -- 행을 키워 페이지 수를 늘린다
);
DECLARE @b INT = 0;
WHILE @b < 3
BEGIN
  WITH n AS (SELECT TOP ($ROWS / 3) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) i
               FROM sys.all_objects a CROSS JOIN sys.all_objects b)
  INSERT INTO ledger (account_id, amount) SELECT i % 50000, 100 + i % 900 FROM n;
  SET @b += 1;
END" || exit 2
BASE=$(num "$(QD "SET NOCOUNT ON; SELECT COUNT(*) FROM ledger")")
SUM0=$(num "$(QD "SET NOCOUNT ON; SELECT SUM(amount) FROM ledger")")
echo "  적재 ${BASE}행, 금액 합계 ${SUM0}"

docker exec "$CT" mkdir -p /var/opt/mssql/backup
Q "BACKUP DATABASE [$DB] TO DISK='/var/opt/mssql/backup/a28_full.bak' WITH INIT, CHECKSUM" >/dev/null
echo "  전체 백업 완료 (WITH CHECKSUM)"

# 백업 이후의 행 — 페이지 복원 뒤에도 살아 있어야 로그 체인이 증명된다
QDX "INSERT INTO ledger (account_id, amount) SELECT 999999, 777 FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10)) v(x);" || exit 2
Q "BACKUP LOG [$DB] TO DISK='/var/opt/mssql/backup/a28_log1.trn' WITH INIT" >/dev/null
AFTER=$(num "$(QD "SET NOCOUNT ON; SELECT COUNT(*) FROM ledger")")
echo "  백업 뒤 10행 추가 → 총 ${AFTER}행, 로그 백업 1개"
echo

echo "## 1-2. 손상시킬 페이지 고르기 (중간쯤의 데이터 페이지)"
PAGE=$(num "$(QD "SET NOCOUNT ON;
SELECT MAX(p) FROM (
  SELECT TOP 100 allocated_page_page_id AS p
    FROM sys.dm_db_database_page_allocations(DB_ID('$DB'), OBJECT_ID('ledger'), 1, NULL, 'DETAILED')
   WHERE page_type = 1 AND is_allocated = 1
   ORDER BY allocated_page_page_id) x;")")
echo "  대상: 1:${PAGE} (파일 오프셋 $((PAGE*8192)))"
echo

echo "## 1-3. 파일에서 직접 32바이트를 지운다 (OFFLINE 상태에서)"
Q "ALTER DATABASE [$DB] SET OFFLINE WITH ROLLBACK IMMEDIATE" >/dev/null
docker exec -u root "$CT" dd if=/dev/zero of="/var/opt/mssql/data/${DB}.mdf" \
  bs=1 count=32 seek=$((PAGE*8192+2048)) conv=notrunc status=none
Q "ALTER DATABASE [$DB] SET ONLINE" >/dev/null
echo "  손상 완료, DB 는 다시 ONLINE — 겉보기로는 아무 일도 없다"
echo

echo "## 1-4. 그 페이지를 읽으면"
READ_OUT=$(QD "SET NOCOUNT ON; SELECT COUNT(*) AS c FROM ledger WITH (INDEX(1))")
echo "$READ_OUT" | grep -E 'Msg|메시지|incorrect|checksum' | head -4
echo

echo "## 1-5. msdb.dbo.suspect_pages — 엔진이 스스로 적었다"
Q "SET NOCOUNT ON; SELECT database_id, file_id, page_id, event_type, error_count FROM msdb.dbo.suspect_pages WHERE database_id = DB_ID('$DB')"
echo "  (event_type 1=823/824, 2=잘못된 체크섬, 3=찢어진 페이지)"
echo

echo "## 1-6. DBCC CHECKDB"
CHECK=$(Q "DBCC CHECKDB (N'$DB') WITH NO_INFOMSGS")
echo "$CHECK" | head -8
echo
echo "$PAGE" > "$OUT/corrupt-page.txt"
echo "결론: 손상은 읽기 전까지 조용하다. 읽기가 824 로 죽고, suspect_pages 에 남고,"
echo "CHECKDB 가 범위를 확정한다. 다음 실험이 그 페이지만 되돌린다."
