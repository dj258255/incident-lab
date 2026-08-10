#!/usr/bin/env bash
# 실험 17. 음수 잔액을 읽는 쪽이 각각 어떻게 틀리는가.
#
# 못 한 것에 이렇게 적어 두었다.
#   "음수 잔액을 읽는 클라이언트 코드는 안 봤습니다. 상점·랭킹·통계 코드가 각각
#    어떻게 깨지는지는 애플리케이션 계층이라 이 랩 밖입니다."
#
# **또 선을 잘못 그었다.** 음수가 실제로 깨뜨리는 것은 앱의 화면이 아니라 **쿼리**다.
#   상점  WHERE balance >= @price      -- 살 수 있는지 판정
#   랭킹  ORDER BY balance DESC        -- 정렬
#   통계  SUM / AVG / 백분위            -- 집계
#   충전  UPDATE ... SET balance += @n -- 상계
# 전부 DB 안에 있고 전부 잴 수 있다. 앱 코드를 안 봐도 **무엇이 틀리는지는 여기서 난다.**
#
# 같은 회수를 두 설계에 적용하고 네 종류의 읽기를 각각 던진다.
#   NEGATIVE  제약을 빼고 잔액을 음수로 내린다
#   DEBT      잔액은 0 에서 멈추고 못 받은 만큼을 debt 에 적는다
# 그리고 실험 14의 보호 뷰를 NEGATIVE 위에 얹어 **뷰가 어디까지 고치는지**까지 본다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
N=${READER_ACCOUNTS:-100000}
RECLAIM=${READER_RECLAIM:-800}
PRICE=${READER_PRICE:-1000}

wait_ready || exit 2

# ── 표 셋. 같은 사람들, 같은 회수, 다른 설계 ────────────────────────────
QDX "SET NOCOUNT ON;
DROP VIEW  IF EXISTS v_reader_neg;
DROP TABLE IF EXISTS rd_neg;
DROP TABLE IF EXISTS rd_debt;

CREATE TABLE rd_neg  (account_id INT NOT NULL PRIMARY KEY, balance BIGINT NOT NULL);
CREATE TABLE rd_debt (account_id INT NOT NULL PRIMARY KEY, balance BIGINT NOT NULL,
                      debt BIGINT NOT NULL DEFAULT 0);

