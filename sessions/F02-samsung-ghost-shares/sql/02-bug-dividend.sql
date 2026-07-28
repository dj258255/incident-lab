-- 버그: 우리사주 배당 배치의 원/주 단위 착오.
-- 의도한 갱신은 cash_krw = cash_krw + shares * 1000 (주당 1,000원 현금 지급).
-- 착오 갱신은 같은 숫자가 단위 검증 없이 '주' 수량 컬럼으로 들어간다.
\echo '착오 배당 배치 실행: 주당 1,000원 배당금이 주당 1,000주 입고로 들어간다'
BEGIN;
UPDATE holdings
   SET shares = shares + shares * 1000   -- 의도: cash_krw = cash_krw + shares * 1000
 WHERE account_id BETWEEN 1 AND 999;     -- 우리사주 조합원 999계좌
COMMIT;

\echo ''
\echo '커밋 성공. 발행총수를 넘겼는데 아무 제약에도 걸리지 않았다:'
\ir report-state.sql

\echo ''
\echo '표본 계좌 잔고 (조합원-7 실보유 12주, 조합원-50 실보유 55주):'
SELECT account_id AS "계좌", holder AS "주주", shares AS "잔고(주)"
FROM holdings WHERE account_id IN (7, 50) ORDER BY account_id;

\echo ''
\echo '이어지는 매도 주문: 계좌 50(실보유 55주)이 유령주 50,000주 매도'
BEGIN;
UPDATE holdings SET shares = shares - 50000 WHERE account_id = 50;
COMMIT;

\echo ''
\echo '매도도 통과했다. 잔고 차감 후:'
SELECT account_id AS "계좌", holder AS "주주", shares AS "잔고(주)"
FROM holdings WHERE account_id = 50;
