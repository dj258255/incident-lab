#!/usr/bin/env bash
# 실험 3. 승격의 마지막 관문 — 로그인은 DB 를 따라오지 않는다.
#
# 사용자는 DB 안에 살아 백업을 따라오지만, 로그인은 master 에 살아 안 따라온다.
# 승격된 보조에서 앱이 접속을 시도하면 그때 드러난다. SID 로 진단하고,
# ALTER USER ... WITH LOGIN 으로 수리하고, WITH SID 로 예방까지 실측한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
exec > >(tee "$OUT/exp3-orphan.txt") 2>&1

echo "# 실험 3. 고아 사용자 — SID 가 안 맞으면 접속이 없다"
echo
wait_both || exit 2

echo "## 3-1. 승격된 보조에 앱이 접속하면"
T1=$(docker exec "$S" "$SQLCMD" -S localhost -U app_login -P 'App_Passw0rd!' -C -h -1 -W -l 5 -d "$DB" -Q "SELECT 1" 2>&1 | head -1)
echo "  app_login 접속: $(echo "$T1" | cut -c1-70)"
echo "  — 로그인은 master 에 살아서 DB 백업을 안 따라온다"
echo

echo "## 3-2. 보조에 같은 이름의 로그인을 만들어도 (새 SID)"
QS "CREATE LOGIN app_login WITH PASSWORD = 'App_Passw0rd!'" >/dev/null
T2=$(docker exec "$S" "$SQLCMD" -S localhost -U app_login -P 'App_Passw0rd!' -C -h -1 -W -l 5 -d "$DB" -Q "SELECT 1" 2>&1 | head -1)
echo "  app_login 으로 $DB 접속: $(echo "$T2" | cut -c1-70)"
echo

echo "## 3-3. 진단 — DB 사용자와 서버 로그인의 SID 대조"
QSD "SET NOCOUNT ON;
SELECT dp.name,
       CONVERT(VARCHAR(40), dp.sid, 1)                 AS user_sid,
       ISNULL(CONVERT(VARCHAR(40), sp.sid, 1), '(없음)') AS login_sid,
       CASE WHEN sp.sid IS NULL THEN N'고아' WHEN dp.sid = sp.sid THEN N'정상' ELSE N'불일치' END AS verdict
  FROM sys.database_principals dp
  LEFT JOIN sys.server_principals sp ON dp.name = sp.name
 WHERE dp.name = 'app_login';"
echo

echo "## 3-4. 수리 — ALTER USER ... WITH LOGIN"
QSD "ALTER USER app_login WITH LOGIN = app_login" >/dev/null
T3=$(docker exec "$S" "$SQLCMD" -S localhost -U app_login -P 'App_Passw0rd!' -C -h -1 -W -l 5 -d "$DB" -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM ledger" 2>&1 | head -1)
echo "  수리 후 app_login 조회: $(num "$T3")행 — 접속이 살았다"
QSD "SET NOCOUNT ON;
SELECT CASE WHEN dp.sid = sp.sid THEN N'정상 (SID 일치)' END
  FROM sys.database_principals dp JOIN sys.server_principals sp ON dp.name = sp.name
 WHERE dp.name = 'app_login';"
echo

echo "## 3-5. 예방 — 처음부터 SID 째 만들었다면"
SID_P=$(num "$(QP "SET NOCOUNT ON; SELECT CONVERT(VARCHAR(100), suser_sid('app_login'), 1)")")
echo "  주의 SID: ${SID_P}"
echo "  보조에 CREATE LOGIN app_login WITH PASSWORD=..., SID = ${SID_P} 로 만들었으면"
echo "  복원 즉시 일치했다. sp_help_revlogin 이 자동화하는 것이 정확히 이것이다."
echo
echo "결론: 페일오버 절차의 마지막 줄은 DB 가 아니라 로그인이다. 복원·승격이 끝나도"
echo "SID 가 안 맞으면 앱은 못 들어온다. 이관 전에 SID 째 옮기는 것이 예방이고,"
echo "사후에는 ALTER USER ... WITH LOGIN 한 줄이 수리다."
