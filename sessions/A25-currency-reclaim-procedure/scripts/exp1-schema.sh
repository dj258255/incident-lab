#!/usr/bin/env bash
# 실험 1. 스키마와 보정 프로시저를 만들고, 잔액 제약이 어디서 걸리는지 본다.
#
# A24 가 회수 대상(계정, 건수, 금액)까지 뽑아 놓았다. 이제 실제로 되돌려야 한다.
# 그런데 되돌리려는 순간 먼저 부딪히는 것이 잔액 제약이다.
#
# 게임 재화 표에는 보통 `CHECK (balance >= 0)` 이 붙어 있다. 정상 흐름에서는
# 맞는 제약이다. 그런데 이미 써 버린 재화를 회수하려면 잔액이 음수가 돼야 한다.
# 로스트아크 2023-06 공지가 "사용 내역 취소 또는 음수 재화 적용"이라고 적은 그 자리다.
#
# 이 실험은 제약이 실제로 회수를 막는 것을 확인하고, 두 설계를 만들어 다음 실험에서
# 견준다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

wait_ready || exit 2

{
echo "# 실험 1. 스키마와 보정 프로시저"
echo "# $(num "$(Q "SELECT LEFT(@@VERSION, 46)")")"
echo
echo "  계정 ${ACCOUNTS}개, 회수 대상 ${TARGETS}개."
echo "  대상 중 ${SHORT_RATIO}분의 1은 이미 재화를 써서 잔액이 회수액보다 적습니다."
echo

Q "IF DB_ID('$DB') IS NULL CREATE DATABASE [$DB];" >/dev/null
# 보정 자체를 되돌리려면 로그 백업 체인이 필요하다(실험 4).
Q "ALTER DATABASE [$DB] SET RECOVERY FULL;" >/dev/null

echo "## 1-1. 표"
QDX "SET NOCOUNT ON;
DROP TABLE IF EXISTS correction_detail;
DROP TABLE IF EXISTS correction_batch;
DROP TABLE IF EXISTS reclaim_target;
DROP TABLE IF EXISTS account_currency;

-- 재화 잔액. 정상 흐름에서는 음수가 될 수 없다.
CREATE TABLE account_currency (
    account_id INT    NOT NULL PRIMARY KEY,
    balance    BIGINT NOT NULL,
    CONSTRAINT CK_balance_nonneg CHECK (balance >= 0)
);

-- A24 의 산출물. 계정과 회수할 금액.
CREATE TABLE reclaim_target (
    account_id   INT    NOT NULL PRIMARY KEY,
    extra_rows   INT    NOT NULL,
    extra_amount BIGINT NOT NULL
);

-- 보정 작업 단위. 무엇을 왜 언제 누가 했는지 남는다.
CREATE TABLE correction_batch (
    batch_id   INT IDENTITY(1,1) PRIMARY KEY,
    reason     NVARCHAR(200) NOT NULL,
    created_by SYSNAME       NOT NULL DEFAULT SUSER_SNAME(),
    created_at DATETIME2(3)  NOT NULL DEFAULT SYSDATETIME(),
    status     VARCHAR(20)   NOT NULL DEFAULT 'RUNNING',
    last_done  INT           NOT NULL DEFAULT 0   -- 재시작 지점
);

-- 계정별 전후 기록. 이의 제기가 오면 이 표가 근거가 된다.
CREATE TABLE correction_detail (
    batch_id       INT    NOT NULL,
    account_id     INT    NOT NULL,
    target_amount  BIGINT NOT NULL,
    applied_amount BIGINT NOT NULL,   -- 잔액에서 실제로 뺀 금액
    debt_amount    BIGINT NOT NULL,   -- 잔액이 모자라 빚으로 남긴 금액
    balance_before BIGINT NOT NULL,
    balance_after  BIGINT NOT NULL,
    applied_at     DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_correction_detail PRIMARY KEY (batch_id, account_id)
);" || exit 2
echo "  account_currency, reclaim_target, correction_batch, correction_detail"
echo

echo "## 1-2. 적재"
QDX "SET NOCOUNT ON;
WITH n AS (SELECT TOP ($ACCOUNTS) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
             FROM sys.all_objects a CROSS JOIN sys.all_objects b CROSS JOIN sys.all_objects c)
INSERT INTO account_currency WITH (TABLOCK) (account_id, balance)
SELECT i, 50000 + (i % 37) * 1000 FROM n;" || exit 2

# 회수 대상. 3분의 1은 잔액보다 큰 금액을 회수해야 하는 계정으로 만든다.
QDX "SET NOCOUNT ON;
WITH t AS (SELECT TOP ($TARGETS) account_id, balance,
                  ROW_NUMBER() OVER (ORDER BY account_id) AS rn
             FROM account_currency ORDER BY account_id)
INSERT INTO reclaim_target (account_id, extra_rows, extra_amount)
SELECT account_id, 3,
       CASE WHEN rn % $SHORT_RATIO = 0 THEN balance + 12000   -- 이미 써서 잔액이 모자란다
                                       ELSE 6000 END
  FROM t;" || exit 2

A=$(num "$(QD "SELECT COUNT(*) FROM account_currency")")
T=$(num "$(QD "SELECT COUNT(*) FROM reclaim_target")")
SHORT=$(num "$(QD "SELECT COUNT(*) FROM reclaim_target r JOIN account_currency a ON a.account_id = r.account_id
                    WHERE r.extra_amount > a.balance")")
TOTAL=$(num "$(QD "SELECT SUM(extra_amount) FROM reclaim_target")")
[ "$A" = "$ACCOUNTS" ] || { echo "중단: 계정이 ${A}개입니다(기대 ${ACCOUNTS})"; exit 2; }
[ "$T" = "$TARGETS" ]  || { echo "중단: 대상이 ${T}개입니다(기대 ${TARGETS})"; exit 2; }
printf "  %-24s %s\n" "계정" "${A}개"
printf "  %-24s %s\n" "회수 대상" "${T}개"
printf "  %-24s %s\n" "잔액이 모자란 대상" "${SHORT}개"
printf "  %-24s %s\n" "회수 총액" "$TOTAL"
echo

echo "## 1-3. 제약이 회수를 막는다"
echo
# 잔액이 모자란 계정 하나를 골라 그대로 차감해 본다.
ONE=$(num "$(QD "SELECT TOP 1 CAST(r.account_id AS varchar(12))
                   FROM reclaim_target r JOIN account_currency a ON a.account_id = r.account_id
                  WHERE r.extra_amount > a.balance ORDER BY r.account_id")")
ERR=$(QD "SET NOCOUNT ON;
UPDATE a SET a.balance = a.balance - r.extra_amount
  FROM account_currency a JOIN reclaim_target r ON r.account_id = a.account_id
 WHERE a.account_id = $ONE;" | grep -E '^(Msg|메시지)' | head -1)
if [ -n "$ERR" ]; then
  echo "  계정 ${ONE} 을 그대로 차감하면 막힙니다."
  echo "    $ERR"
  echo
  echo "  **회수는 제약과 부딪힙니다.** 이미 쓴 재화를 되돌리려면 잔액이 음수가 돼야"
  echo "  하는데 제약이 그것을 막습니다. 제약을 없애면 정상 흐름의 방어도 함께 사라집니다."
else
  echo "  **차감이 통과했습니다. 제약이 걸려 있지 않습니다. 이 실험은 성립하지 않습니다.**"
  exit 2
fi
echo

echo "## 1-4. 두 설계"
echo
echo "  A안 음수 잔액 허용   제약을 빼고 잔액이 음수로 내려가게 둔다."
echo "                        이후 획득분이 자연스럽게 상계된다."
echo "  B안 빚 컬럼 분리      잔액은 0 이상을 유지하고 못 받은 만큼을 debt 에 적는다."
echo "                        제약이 살아 있고, 빚이 있는 계정을 따로 셀 수 있다."
echo
echo "  둘 다 만들고 실험 2에서 견줍니다."

QDX "SET NOCOUNT ON;
-- B안용 컬럼. A안은 제약만 빼면 되므로 별도 표가 필요 없다.
IF COL_LENGTH('account_currency','debt') IS NULL
    ALTER TABLE account_currency ADD debt BIGINT NOT NULL DEFAULT 0;" || exit 2

echo
{ echo "metric,value"
  echo "accounts,$A"
  echo "targets,$T"
  echo "short_targets,$SHORT"
  echo "reclaim_total,$TOTAL"
  echo "chunk,$CHUNK"; } > "$OUT/dataset.csv"
echo "  준비 완료. 회수 총액 ${TOTAL}, 배치 크기 ${CHUNK}."
} 2>&1 | tee "$OUT/exp1-schema.txt"
