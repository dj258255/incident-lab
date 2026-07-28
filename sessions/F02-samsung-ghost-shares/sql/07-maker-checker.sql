-- 해소 2: maker-checker.
-- 발행총수의 1%(10,000주)를 넘는 단일 입고는 잔고에 바로 반영하지 않고
-- 승인 대기(PENDING)로 적재한다. 승인 전에는 잔고가 늘지 않으므로 매도도 안 된다.
TRUNCATE holdings;
\ir 00-seed-holdings.sql

CREATE TABLE share_credits (
    credit_id  bigserial PRIMARY KEY,
    account_id int    NOT NULL REFERENCES holdings(account_id),
    qty        bigint NOT NULL CHECK (qty > 0),
    reason     text   NOT NULL,
    status     text   NOT NULL CHECK (status IN ('APPLIED', 'PENDING', 'REJECTED')),
    maker      text   NOT NULL,
    checker    text
);

-- 입고 요청. 임계치 이하는 즉시 반영(총량 트리거는 그대로 통과해야 한다),
-- 임계치 초과는 PENDING으로만 적재한다.
CREATE FUNCTION request_credit(p_account int, p_qty bigint, p_reason text, p_maker text)
RETURNS text AS $$
DECLARE
    v_threshold bigint;
BEGIN
    SELECT issued_shares / 100 INTO v_threshold FROM company WHERE company_id = 1;
    IF p_qty > v_threshold THEN
        INSERT INTO share_credits (account_id, qty, reason, status, maker)
        VALUES (p_account, p_qty, p_reason, 'PENDING', p_maker);
        RETURN format('PENDING: %s주는 임계치 %s주(발행총수의 1%%)를 초과, 승인 대기', p_qty, v_threshold);
    END IF;
    UPDATE holdings SET shares = shares + p_qty WHERE account_id = p_account;
    INSERT INTO share_credits (account_id, qty, reason, status, maker, checker)
    VALUES (p_account, p_qty, p_reason, 'APPLIED', p_maker, '(임계치 이하 자동)');
    RETURN format('APPLIED: %s주 즉시 입고', p_qty);
END $$ LANGUAGE plpgsql;

-- 승인/반려. 입력자와 승인자가 같으면 거부한다. 승인 시 반영되는 UPDATE도
-- 총량 트리거를 그대로 지나가므로 승인 실수가 나도 총량 검증이 한 번 더 막는다.
CREATE FUNCTION review_credit(p_credit bigint, p_checker text, p_approve boolean)
RETURNS text AS $$
DECLARE
    v share_credits;
BEGIN
    SELECT * INTO v FROM share_credits WHERE credit_id = p_credit FOR UPDATE;
    IF v.status <> 'PENDING' THEN
        RAISE EXCEPTION 'credit %는 PENDING 상태가 아니다: %', p_credit, v.status;
    END IF;
    IF v.maker = p_checker THEN
        RAISE EXCEPTION '입력자(%)와 승인자가 같을 수 없다', v.maker;
    END IF;
    IF p_approve THEN
        UPDATE holdings SET shares = shares + v.qty WHERE account_id = v.account_id;
        UPDATE share_credits SET status = 'APPLIED', checker = p_checker WHERE credit_id = p_credit;
        RETURN format('APPLIED: credit %s 승인, %s주 입고', p_credit, v.qty);
    END IF;
    UPDATE share_credits SET status = 'REJECTED', checker = p_checker WHERE credit_id = p_credit;
    RETURN format('REJECTED: credit %s 반려', p_credit);
END $$ LANGUAGE plpgsql;

\echo '착오 배당과 같은 대형 입고 요청: 계좌 50에 55,000주(배당금 55,000원의 단위 착오)'
SELECT request_credit(50, 55000, '우리사주 배당(단위 착오)', '오퍼레이터A') AS "결과";

\echo ''
\echo '승인 전이므로 잔고는 그대로다:'
SELECT account_id AS "계좌", shares AS "잔고(주)" FROM holdings WHERE account_id = 50;

\echo ''
\echo '승인 전 매도 시도: 계좌 50이 50,000주 매도'
UPDATE holdings SET shares = shares - 50000 WHERE account_id = 50;

\echo ''
\echo '입력자 본인이 승인 시도:'
SELECT review_credit(1, '오퍼레이터A', true) AS "결과";

\echo ''
\echo '검토자가 단위 착오를 확인하고 반려:'
SELECT review_credit(1, '검토자B', false) AS "결과";

\echo ''
\echo '임계치 이하의 정상 입고(계좌 101에 5,000주 타사 대체입고)는 즉시 반영:'
SELECT request_credit(101, 5000, '타사 대체입고', '오퍼레이터A') AS "결과";

\echo ''
\echo '입고 대장:'
SELECT credit_id AS "id", account_id AS "계좌", qty AS "수량(주)", status,
       maker AS "입력자", checker AS "승인자", reason AS "사유"
FROM share_credits ORDER BY credit_id;

\echo ''
\echo '최종 원장:'
\ir report-state.sql
