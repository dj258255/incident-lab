-- 같은 경쟁을 advisory lock으로 직렬화한다.
TRUNCATE holdings;
\ir 00-seed-holdings.sql

-- 트리거는 그대로 두고 검증 함수만 교체한다. 검증에 들어가기 전에
-- 트랜잭션 끝까지 유지되는 전역 잠금을 잡아, 총량 검증과 커밋이 한 세션씩 지나가게 한다.
CREATE OR REPLACE FUNCTION assert_total_within_issued() RETURNS trigger AS $$
DECLARE
    v_issued bigint;
    v_total  bigint;
BEGIN
    PERFORM pg_advisory_xact_lock(20180406);   -- 원장 총량 검증 직렬화
    SELECT issued_shares INTO v_issued FROM company WHERE company_id = 1;
    SELECT coalesce(sum(shares), 0) INTO v_total FROM holdings;
    IF v_total > v_issued THEN
        RAISE EXCEPTION '원장 불변식 위반: 잔고 합계 %주가 발행총수 %주를 초과', v_total, v_issued;
    END IF;
    RETURN NULL;
END $$ LANGUAGE plpgsql;

\echo '재설정 완료. 검증 함수가 pg_advisory_xact_lock(20180406)을 먼저 잡는다.'
