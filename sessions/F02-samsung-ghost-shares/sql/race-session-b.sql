-- 동시 입고 세션 B. 세션 A보다 1초 늦게 시작해 A가 커밋하기 전에 검증을 통과한다.
\echo '[세션B] 계좌 202에 20,000주 대체입고, 검증 후 3초 뒤 커밋'
BEGIN;
UPDATE holdings SET shares = shares + 20000 WHERE account_id = 202;
SELECT pg_sleep(3) AS wait \gset
COMMIT;
\echo '[세션B] 커밋 완료'