-- 3명 중 1명은 잔액이 얼마 없다. 그들이 회수로 음수가 된다.
WITH n AS (SELECT TOP ($N) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
             FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO rd_neg (account_id, balance)
SELECT i, CASE WHEN i % 3 = 0 THEN 200 ELSE 5000 END FROM n;
INSERT INTO rd_debt (account_id, balance, debt) SELECT account_id, balance, 0 FROM rd_neg;" || exit 2

BEFORE_SUM=$(num "$(QD "SELECT CAST(SUM(balance) AS varchar(30)) FROM rd_neg")")
BEFORE_CNT=$(num "$(QD "SELECT CAST(COUNT(*) AS varchar(20)) FROM rd_neg WHERE balance > 0")")

# 같은 금액을 두 설계에 회수한다.
QDX "SET NOCOUNT ON;
UPDATE rd_neg SET balance = balance - $RECLAIM;
UPDATE rd_debt
   SET balance = CASE WHEN balance >= $RECLAIM THEN balance - $RECLAIM ELSE 0 END,
       debt    = debt + CASE WHEN balance >= $RECLAIM THEN 0 ELSE $RECLAIM - balance END;" || exit 2

# 실험 14의 보호 뷰를 NEGATIVE 위에 얹는다.
QF "SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
CREATE OR ALTER VIEW v_reader_neg
AS
SELECT account_id,
       CASE WHEN balance < 0 THEN 0 ELSE balance END AS balance,
       CASE WHEN balance < 0 THEN -balance ELSE 0 END AS debt
  FROM rd_neg;
GO" >/dev/null

row(){ printf "  %-26s %-16s %-16s %s\n" "$1" "$2" "$3" "$4"; }
csv(){ echo "\"$1\",\"$2\",\"$3\",\"$4\"" >> "$OUT/negative-readers.csv"; }

: > "$OUT/negative-readers.csv"
echo "reader,negative,debt,view" >> "$OUT/negative-readers.csv"

{
echo "# 실험 17. 음수 잔액을 읽는 쪽이 각각 어떻게 틀리는가"
echo
echo "  실험 14는 앱이 음수를 못 보게 뷰로 가렸고, **읽는 쪽이 각각 어떻게 틀리는지**는"
echo "  앱 계층이라며 안 봤습니다. 그것도 선을 잘못 그은 것입니다. 음수가 깨뜨리는 것은"
echo "  화면이 아니라 **쿼리**이고, 쿼리는 DB 안에 있습니다."
echo
printf "  %-26s %s\n" "계정" "${N}개 (3명 중 1명은 잔액 200)"
printf "  %-26s %s\n" "회수액" "전원 ${RECLAIM}"
printf "  %-26s %s\n" "회수 전 유통량" "$BEFORE_SUM"
printf "  %-26s %s\n" "회수 전 보유 계정" "$BEFORE_CNT"
echo

echo "=================================================================="
echo "## 17-1. 네 종류의 읽기를 같은 데이터에 던진다"
echo "=================================================================="
echo
echo "  왼쪽이 NEGATIVE 설계(제약을 뺀 표), 가운데가 DEBT 설계,"
echo "  오른쪽이 NEGATIVE 위에 실험 14의 보호 뷰를 얹은 것입니다."
echo
row "읽는 쪽" "NEGATIVE" "DEBT" "보호 뷰"
echo "  ------------------------------------------------------------------------"

# ── (1) 상점: 살 수 있는 사람 수 ────────────────────────────────────────
# 가격 이상 가진 사람만 살 수 있다. 음수는 당연히 못 산다. 여기는 안 틀린다.
S_NEG=$(num "$(QD  "SELECT CAST(COUNT(*) AS varchar(20)) FROM rd_neg  WHERE balance >= $PRICE")")
S_DBT=$(num "$(QD  "SELECT CAST(COUNT(*) AS varchar(20)) FROM rd_debt WHERE balance >= $PRICE")")
S_VW=$(num "$(QD   "SELECT CAST(COUNT(*) AS varchar(20)) FROM v_reader_neg WHERE balance >= $PRICE")")
row "상점: 살 수 있는 계정" "$S_NEG" "$S_DBT" "$S_VW"
csv "상점 구매가능" "$S_NEG" "$S_DBT" "$S_VW"

# ── (2) 상점의 다른 판정: 잔액 부족 안내 ────────────────────────────────
# **여기가 갈린다.** "얼마 모자란가"를 price - balance 로 계산하면 음수에서는
# 실제 필요액보다 부풀어 나온다. 회수당한 사람에게 빚까지 채우라고 요구하는 셈이다.
L_NEG=$(num "$(QD "SELECT CAST(MAX($PRICE - balance) AS varchar(30)) FROM rd_neg  WHERE balance < $PRICE")")
L_DBT=$(num "$(QD "SELECT CAST(MAX($PRICE - balance) AS varchar(30)) FROM rd_debt WHERE balance < $PRICE")")
L_VW=$(num "$(QD  "SELECT CAST(MAX($PRICE - balance) AS varchar(30)) FROM v_reader_neg WHERE balance < $PRICE")")
row "상점: 최대 부족액 안내" "$L_NEG" "$L_DBT" "$L_VW"
csv "상점 부족액" "$L_NEG" "$L_DBT" "$L_VW"

# ── (3) 랭킹: 하위 정렬 ─────────────────────────────────────────────────
# 오름차순 1등이 누구인가. 음수는 0 보유자보다 아래로 내려간다.
R_NEG=$(num "$(QD "SELECT TOP 1 CAST(balance AS varchar(30)) FROM rd_neg  ORDER BY balance ASC")")
R_DBT=$(num "$(QD "SELECT TOP 1 CAST(balance AS varchar(30)) FROM rd_debt ORDER BY balance ASC")")
R_VW=$(num "$(QD  "SELECT TOP 1 CAST(balance AS varchar(30)) FROM v_reader_neg ORDER BY balance ASC")")
row "랭킹: 최하위 잔액" "$R_NEG" "$R_DBT" "$R_VW"
csv "랭킹 최하위" "$R_NEG" "$R_DBT" "$R_VW"

# ── (4) 통계: 유통량과 평균 ─────────────────────────────────────────────
T_NEG=$(num "$(QD "SELECT CAST(SUM(balance) AS varchar(30)) FROM rd_neg")")
T_DBT=$(num "$(QD "SELECT CAST(SUM(balance) AS varchar(30)) FROM rd_debt")")
T_VW=$(num "$(QD  "SELECT CAST(SUM(balance) AS varchar(30)) FROM v_reader_neg")")
row "통계: 유통 중인 재화" "$T_NEG" "$T_DBT" "$T_VW"
csv "통계 유통량" "$T_NEG" "$T_DBT" "$T_VW"

A_NEG=$(num "$(QD "SELECT CAST(AVG(balance) AS varchar(30)) FROM rd_neg  WHERE balance > 0")")
A_DBT=$(num "$(QD "SELECT CAST(AVG(balance) AS varchar(30)) FROM rd_debt WHERE balance > 0")")
A_VW=$(num "$(QD  "SELECT CAST(AVG(balance) AS varchar(30)) FROM v_reader_neg WHERE balance > 0")")
row "통계: 보유자 평균(>0)" "$A_NEG" "$A_DBT" "$A_VW"
csv "통계 보유자평균" "$A_NEG" "$A_DBT" "$A_VW"

# 같은 평균인데 필터를 뺀 것. **여기서 갈린다.**
W_NEG=$(num "$(QD "SELECT CAST(AVG(balance) AS varchar(30)) FROM rd_neg")")
W_DBT=$(num "$(QD "SELECT CAST(AVG(balance) AS varchar(30)) FROM rd_debt")")
W_VW=$(num "$(QD  "SELECT CAST(AVG(balance) AS varchar(30)) FROM v_reader_neg")")
row "통계: 전체 평균(필터 없음)" "$W_NEG" "$W_DBT" "$W_VW"
csv "통계 전체평균" "$W_NEG" "$W_DBT" "$W_VW"

H_NEG=$(num "$(QD "SELECT CAST(COUNT(*) AS varchar(20)) FROM rd_neg  WHERE balance > 0")")
H_DBT=$(num "$(QD "SELECT CAST(COUNT(*) AS varchar(20)) FROM rd_debt WHERE balance > 0")")
H_VW=$(num "$(QD  "SELECT CAST(COUNT(*) AS varchar(20)) FROM v_reader_neg WHERE balance > 0")")
row "통계: 보유 계정 수" "$H_NEG" "$H_DBT" "$H_VW"
csv "통계 보유계정" "$H_NEG" "$H_DBT" "$H_VW"

echo
echo "  **틀리는 자리가 종류마다 다릅니다. 그리고 안 틀리는 자리도 있습니다.**"
echo
echo "  상점의 구매 가능 판정(WHERE balance >= 가격)은 세 설계가 같습니다."
echo "  음수든 0 이든 못 사는 것은 마찬가지라 부등호가 알아서 걸러 냅니다."
echo "  **여기만 보고 \"음수여도 괜찮다\"고 판단하면 나머지를 놓칩니다.**"
echo
echo "  같은 상점 화면의 **부족액 안내**에서 바로 갈립니다. 가격 - 잔액으로 계산하면"
echo "  NEGATIVE 에서는 회수당한 만큼이 얹혀 실제 필요액보다 부풀어 나옵니다."
echo "  이용자에게는 \"빚부터 갚아야 살 수 있다\"로 보입니다. 그것이 의도라면 맞고,"
echo "  의도가 아니라면 **아무도 모르게 틀린 안내**가 나갑니다."
echo
echo "  **통계에서 갈리는 자리가 필터에 달렸습니다.** 여기는 예상과 달랐습니다."
echo "  보유자 평균(WHERE balance > 0)은 세 설계가 같습니다. NEGATIVE 에서는 음수가,"
echo "  DEBT 에서는 0 이 걸러지는데 **그것이 같은 사람들**이라 남는 모집단이 같습니다."
echo "  필터를 빼면 바로 갈립니다. 전체 평균은 ${W_NEG} 대 ${W_DBT} 입니다."
echo
echo "  그래서 \"통계가 틀린다\"는 한 문장으로는 부족합니다. **어떤 지표는 맞고 어떤"
echo "  지표는 틀리며, 그 경계는 쿼리의 WHERE 절이 정합니다.** 지표를 다 세어 볼 수"
echo "  없다는 것이 이 실험의 진짜 결과입니다."
echo

echo "=================================================================="
echo "## 17-2. 충전이 오면"
echo "=================================================================="
echo
echo "  음수 설계의 상계는 \"더하기만 하면 된다\"가 장점입니다. 실제로 그런지 봅니다."
echo

# 회수당한 사람 한 명에게 충전을 넣는다.
VICT=$(num "$(QD "SELECT TOP 1 CAST(account_id AS varchar(20)) FROM rd_neg WHERE balance < 0 ORDER BY account_id")")
TOPUP=${READER_TOPUP:-500}
QDX "SET NOCOUNT ON;
UPDATE rd_neg  SET balance = balance + $TOPUP WHERE account_id = $VICT;
UPDATE rd_debt SET balance = balance + CASE WHEN debt >= $TOPUP THEN 0 ELSE $TOPUP - debt END,
                   debt    = CASE WHEN debt >= $TOPUP THEN debt - $TOPUP ELSE 0 END
 WHERE account_id = $VICT;" || exit 2

P_NEG=$(numsp "$(QD "SELECT CAST(balance AS varchar(30)) FROM rd_neg WHERE account_id = $VICT")")
P_DBT=$(numsp "$(QD "SELECT CAST(balance AS varchar(30)) + ' / ' + CAST(debt AS varchar(30))
                       FROM rd_debt WHERE account_id = $VICT")")
P_VW=$(numsp "$(QD  "SELECT CAST(balance AS varchar(30)) + ' / ' + CAST(debt AS varchar(30))
                       FROM v_reader_neg WHERE account_id = $VICT")")
printf "  %-26s %s\n" "계정 $VICT 에 ${TOPUP} 충전" ""
row "충전 뒤 (잔액 / 빚)" "$P_NEG" "$P_DBT" "$P_VW"
csv "충전 뒤" "$P_NEG" "$P_DBT" "$P_VW"
echo
echo "  **상계 결과는 같습니다.** 음수에 더하는 것과 빚에서 빼는 것이 같은 값을 냅니다."
echo "  DEBT 설계가 로직을 따로 써야 한다는 대가는 여기서 실제로 드러나고,"
echo "  NEGATIVE 가 그 대가를 안 치르는 것도 사실입니다."
echo
echo "  다만 그 대가를 안 치르는 값이 **위의 표 전부**입니다."
echo

echo "=================================================================="
echo "## 17-3. 뷰는 어디까지 고치는가"
echo "=================================================================="
echo
echo "  오른쪽 열이 실험 14의 보호 뷰입니다. 지표는 DEBT 와 같아졌습니다."
echo "  그러면 뷰만 씌우면 되는가. **읽는 경로가 하나일 때만 그렇습니다.**"
echo

# 뷰를 안 거치는 경로가 하나라도 있으면 그 경로는 음수를 그대로 본다.
BYPASS=$(num "$(QD "SELECT CAST(COUNT(*) AS varchar(20)) FROM rd_neg WHERE balance < 0")")
VIEWED=$(num "$(QD "SELECT CAST(COUNT(*) AS varchar(20)) FROM v_reader_neg WHERE balance < 0")")
printf "  %-40s %s\n" "기저 표를 직접 읽으면 음수 계정" "${BYPASS}개"
printf "  %-40s %s\n" "뷰로 읽으면 음수 계정" "${VIEWED}개"
csv "뷰 우회" "$BYPASS" "-" "$VIEWED"
echo
echo "  뷰는 **읽기를 고칠 뿐 표를 안 고칩니다.** 배치 잡, 백오피스 쿼리, 다른 팀의"
echo "  분석 도구, 리포트 하나라도 기저 표를 직접 읽으면 그 경로는 ${BYPASS}개를 그대로"
echo "  봅니다. 그리고 그 경로가 있는지 없는지는 **DB 가 강제할 수 없습니다.**"
echo "  기저 표에 DENY SELECT 를 걸어도 sysadmin 과 db_owner 는 지나갑니다."
echo
echo "  DEBT 설계는 이 질문 자체가 없습니다. **표에 음수가 없으므로 어느 경로로 읽어도"
echo "  음수가 안 나옵니다.**"

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  음수 잔액이 무엇을 깨뜨리는지 **읽는 쪽별로** 갈렸습니다."
echo
printf "  %-34s %s\n" "읽는 쪽" "NEGATIVE 에서"
printf "  %-34s %s\n" "상점: 살 수 있는가" "안 틀린다 (부등호가 걸러 낸다)"
printf "  %-34s %s\n" "상점: 얼마 모자란가" "**부풀어 나온다** ($L_NEG 대 $L_DBT)"
printf "  %-34s %s\n" "랭킹: 하위 정렬" "**음수가 0 보유자 아래로 간다** ($R_NEG)"
printf "  %-34s %s\n" "통계: 유통량" "**적게 나온다** ($T_NEG 대 $T_DBT)"
printf "  %-34s %s\n" "통계: 보유자 평균(WHERE > 0)" "안 틀린다 (걸러지는 사람이 같다)"
printf "  %-34s %s\n" "통계: 전체 평균(필터 없음)" "**달라진다** ($W_NEG 대 $W_DBT)"
printf "  %-34s %s\n" "충전 상계" "안 틀린다 (더하기로 자연히 맞는다)"
echo
echo "  **위험한 것은 \"안 틀린다\" 줄들입니다.** 제일 먼저 확인해 보는 상점의 구매"
echo "  판정이 멀쩡하게 나오고, 통계도 보유자 평균만 보면 맞습니다. 거기서"
echo "  \"음수여도 괜찮다\"고 결론 내면 나머지가 전부 틀린 채로 나갑니다."
echo
echo "  같은 종류의 읽기 안에서도 갈렸습니다. 상점의 두 판정 중 하나만,"
echo "  통계의 두 평균 중 하나만 틀립니다. **경계를 정하는 것은 설계가 아니라"
echo "  각 쿼리의 WHERE 절입니다.**"
echo
echo "  그래서 \"음수 잔액을 읽는 코드를 전부 확인한다\"는 계획은 성립하기 어렵습니다."
echo "  확인해야 할 쿼리가 몇 개인지 셀 수 없고, 새로 추가되는 것도 막을 수 없고,"
echo "  확인해도 **틀린 것과 안 틀린 것이 섞여 나와** 통과했다는 착각을 줍니다."
echo "  **읽는 쪽을 고치는 대신 표에 음수를 안 넣는 쪽(DEBT)이 세는 곳이 없습니다.**"
} 2>&1 | tee "$OUT/exp17-negative-readers.txt"
