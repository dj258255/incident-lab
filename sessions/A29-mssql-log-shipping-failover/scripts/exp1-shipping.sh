#!/usr/bin/env bash
# 실험 1. 로그 전달 — 백업 파일이 곧 복제다.
#
# 로그 전달은 세 동작의 반복이다. 주에서 로그 백업 → 파일 복사 → 보조에서 복원.
# 보조를 STANDBY 로 두면 읽기가 되지만, 다음 복원 때마다 읽던 세션이 끊긴다.
# 이 실험은 그 반복을 두 라운드 돌리고, 보조가 어디까지 따라왔는지를 행 수로 판정한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
exec > >(tee "$OUT/exp1-shipping.txt") 2>&1

echo "# 실험 1. 로그 전달 — 주(a25) → 보조(a26)"
echo
wait_both || exit 2

echo "## 1-1. 주: FULL 복구 DB + 앱 로그인 + 원장 10,000행"
QS "IF DB_ID('$DB') IS NOT NULL BEGIN ALTER DATABASE [$DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DB]; END" >/dev/null
QP "IF DB_ID('$DB') IS NOT NULL BEGIN ALTER DATABASE [$DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DB]; END" >/dev/null
QP "IF SUSER_ID('app_login') IS NOT NULL DROP LOGIN app_login" >/dev/null
QS "IF SUSER_ID('app_login') IS NOT NULL DROP LOGIN app_login" >/dev/null
QP "CREATE DATABASE [$DB]; ALTER DATABASE [$DB] SET RECOVERY FULL;" >/dev/null
QP "CREATE LOGIN app_login WITH PASSWORD = 'App_Passw0rd!'" >/dev/null
QPD "CREATE USER app_login FOR LOGIN app_login; ALTER ROLE db_datareader ADD MEMBER app_login;" >/dev/null
QPD "SET NOCOUNT ON;
CREATE TABLE ledger (id INT IDENTITY(1,1) PRIMARY KEY, account_id INT NOT NULL, amount BIGINT NOT NULL, memo CHAR(60) NOT NULL DEFAULT 'x');
DECLARE @b INT = 0;
WHILE @b < 5
BEGIN
  WITH n AS (SELECT TOP (2000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) i FROM sys.all_objects a CROSS JOIN sys.all_objects b)
  INSERT INTO ledger (account_id, amount) SELECT i % 5000, 100 + i % 900 FROM n;
  SET @b += 1;
END" >/dev/null
P0=$(num "$(QPD "SET NOCOUNT ON; SELECT COUNT(*) FROM ledger")")
SID_P=$(num "$(QP "SET NOCOUNT ON; SELECT CONVERT(VARCHAR(100), suser_sid('app_login'), 1)")")
echo "  주: ${P0}행 · app_login SID = ${SID_P}"
echo

echo "## 1-2. 초기화: 전체 백업 → 복사 → 보조에 STANDBY 복원"
docker exec "$P" mkdir -p /var/opt/mssql/backup; docker exec "$S" mkdir -p /var/opt/mssql/backup
QP "BACKUP DATABASE [$DB] TO DISK='/var/opt/mssql/backup/a29_full.bak' WITH INIT, CHECKSUM" >/dev/null
ship a29_full.bak
QS "RESTORE DATABASE [$DB] FROM DISK='/var/opt/mssql/backup/a29_full.bak' WITH REPLACE, STANDBY='/var/opt/mssql/backup/a29_undo.dat'" | grep -E 'RESTORE|processed' | head -1
S0=$(num "$(QSD "SET NOCOUNT ON; SELECT COUNT(*) FROM ledger")")
echo "  보조(STANDBY, 읽기 전용): ${S0}행"
echo

echo "## 1-3. 반복 라운드: 쓰기 → 로그 백업 → 복사 → 복원 (두 번)"
for r in 1 2; do
  QPD "SET NOCOUNT ON; INSERT INTO ledger (account_id, amount) SELECT 777000 + $r, 500 FROM (VALUES (1),(2),(3),(4),(5)) v(x);" >/dev/null
  QP "BACKUP LOG [$DB] TO DISK='/var/opt/mssql/backup/a29_log$r.trn' WITH INIT" >/dev/null
  ship "a29_log$r.trn"
  QS "RESTORE LOG [$DB] FROM DISK='/var/opt/mssql/backup/a29_log$r.trn' WITH STANDBY='/var/opt/mssql/backup/a29_undo.dat'" >/dev/null
  PN=$(num "$(QPD "SET NOCOUNT ON; SELECT COUNT(*) FROM ledger")")
  SN=$(num "$(QSD "SET NOCOUNT ON; SELECT COUNT(*) FROM ledger")")
  echo "  라운드 $r: 주 ${PN}행 / 보조 ${SN}행"
done
echo

echo "## 1-4. 지연의 실체 — 아직 안 보낸 쓰기는 보조에 없다"
QPD "SET NOCOUNT ON; INSERT INTO ledger (account_id, amount) SELECT 888000, 999 FROM (VALUES (1),(2),(3)) v(x);" >/dev/null
PN=$(num "$(QPD "SET NOCOUNT ON; SELECT COUNT(*) FROM ledger")")
SN=$(num "$(QSD "SET NOCOUNT ON; SELECT COUNT(*) FROM ledger")")
echo "  주 ${PN}행 / 보조 ${SN}행 — 차이 $((PN-SN))행이 로그 전달의 RPO 다"
echo "$PN" > "$OUT/primary-final.txt"
echo
echo "결론: 로그 전달은 백업 체인의 자동화다. 보조는 마지막으로 복원된 로그까지만 안다."
echo "아직 백업 안 된 $((PN-SN))행을 어떻게 하느냐가 다음 실험(페일오버)이다."
