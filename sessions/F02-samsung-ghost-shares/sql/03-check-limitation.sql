-- CHECK 제약으로 '잔고 합계 <= 발행총수'를 표현하려는 두 가지 시도.
-- 둘 다 Postgres가 문법 수준에서 거부한다. CHECK는 행 하나만 볼 수 있다.
\echo '시도 1: 집계 함수를 CHECK에 넣기'
ALTER TABLE holdings ADD CONSTRAINT cap_total_by_aggregate
    CHECK (sum(shares) <= 1000000);

\echo ''
\echo '시도 2: 서브쿼리로 company.issued_shares 참조하기'
ALTER TABLE holdings ADD CONSTRAINT cap_total_by_subquery
    CHECK (shares <= (SELECT issued_shares FROM company WHERE company_id = 1));
