#!/usr/bin/env bash
# 실험 14. 음수 잔액을 앱이 못 보게 막을 수 있는가.
#
# 못 한 것에 이렇게 적어 두었다.
#   "음수 잔액을 읽는 애플리케이션 코드는 여전히 안 봤습니다. DB 안에서 깨지는 것만
#    쟀습니다. 클라이언트가 음수를 어떻게 표시하고 계산하는지는 이 랩 밖입니다."
#
# **질문을 잘못 세웠다.** 실무의 답은 "앱 코드를 다 고친다"가 아니라
# **"앱이 음수를 볼 수 없게 한다"**이고, 그것은 DB 쪽 일이다.
#
# 앱이 기저 표가 아니라 뷰를 읽게 하고, 뷰가 음수를 0 으로 접어 내놓으면 앱 입장에서는
# 음수가 존재하지 않는다. 그 방어가 실제로 서는지, 무엇을 못 막는지 본다.
#
#   기저 표      NEGATIVE 설계. 잔액이 음수가 될 수 있다
#   보호 뷰      잔액은 0 이상으로 접고 음수분을 debt 로 나눠 내놓는다
#   권한         기저 표에 DENY SELECT, 뷰에만 GRANT SELECT
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
N=${SHIELD_ACCOUNTS:-100000}
RECLAIM=${SHIELD_RECLAIM:-800}

wait_ready || exit 2
AS(){ docker exec "$CT" "$SQLCMD" -S localhost -U "$1" -P 'Lab_Passw0rd!' -C -h -1 -W -d "$DB" -Q "$2" 2>&1; }
msg(){ echo "$1" | grep -oE '^(Msg|메시지) [0-9]+' | head -1; }

# 앱 계정 하나. 기저 표는 못 보고 뷰만 본다.
QD "IF SUSER_ID('game_app') IS NULL
      CREATE LOGIN game_app WITH PASSWORD = 'Lab_Passw0rd!', CHECK_POLICY = OFF;
    ELSE
      ALTER LOGIN game_app WITH PASSWORD = 'Lab_Passw0rd!', CHECK_POLICY = OFF;" >/dev/null
QDX "IF DATABASE_PRINCIPAL_ID('game_app') IS NULL CREATE USER game_app FOR LOGIN game_app;" || exit 2
[ "$(num "$(AS game_app "SELECT 'O'+'K'")")" = "OK" ] || { echo "중단: game_app 로 못 붙습니다" >&2; exit 2; }

