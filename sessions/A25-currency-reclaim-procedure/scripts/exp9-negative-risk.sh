#!/usr/bin/env bash
# 실험 9. 음수 잔액을 허용하면 무엇이 깨지는가.
#
# 실험 2는 NEGATIVE 설계를 "제약을 빼야 한다. 상계는 공짜지만 음수 잔액을 읽는 모든
# 코드가 위험"이라고 적고 넘어갔다. **위험하다고만 적고 무엇이 어떻게 깨지는지는
# 안 봤다.** 못 한 것에는 "애플리케이션 계층이라 다루지 않았다"고 썼다.
#
# 그 서술이 좁았다. 음수 잔액이 깨뜨리는 것 중 상당수는 **DB 안에 있다.**
# 대사 쿼리, 운영 지표, 그리고 무엇보다 제약 자체다. 그것을 잰다.
#
# 같은 회수를 두 설계에 똑같이 적용하고 넷을 본다.
#   1 총량 대사      발행량과 잔액 합계가 맞는가
#   2 미회수 잔량    아직 못 받은 금액을 셀 수 있는가
#   3 운영 지표      보유자 수와 평균 보유량이 같은가
#   4 제약의 방어    **회수와 무관한 버그가 음수를 만들 때 막히는가**
#
# 4번이 핵심이다. 제약을 뺀 이유는 회수 때문인데, 그 제약이 원래 막고 있던 것은
# 회수만이 아니다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
N=${NEG_ACCOUNTS:-100000}
RECLAIM=${NEG_RECLAIM:-800}    # 계정마다 회수할 금액

wait_ready || exit 2

# 두 표를 나란히 만든다. 시작 상태와 회수액이 같고 설계만 다르다.
#   acct_neg   제약 없음. 모자라면 잔액이 음수가 된다
#   acct_debt  CHECK(balance >= 0) 가 살아 있고 못 받은 만큼 debt 에 남는다
#
# 계정의 3분의 1은 잔액이 회수액보다 적게 만든다. 그래야 갈린다.
QDX "SET NOCOUNT ON;
DROP TABLE IF EXISTS acct_neg;
DROP TABLE IF EXISTS acct_debt;
CREATE TABLE acct_neg  (account_id INT NOT NULL PRIMARY KEY, balance BIGINT NOT NULL);
CREATE TABLE acct_debt (account_id INT NOT NULL PRIMARY KEY, balance BIGINT NOT NULL,
                        debt BIGINT NOT NULL DEFAULT 0,
                        CONSTRAINT CK_acct_debt_nonneg CHECK (balance >= 0));
