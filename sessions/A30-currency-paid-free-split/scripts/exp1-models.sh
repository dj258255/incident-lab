#!/usr/bin/env bash
# 실험 1. 같은 데이터를 세 모델로 담는다.
#
# A24·A25 는 재화를 balance 한 컬럼으로 다뤘다. 공정위 의결 2024-005 는 그 구조에서
# "유상 구입한 것인지 무상 획득한 것인지 구별이 불가능"해 관련매출액 산정 자체가
# 안 됐다고 적는다. 이 실험은 같은 지급·소모 이력을 세 모델에 담고,
# 다음 실험에서 같은 질문 다섯 개를 던져 어느 모델이 어디서 답을 못 하는지 본다.
#
#   M1  balance 한 컬럼                          (현재 랩 = A25)
#   M2  paid_balance / free_balance 두 컬럼
#   M3  로트(lot) 테이블 — 취득 경로·주문·만료를 행으로
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
exec > >(tee "$OUT/exp1-models.txt") 2>&1

echo "# 실험 1. 한 이력을 세 모델에 담는다"
echo
wait_ready || exit 2

echo "## 1-1. 준비"
Q "IF DB_ID('$DB') IS NOT NULL BEGIN ALTER DATABASE [$DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DB]; END" >/dev/null
Q "CREATE DATABASE [$DB]" >/dev/null
QDX "SET NOCOUNT ON;
-- 공통 원장: 무엇이 언제 어떤 경로로 들어오고 나갔나
CREATE TABLE ledger (
    entry_id    BIGINT IDENTITY(1,1) PRIMARY KEY,
    account_id  INT          NOT NULL,
    delta       BIGINT       NOT NULL,           -- 양수 지급, 음수 소모
    source      VARCHAR(10)  NOT NULL,           -- PAID | FREE | SPEND
    order_id    VARCHAR(30)  NULL,               -- 유상 지급의 주문 (환불 회수의 열쇠)
    expires_at  DATETIME2(0) NULL,               -- 무상 지급의 만료
    occurred_at DATETIME2(3) NOT NULL DEFAULT SYSDATETIME()
);
CREATE INDEX idx_ledger_acct ON ledger(account_id, entry_id);

-- M1: 랩의 현재 모델
CREATE TABLE m1_wallet (account_id INT NOT NULL PRIMARY KEY, balance BIGINT NOT NULL);
-- M2: 유상·무상 두 컬럼
CREATE TABLE m2_wallet (account_id INT NOT NULL PRIMARY KEY, paid_balance BIGINT NOT NULL, free_balance BIGINT NOT NULL);
-- M3: 로트. 취득 로트마다 한 행, 남은 수량을 들고 있는다
CREATE TABLE m3_lot (
    lot_id     BIGINT IDENTITY(1,1) PRIMARY KEY,
    account_id INT          NOT NULL,
    source     VARCHAR(10)  NOT NULL,
    order_id   VARCHAR(30)  NULL,
    expires_at DATETIME2(0) NULL,
    granted    BIGINT       NOT NULL,
    remaining  BIGINT       NOT NULL,
    CONSTRAINT CK_m3_remaining CHECK (remaining >= 0 AND remaining <= granted)
);
CREATE INDEX idx_m3_acct ON m3_lot(account_id, lot_id);" || exit 2
echo "  원장 + 세 모델 표 생성"
echo

echo "## 1-2. 지급 이력 심기 (계정 ${ACCOUNTS})"
QDX "SET NOCOUNT ON;
WITH n AS (SELECT TOP ($ACCOUNTS) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) i
             FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO ledger (account_id, delta, source, order_id, expires_at)
SELECT i, 1000, 'PAID', CONCAT('ord-', i, '-a'), NULL FROM n;

WITH n AS (SELECT TOP ($ACCOUNTS) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) i
             FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO ledger (account_id, delta, source, order_id, expires_at)
