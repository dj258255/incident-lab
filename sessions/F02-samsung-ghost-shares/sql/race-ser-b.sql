-- SERIALIZABLE 대안 실험, 세션 B. 세션 A와 다른 계좌를 갱신한다.
\echo '[직렬화B] 계좌 202에 20,000주 대체입고 (SERIALIZABLE), 검증 후 3초 뒤 커밋'
BEGIN ISOLATION LEVEL SERIALIZABLE;
UPDATE holdings SET shares = shares + 20000 WHERE account_id = 202;
SELECT pg_sleep(3) AS wait \gset
COMMIT;
\echo '[직렬화B] 커밋 완료'
