-- 해소 1: 총량 검증 트리거.
-- 잔고를 늘리는 문장이 끝날 때마다 SUM(shares) <= issued_shares 를 확인하고,
-- 넘으면 예외를 던져 트랜잭션 전체를 롤백시킨다.
\echo '원장을 착오 이전 상태로 재설정'
TRUNCATE holdings;
\ir 00-seed-holdings.sql

CREATE OR REPLACE FUNCTION assert_total_within_issued() RETURNS trigger AS $$
DECLARE
    v_issued bigint;
    v_total  bigint;
BEGIN
    SELECT issued_shares INTO v_issued FROM company WHERE company_id = 1;
    SELECT coalesce(sum(shares), 0) INTO v_total FROM holdings;
    IF v_total > v_issued THEN
        RAISE EXCEPTION '원장 불변식 위반: 잔고 합계 %주가 발행총수 %주를 초과', v_total, v_issued;
    END IF;
    RETURN NULL;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_total_cap
AFTER INSERT OR UPDATE OF shares ON holdings
FOR EACH STATEMENT EXECUTE FUNCTION assert_total_within_issued();

\echo ''
\echo '같은 착오 배당 배치를 다시 실행:'
BEGIN;
UPDATE holdings
   SET shares = shares + shares * 1000
 WHERE account_id BETWEEN 1 AND 999;
COMMIT;

\echo ''
\echo '트랜잭션이 롤백됐다. 원장은 그대로다:'
\ir report-state.sql

\echo ''
\echo '정상 배당(주당 1,000원, 원 단위 현금 지급)은 통과한다:'
BEGIN;
UPDATE holdings
   SET cash_krw = cash_krw + shares * 1000
 WHERE account_id BETWEEN 1 AND 999;
COMMIT;

SELECT account_id AS "계좌", shares AS "잔고(주)", cash_krw AS "배당금(원)"
FROM holdings WHERE account_id IN (7, 50) ORDER BY account_id;

\echo ''
\echo '착오 입고분 매도 시도: 계좌 50(실보유 55주)이 50,000주 매도'
UPDATE holdings SET shares = shares - 50000 WHERE account_id = 50;

\echo ''
\echo '잔고 부족(음수 잔고 CHECK)으로 거부됐다. 계좌 50 잔고:'
SELECT account_id AS "계좌", shares AS "잔고(주)" FROM holdings WHERE account_id = 50;
