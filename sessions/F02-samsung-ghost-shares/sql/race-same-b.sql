-- 동시 입고 세션 B의 같은 계좌 변형. 세션 A와 똑같이 계좌 101을 대상으로 한다.
-- A가 잡은 행 잠금에 걸려 UPDATE 자체가 A의 커밋까지 기다리게 된다.
\echo '[세션B] 계좌 101에 20,000주 대체입고 (A와 같은 계좌), 검증 후 3초 뒤 커밋'
BEGIN;
UPDATE holdings SET shares = shares + 20000 WHERE account_id = 101;
SELECT pg_sleep(3) AS wait \gset
COMMIT;
\echo '[세션B] 커밋 완료'
