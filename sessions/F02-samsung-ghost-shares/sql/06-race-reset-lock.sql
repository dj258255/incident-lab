-- 같은 경쟁을 advisory lock으로 직렬화한다.
TRUNCATE holdings;
\ir 00-seed-holdings.sql

-- 트리거는 그대로 두고 검증 함수만 교체한다. 검증에 들어가기 전에
-- 트랜잭션 끝까지 유지되는 전역 잠금을 잡아, 총량 검증과 커밋이 한 세션씩 지나가게 한다.
--
-- VOLATILE을 반드시 명시할 것. 이 해소는 격리 수준이 아니라 함수 volatility에 달려 있다.
-- VOLATILE 함수는 자기가 실행하는 질의마다 새 스냅숏을 잡는다. 그래서 잠금 대기가 끝난 뒤의
-- SUM이 앞 세션이 커밋한 합계를 본다. STABLE이나 IMMUTABLE로 선언하면 호출한 질의의 스냅숏을
-- 그대로 쓰므로, 잠금을 제대로 잡고도 대기 이전의 낡은 합계를 읽어 검증이 통과한다.
-- 오류 없이 조용히 뚫리는 쪽이라 기본값에 기대지 않고 적어 둔다.
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
END $$ LANGUAGE plpgsql VOLATILE;   -- 위 주석 참고. STABLE로 바꾸면 이 해소가 조용히 무너진다

\echo '재설정 완료. 검증 함수가 pg_advisory_xact_lock(20180406)을 먼저 잡는다.'