{
echo "# 실험 14. 음수 잔액을 앱이 못 보게 막을 수 있는가"
echo
echo "  실험 10은 음수 잔액이 DB 안에서 무엇을 깨뜨리는지 쟀고, 앱 계층은 랩 밖이라고"
echo "  적었습니다. **질문이 틀렸습니다.** 실무의 답은 앱 코드를 다 고치는 것이 아니라"
echo "  **앱이 음수를 볼 수 없게 하는 것**이고, 그것은 DB 쪽 일입니다."
echo

QDX "SET NOCOUNT ON;
DROP VIEW IF EXISTS v_account_currency;
DROP TABLE IF EXISTS acct_neg2;
CREATE TABLE acct_neg2 (account_id INT NOT NULL PRIMARY KEY, balance BIGINT NOT NULL);
WITH n AS (SELECT TOP ($N) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
             FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO acct_neg2 (account_id, balance)
SELECT i, CASE WHEN i % 3 = 0 THEN 200 ELSE 5000 END FROM n;" || exit 2
ISSUED=$(num "$(QD "SELECT CAST(SUM(balance) AS varchar(30)) FROM acct_neg2")")
QDX "SET NOCOUNT ON; UPDATE acct_neg2 SET balance = balance - $RECLAIM;" || exit 2

# 보호 뷰. 앱이 볼 모양을 여기서 정한다. DEBT 설계와 같은 두 컬럼을 내놓는다.
QF "SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
CREATE OR ALTER VIEW v_account_currency
AS
SELECT account_id,
       CASE WHEN balance < 0 THEN 0 ELSE balance END AS balance,
       CASE WHEN balance < 0 THEN -balance ELSE 0 END AS debt
  FROM acct_neg2;
GO" >/dev/null

QDX "DENY SELECT ON acct_neg2 TO game_app;
     GRANT SELECT ON v_account_currency TO game_app;" || exit 2

: > "$OUT/negative-shield.csv"
echo "check,through,value,note" >> "$OUT/negative-shield.csv"
printf "  %-30s %-16s %-18s %s\n" "확인" "무엇으로" "값" "비고"

probe(){ # $1=라벨 $2=경로 $3=SQL $4=비고
  local v; v=$(num "$(AS game_app "SET NOCOUNT ON; $3")")
  local m; m=$(msg "$(AS game_app "SET NOCOUNT ON; $3")")
  [ -n "$m" ] && v="$m"
  printf "  %-30s %-16s %-18s %s\n" "$1" "$2" "$v" "$4"
  echo "\"$1\",\"$2\",\"$v\",\"$4\"" >> "$OUT/negative-shield.csv"
}

echo "### 14-1. 앱이 기저 표를 볼 수 있는가"
echo
probe "기저 표를 직접 읽는다" "기저 표" \
  "SELECT CAST(COUNT(*) AS varchar(12)) FROM acct_neg2;" "막혀야 한다"
probe "뷰로 읽는다" "보호 뷰" \
  "SELECT CAST(COUNT(*) AS varchar(12)) FROM v_account_currency;" "되어야 한다"
echo
echo "  **기저 표는 막히고 뷰만 열립니다.** 실험 8의 프로시저 강제와 같은 방법입니다."
echo "  규칙을 앱에 맡기지 않고 DB 가 볼 수 있는 모양 자체를 정합니다."
echo

echo "### 14-2. 뷰로 보면 실험 10에서 깨지던 것이 서는가"
echo
NEG_MIN=$(num "$(QD "SELECT CAST(MIN(balance) AS varchar(20)) FROM acct_neg2")")
printf "  %-30s %-16s %-18s %s\n" "가장 낮은 잔액" "기저 표" "$NEG_MIN" "음수다"
echo "\"가장 낮은 잔액\",\"기저 표\",\"$NEG_MIN\",\"음수다\"" >> "$OUT/negative-shield.csv"
probe "가장 낮은 잔액" "보호 뷰" \
  "SELECT CAST(MIN(balance) AS varchar(20)) FROM v_account_currency;" "0 이어야 한다"

RAW_SUM=$(num "$(QD "SELECT CAST(SUM(balance) AS varchar(30)) FROM acct_neg2")")
printf "  %-30s %-16s %-18s %s\n" "유통 중인 재화 총량" "기저 표" "$RAW_SUM" "음수가 깎는다"
echo "\"유통 중인 재화 총량\",\"기저 표\",\"$RAW_SUM\",\"음수가 깎는다\"" >> "$OUT/negative-shield.csv"
probe "유통 중인 재화 총량" "보호 뷰" \
  "SELECT CAST(SUM(balance) AS varchar(30)) FROM v_account_currency;" "실제 유통량"
probe "미회수 잔량" "보호 뷰" \
  "SELECT CAST(SUM(debt) AS varchar(30)) FROM v_account_currency;" "따로 셀 수 있다"
echo
echo "  **뷰를 통과하면 실험 10에서 갈리던 세 지표가 DEBT 설계와 같아집니다.**"
echo "  앱은 음수를 못 보고, 유통량은 실제 값이 나오고, 미회수 잔량은 따로 셉니다."
echo

echo "### 14-3. 뷰가 못 막는 것"
echo
echo "  그러면 NEGATIVE 로 가도 되는가. **아닙니다.** 뷰가 못 막는 자리가 남습니다."
echo
BUG=$(QD "UPDATE acct_neg2 SET balance = balance - 100000;")
BUGMSG=$(msg "$BUG"); BUGMSG=${BUGMSG:-통과(오류 없음)}
BAD=$(num "$(QD "SELECT CAST(COUNT(*) AS varchar(12)) FROM acct_neg2 WHERE balance < 0")")
printf "  %-30s %-16s %-18s %s\n" "조건 빠뜨린 대량 차감" "기저 표" "$BUGMSG" "제약이 없다"
echo "\"조건 빠뜨린 대량 차감\",\"기저 표\",\"$BUGMSG\",\"제약이 없다\"" >> "$OUT/negative-shield.csv"
probe "그 뒤 미회수 잔량" "보호 뷰" \
  "SELECT CAST(SUM(debt) AS varchar(30)) FROM v_account_currency;" "버그분이 섞였다"
echo
echo "  **뷰는 보여 주는 모양만 바꿉니다.** 잘못된 차감을 막지 못하고, 그 결과로 생긴"
echo "  음수도 회수로 생긴 음수와 똑같이 debt 로 보여 줍니다. 실험 10의 결론이"
echo "  그대로 남습니다. **뷰는 표시를 고치지 무결성을 지키지 않습니다.**"
echo
echo "  그리고 뷰로 DEBT 를 흉내 내는 순간 **DEBT 설계와 하는 일이 같아집니다.**"
echo "  같은 두 컬럼을 앱에 내주면서 제약만 잃은 셈입니다. 그러면 처음부터 컬럼을"
echo "  나누는 쪽이 낫습니다."
echo

echo "### 14-4. 반대로 DEBT 설계에 같은 뷰를 씌우면"
echo
QDX "SET NOCOUNT ON;
DROP VIEW IF EXISTS v_account_debt;
DROP TABLE IF EXISTS acct_debt2;
CREATE TABLE acct_debt2 (account_id INT NOT NULL PRIMARY KEY, balance BIGINT NOT NULL,
                         debt BIGINT NOT NULL DEFAULT 0,
                         CONSTRAINT CK_acct_debt2 CHECK (balance >= 0));
WITH n AS (SELECT TOP ($N) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
             FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO acct_debt2 (account_id, balance, debt)
SELECT i, CASE WHEN i % 3 = 0 THEN 200 ELSE 5000 END, 0 FROM n;
UPDATE acct_debt2
   SET balance = CASE WHEN balance >= $RECLAIM THEN balance - $RECLAIM ELSE 0 END,
       debt    = debt + CASE WHEN balance >= $RECLAIM THEN 0 ELSE $RECLAIM - balance END;" || exit 2
QF "SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
CREATE OR ALTER VIEW v_account_debt AS
SELECT account_id, balance, debt FROM acct_debt2;
GO" >/dev/null
QDX "DENY SELECT ON acct_debt2 TO game_app;
     GRANT SELECT ON v_account_debt TO game_app;" || exit 2

BUG2=$(QD "UPDATE acct_debt2 SET balance = balance - 100000;")
BUG2MSG=$(msg "$BUG2"); BUG2MSG=${BUG2MSG:-통과(오류 없음)}
printf "  %-30s %-16s %-18s %s\n" "같은 대량 차감" "기저 표" "$BUG2MSG" "제약이 막는다"
echo "\"같은 대량 차감(DEBT)\",\"기저 표\",\"$BUG2MSG\",\"제약이 막는다\"" >> "$OUT/negative-shield.csv"
probe "그 뒤 미회수 잔량" "보호 뷰" \
  "SELECT CAST(SUM(debt) AS varchar(30)) FROM v_account_debt;" "회수분만 남는다"

QD "DROP VIEW IF EXISTS v_account_currency; DROP VIEW IF EXISTS v_account_debt;
    DROP TABLE IF EXISTS acct_neg2; DROP TABLE IF EXISTS acct_debt2;" >/dev/null

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  못 한 것에 \"앱 계층이라 이 랩 밖\"이라고 적은 것은 **질문을 잘못 세운 것**이었습니다."
echo "  앱이 음수를 어떻게 다루는지 묻는 대신 **앱이 음수를 보게 둘 것인가**를 물으면"
echo "  DB 안에서 답이 나옵니다."
echo
echo "  뷰로 접고 기저 표를 막으면 앱은 음수를 못 봅니다. 실험 10에서 갈리던 지표"
echo "  (최소 잔액, 유통 총량, 미회수 잔량)가 전부 DEBT 설계와 같아집니다."
echo "  **표시 계층 위험은 DB 에서 막을 수 있습니다.**"
echo
echo "  그런데 그 방어에는 두 가지가 남습니다."
echo
echo "    뷰는 **표시를 고치지 무결성을 지키지 않습니다.** 조건을 빠뜨린 차감이"
echo "    그대로 통과하고, 그 음수는 회수로 생긴 음수와 구분되지 않습니다"
echo
echo "    뷰로 balance 와 debt 를 나눠 내주는 순간 **DEBT 설계와 하는 일이 같습니다.**"
echo "    같은 결과를 제약 없이 얻는 셈이라, 애초에 컬럼을 나누는 쪽이 낫습니다"
echo
echo "  **그래서 실험 10의 결론이 뒤집히지 않고 오히려 좁혀집니다.** NEGATIVE 를"
echo "  고르더라도 앱을 지키려면 결국 뷰로 DEBT 모양을 만들어야 하고, 그러느니"
echo "  컬럼을 나누고 제약을 살리는 편이 낫습니다."
echo
echo "  운영으로 옮기면 이렇게 됩니다."
echo "    앱은 기저 표가 아니라 **뷰를 읽는다.** 기저 표에는 DENY SELECT"
echo "    뷰는 표시 계층이다. 무결성은 **제약이 지킨다**"
echo "    설계를 고를 때 \"앱이 어떻게 읽을까\"가 아니라 \"앱이 무엇을 볼 수 있게 할까\"를 묻는다"
} 2>&1 | tee "$OUT/exp14-negative-shield.txt"