SELECT i, 300, 'FREE', NULL, DATEADD(day, 30, SYSDATETIME()) FROM n;

-- 계정 3의 배수는 유상 한 번 더 (환불 대상 주문을 만들기 위해)
WITH n AS (SELECT TOP ($ACCOUNTS) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) i
             FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO ledger (account_id, delta, source, order_id, expires_at)
SELECT i, 500, 'PAID', CONCAT('ord-', i, '-b'), NULL FROM n WHERE i % 3 = 0;" || exit 2

echo "## 1-3. 소모 이력 (계정마다 200 소모 — 무상 300 중 100 이 남아 만료 대상이 된다)"
QDX "SET NOCOUNT ON;
WITH n AS (SELECT TOP ($ACCOUNTS) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) i
             FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO ledger (account_id, delta, source) SELECT i, -200, 'SPEND' FROM n;" || exit 2
L=$(num "$(QD "SET NOCOUNT ON; SELECT COUNT(*) FROM ledger")")
echo "  원장 ${L}행"
echo

echo "## 1-4. 세 모델에 적재 — 소모 규칙은 '무상 먼저'로 통일"
QDX "SET NOCOUNT ON;
-- M1: 그냥 합친다
INSERT INTO m1_wallet (account_id, balance)
SELECT account_id, SUM(delta) FROM ledger GROUP BY account_id;

-- M2: 지급은 경로별로, 소모는 무상에서 먼저 빼고 모자라면 유상에서
INSERT INTO m2_wallet (account_id, paid_balance, free_balance)
SELECT g.account_id,
       g.paid - CASE WHEN g.spend > g.free THEN g.spend - g.free ELSE 0 END,
       CASE WHEN g.free > g.spend THEN g.free - g.spend ELSE 0 END
  FROM (SELECT account_id,
               SUM(CASE WHEN source='PAID'  THEN delta ELSE 0 END) AS paid,
               SUM(CASE WHEN source='FREE'  THEN delta ELSE 0 END) AS free,
               SUM(CASE WHEN source='SPEND' THEN -delta ELSE 0 END) AS spend
          FROM ledger GROUP BY account_id) g;

-- M3: 로트를 만들고, 소모를 무상 로트부터 차감
INSERT INTO m3_lot (account_id, source, order_id, expires_at, granted, remaining)
SELECT account_id, source, order_id, expires_at, delta, delta
  FROM ledger WHERE delta > 0;" || exit 2

# M3 소모 차감: 무상(FREE) 로트 먼저, 그다음 유상(PAID)
QDX "SET NOCOUNT ON;
WITH spend AS (SELECT account_id, SUM(-delta) AS amt FROM ledger WHERE source='SPEND' GROUP BY account_id),
ranked AS (
  SELECT l.lot_id, l.account_id, l.remaining, s.amt,
         SUM(l.remaining) OVER (PARTITION BY l.account_id
             ORDER BY CASE WHEN l.source='FREE' THEN 0 ELSE 1 END, l.lot_id
             ROWS UNBOUNDED PRECEDING) AS cum
    FROM m3_lot l JOIN spend s ON s.account_id = l.account_id)
UPDATE r SET remaining = CASE WHEN r.cum <= r.amt THEN 0
                              WHEN r.cum - r.remaining >= r.amt THEN r.remaining
                              ELSE r.cum - r.amt END
  FROM ranked r;" || exit 2

echo "  적재 완료. 세 모델의 총 잔액이 같은지 확인:"
QD "SET NOCOUNT ON;
SELECT 'M1' AS model, SUM(balance) AS total FROM m1_wallet
UNION ALL SELECT 'M2', SUM(paid_balance + free_balance) FROM m2_wallet
UNION ALL SELECT 'M3', SUM(remaining) FROM m3_lot;"
echo
echo "결론: 같은 이력에서 총 잔액은 셋 다 같다. 차이는 다음 실험의 질문에서 드러난다."