WITH n AS (SELECT TOP ($N) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
             FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO acct_neg (account_id, balance)
SELECT i, CASE WHEN i % 3 = 0 THEN 200 ELSE 5000 END FROM n;
INSERT INTO acct_debt (account_id, balance, debt)
SELECT account_id, balance, 0 FROM acct_neg;" || exit 2

LOADED=$(num "$(QD "SELECT COUNT(*) FROM acct_neg")")
[ "$LOADED" = "$N" ] || { echo "중단: 적재가 ${LOADED}행입니다(기대 $N)" >&2; exit 2; }
ISSUED=$(num "$(QD "SELECT CAST(SUM(balance) AS varchar(30)) FROM acct_neg")")

{
echo "# 실험 9. 음수 잔액을 허용하면 무엇이 깨지는가"
echo
echo "  계정 ${N}개, 발행 총량 ${ISSUED}. 3분의 1은 잔액이 ${RECLAIM} 보다 적습니다."
echo "  같은 회수를 두 설계에 똑같이 적용합니다."
echo "    acct_neg   제약 없음. 모자라면 음수가 된다"
echo "    acct_debt  CHECK(balance >= 0) 가 살아 있고 못 받은 만큼 debt 로 간다"
echo

QDX "SET NOCOUNT ON;
UPDATE acct_neg  SET balance = balance - $RECLAIM;
UPDATE acct_debt SET balance = CASE WHEN balance >= $RECLAIM THEN balance - $RECLAIM ELSE 0 END,
                     debt    = debt + CASE WHEN balance >= $RECLAIM THEN 0 ELSE $RECLAIM - balance END;" || exit 2

: > "$OUT/negative-risk.csv"
echo "check,negative,debt,same" >> "$OUT/negative-risk.csv"

row(){ # $1=항목 $2=neg 값 $3=debt 값
  local same="같음"; [ "$2" = "$3" ] || same="**다름**"
  printf "  %-30s %-18s %-18s %s\n" "$1" "$2" "$3" "$same"
  echo "\"$1\",$2,$3,\"$same\"" >> "$OUT/negative-risk.csv"
}

echo "## 9-1. 회수 총액은 같은가"
echo
printf "  %-30s %-18s %-18s %s\n" "항목" "NEGATIVE" "DEBT" ""
NEG_TAKEN=$(num "$(QD "SELECT CAST($ISSUED - SUM(balance) AS varchar(30)) FROM acct_neg")")
# DEBT 는 실제로 뺀 것과 못 뺀 것을 나눠 들고 있다. 둘을 더해야 대상액이다.
DEBT_TAKEN=$(num "$(QD "SELECT CAST($ISSUED - SUM(balance) AS varchar(30)) FROM acct_debt")")
DEBT_OWED=$(num "$(QD "SELECT CAST(SUM(debt) AS varchar(30)) FROM acct_debt")")
row "실제로 뺀 금액" "$NEG_TAKEN" "$DEBT_TAKEN"
echo
echo "  뺀 금액이 다릅니다. NEGATIVE 는 잔액이 없어도 그냥 빼서 대상액을 전부 뺀 것으로"
echo "  치고, DEBT 는 있는 만큼만 빼고 나머지 ${DEBT_OWED} 을 빚으로 남깁니다."
echo "  **회수 대상액은 둘 다 $(( NEG_TAKEN )) 로 같습니다.** DEBT 는 그것을"
echo "  $(( DEBT_TAKEN )) + ${DEBT_OWED} 로 나눠 들고 있을 뿐입니다."
echo

echo "## 9-2. 아직 못 받은 금액을 셀 수 있는가"
echo
NEG_OWED=$(num "$(QD "SELECT CAST(-SUM(balance) AS varchar(30)) FROM acct_neg WHERE balance < 0")")
row "미회수 잔량" "$NEG_OWED" "$DEBT_OWED"
echo
echo "  여기까지는 NEGATIVE 도 셉니다. 음수 잔액을 다 더하면 됩니다."
echo "  **문제는 그 음수가 회수 때문인지 다른 이유인지 구분이 안 된다는 것입니다.**"
echo "  9-4 에서 그 상황을 만듭니다."
echo

echo "## 9-3. 운영 지표가 같은가"
echo
NEG_H=$(num "$(QD "SELECT CAST(COUNT(*) AS varchar(20)) FROM acct_neg  WHERE balance > 0")")
DEBT_H=$(num "$(QD "SELECT CAST(COUNT(*) AS varchar(20)) FROM acct_debt WHERE balance > 0")")
row "재화 보유 계정 수" "$NEG_H" "$DEBT_H"
NEG_A=$(num "$(QD "SELECT CAST(AVG(balance) AS varchar(20)) FROM acct_neg")")
DEBT_A=$(num "$(QD "SELECT CAST(AVG(balance) AS varchar(20)) FROM acct_debt")")
row "평균 보유량(전체)" "$NEG_A" "$DEBT_A"
NEG_S=$(num "$(QD "SELECT CAST(SUM(balance) AS varchar(30)) FROM acct_neg")")
DEBT_S=$(num "$(QD "SELECT CAST(SUM(balance) AS varchar(30)) FROM acct_debt")")
row "유통 중인 재화 총량" "$NEG_S" "$DEBT_S"
echo
echo "  보유 계정 수는 같습니다. 음수는 0 보다 크지 않으니 양쪽 다 빠집니다."
echo "  **평균과 총량이 다릅니다.** NEGATIVE 는 음수가 양수를 깎아 유통량을 실제보다"
echo "  적게 보고합니다. 실제로 세상에 나가 있는 재화는 DEBT 쪽 숫자입니다."
echo "  재화 총량을 보고 이벤트 지급량을 정하는 운영이라면 여기서 판단이 어긋납니다."
echo

echo "## 9-4. 제약이 막고 있던 것은 회수만이 아니었다"
echo
echo "  회수와 무관한 버그를 하나 던집니다. 차감 쿼리에서 WHERE 조건을 빠뜨려"
echo "  **모든 계정에서 재화를 빼는** 흔한 사고입니다."
echo
BUG_NEG=$(QD "UPDATE acct_neg  SET balance = balance - 100000;" 2>&1)
BUG_DEBT=$(QD "UPDATE acct_debt SET balance = balance - 100000;" 2>&1)
NMSG=$(echo "$BUG_NEG"  | grep -oE '^(Msg|메시지) [0-9]+' | head -1); NMSG=${NMSG:-통과(오류 없음)}
DMSG=$(echo "$BUG_DEBT" | grep -oE '^(Msg|메시지) [0-9]+' | head -1); DMSG=${DMSG:-통과(오류 없음)}
printf "  %-30s %-18s %s\n" "잘못된 대량 차감" "$NMSG" "$DMSG"
echo "\"잘못된 대량 차감\",\"$NMSG\",\"$DMSG\",\"**다름**\"" >> "$OUT/negative-risk.csv"
echo
NEG_BAD=$(num "$(QD "SELECT CAST(COUNT(*) AS varchar(20)) FROM acct_neg  WHERE balance < 0")")
DEBT_BAD=$(num "$(QD "SELECT CAST(COUNT(*) AS varchar(20)) FROM acct_debt WHERE balance < 0")")
row "음수가 된 계정 수" "$NEG_BAD" "$DEBT_BAD"
NEG_OWED2=$(num "$(QD "SELECT CAST(-SUM(balance) AS varchar(30)) FROM acct_neg WHERE balance < 0")")
DEBT_OWED2=$(num "$(QD "SELECT CAST(SUM(debt) AS varchar(30)) FROM acct_debt")")
row "이제 미회수 잔량은" "$NEG_OWED2" "$DEBT_OWED2"
echo
echo "  DEBT 는 ${DMSG} 로 막혔고 표가 그대로입니다. **제약이 버그를 잡았습니다.**"
echo "  NEGATIVE 는 통과했습니다. 그리고 아까 ${NEG_OWED} 이던 미회수 잔량이"
echo "  ${NEG_OWED2} 이 됐습니다. **회수로 생긴 음수와 버그로 생긴 음수가 같은 컬럼에"
echo "  섞여 구분이 안 됩니다.** 얼마를 더 받아야 하는지 아무도 모릅니다."
echo

QD "DROP TABLE IF EXISTS acct_neg; DROP TABLE IF EXISTS acct_debt;" >/dev/null

echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  실험 2가 \"음수 잔액을 읽는 모든 코드가 위험\"이라고만 적고 넘어간 자리입니다."
echo "  그때 저는 그것을 애플리케이션 문제로 밀어 뒀는데, **깨지는 것의 상당수가"
echo "  DB 안에 있었습니다.**"
echo
echo "  깨지지 않는 것부터 적습니다. 회수 대상액은 두 설계가 같고, 보유 계정 수처럼"
echo "  0 보다 큰지만 보는 지표도 같습니다. 미회수 잔량도 평시에는 양쪽 다 셉니다."
echo
echo "  깨지는 것은 셋입니다."
echo
echo "    유통 중인 재화 총량이 실제보다 적게 나온다"
echo "      음수가 양수를 깎습니다. 이 숫자로 이벤트 지급량을 정하면 판단이 어긋납니다."
echo
echo "    미회수 잔량이 다른 음수와 섞인다"
echo "      회수로 생긴 음수인지 버그로 생긴 음수인지 컬럼만 봐서는 모릅니다."
echo "      DEBT 는 잔액과 빚이 다른 컬럼이라 애초에 안 섞입니다."
echo
echo "    **제약이 원래 막던 다른 버그가 함께 풀린다**"
echo "      제약을 뺀 이유는 회수인데, 그 제약은 회수만 막고 있던 것이 아닙니다."
echo "      조건을 빠뜨린 차감 쿼리가 DEBT 에서는 Msg 547 로 즉시 막히고"
echo "      NEGATIVE 에서는 조용히 통과합니다."
echo
echo "  마지막 줄이 이 실험의 결론입니다. 제약은 **비용이 아니라 마지막 방어선**입니다."
echo "  회수 한 번을 편하게 하려고 그것을 빼면, 그 뒤로 들어오는 모든 실수가 같은"
echo "  구멍으로 지나갑니다. 그리고 그 구멍은 **다시 닫기 어렵습니다.** 이미 음수가"
echo "  들어간 표에는 CHECK 제약을 도로 붙일 수 없습니다."
echo
echo "  그래서 실험 2의 \"운영에서 고를 것은 DEBT\"라는 결론이 여기서 근거를 얻습니다."
echo "  그때는 판단이었고 지금은 측정입니다."
} 2>&1 | tee "$OUT/exp9-negative-risk.txt"
