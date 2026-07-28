-- 동시 입고 경쟁 준비: 원장을 재설정하고 검증 함수를 잠금 없는 기본형으로 되돌린다.
-- (04에서 만든 것과 같은 본문이다. advisory lock 라운드 뒤에 되돌릴 때도 이 파일을 쓴다.)
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

\echo '재설정 완료. 잔고 합계 970,000주, 발행총수까지 여유분 30,000주. 트리거는 잠금 없는 기본형.'
