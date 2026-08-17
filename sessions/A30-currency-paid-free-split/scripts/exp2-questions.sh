#!/usr/bin/env bash
# 실험 2. 같은 질문 다섯 개를 세 모델에 던진다.
#
# 질문은 전부 실제 규제·운영에서 나오는 것이다.
#   Q1 미사용 유료 재화가 얼마인가        (환불 산정 — 전자상거래법)
#   Q2 이 주문으로 준 것 중 안 쓴 게 얼마인가 (환불 회수 — Voided Purchases)
#   Q3 이 소모가 온전히 무상이었나         (확률 공시 대상 판정 — 게임산업법 33조 2항)
#   Q4 무상 만료분만 소멸시켜라            (유상에 만료를 걸면 환급 의무와 충돌)
#   Q5 소모 순서를 바꾸면 환불 가능액이 얼마나 갈리나
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
exec > >(tee "$OUT/exp2-questions.txt") 2>&1

echo "# 실험 2. 다섯 질문 — 어느 모델이 어디서 답을 못 하는가"
echo
wait_ready || exit 2

echo "## Q1. 미사용 유료 재화는 얼마인가 (환불 산정)"
echo "  M1:"
QD "SET NOCOUNT ON; SELECT N'balance 컬럼 하나로는 유상분을 못 가른다. 답 없음' AS m1;"
echo "  M2:"
QD "SET NOCOUNT ON; SELECT SUM(paid_balance) AS unused_paid FROM m2_wallet;"
echo "  M3:"
QD "SET NOCOUNT ON; SELECT SUM(remaining) AS unused_paid FROM m3_lot WHERE source='PAID';"
echo

echo "## Q2. 주문 'ord-9-b' 로 지급한 것 중 아직 안 쓴 금액은"
echo "  (환불이 들어오면 이만큼만 회수할 수 있다)"
echo "  M1: 주문 정보 자체가 없다. 답 없음"
echo "  M2:"
QD "SET NOCOUNT ON; SELECT N'유상 총액은 알지만 어느 주문 몫인지 모른다. 답 없음' AS m2;"
echo "  M3:"
QD "SET NOCOUNT ON; SELECT order_id, granted, remaining FROM m3_lot WHERE order_id='ord-9-b';"
echo

echo "## Q3. 계정 7 의 소모 200 은 온전히 무상 재화였나"
echo "  (온전히 무상이면 확률 공시 대상에서 빠진다 — 게임산업법 33조 2항)"
echo "  M1: 소모의 출처를 안 남긴다. 답 없음"
echo "  M2:"
QD "SET NOCOUNT ON;
SELECT CASE WHEN paid_balance = (SELECT SUM(delta) FROM ledger WHERE account_id=7 AND source='PAID')
            THEN N'유상은 안 줄었으니 온전히 무상으로 추정' ELSE N'유상도 줄었다' END AS m2_guess
  FROM m2_wallet WHERE account_id=7;"
echo "  → 추정은 되지만 '이 소모 한 건'이 아니라 '누적 잔액 비교'다. 소모가 여러 번이면 못 가른다"
echo "  M3:"
QD "SET NOCOUNT ON;
SELECT source, SUM(granted - remaining) AS spent FROM m3_lot WHERE account_id=7 GROUP BY source;"
echo

echo "## Q4. 만료된 무상 재화만 소멸시켜라"
echo "  (유상에 만료를 걸면 미사용 유료 환급 의무와 충돌한다)"
echo "  M1: 만료일도 경로도 없다. 답 없음"
echo "  M2: 만료일이 없다. free_balance 를 통째로 지우는 것 말고는 방법이 없다"
echo "  M3:"
QD "SET NOCOUNT ON;
SELECT COUNT(*) AS expiring_lots, SUM(remaining) AS expiring_amount
  FROM m3_lot WHERE source='FREE' AND expires_at IS NOT NULL AND remaining > 0;"
echo "  → 로트 단위라 만료분만 정확히 고를 수 있다"
echo

echo "## Q5. 소모 순서를 뒤집으면 (유상 먼저) 환불 가능액이 얼마나 갈리나"
QD "SET NOCOUNT ON;
WITH g AS (SELECT account_id,
             SUM(CASE WHEN source='PAID'  THEN delta ELSE 0 END) AS paid,
             SUM(CASE WHEN source='FREE'  THEN delta ELSE 0 END) AS free,
             SUM(CASE WHEN source='SPEND' THEN -delta ELSE 0 END) AS spend
           FROM ledger GROUP BY account_id)
SELECT N'무상 먼저 소모' AS policy,
       SUM(paid - CASE WHEN spend > free THEN spend - free ELSE 0 END) AS refundable_paid FROM g
UNION ALL
SELECT N'유상 먼저 소모',
       SUM(CASE WHEN paid > spend THEN paid - spend ELSE 0 END) FROM g;"
echo "  → 같은 이력·같은 총잔액인데 환불 노출액이 갈린다. 정책이 곧 재무 리스크다"
echo

echo "## 정리"
QD "SET NOCOUNT ON;
SELECT N'Q1 미사용 유료' AS question, N'X' AS M1, N'O' AS M2, N'O' AS M3
UNION ALL SELECT N'Q2 주문별 회수', N'X',N'X',N'O'
UNION ALL SELECT N'Q3 온전히 무상인가', N'X',N'△',N'O'
UNION ALL SELECT N'Q4 만료분만 소멸', N'X',N'X',N'O'
UNION ALL SELECT N'Q5 정책별 환불액', N'O',N'O',N'O';"
echo
echo "결론: 총 잔액은 세 모델이 같다(실험 1). 갈리는 것은 답할 수 있는 질문의 수다."
echo "M1 은 다섯 중 하나만 답한다. 공정위 의결 2024-005 가 '유상인지 무상인지 구별이"
echo "불가능'하다고 적은 상태가 바로 M1 이고, 그래서 관련매출액 산정 자체가 안 됐다."
