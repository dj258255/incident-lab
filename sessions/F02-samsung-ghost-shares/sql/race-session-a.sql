-- 동시 입고 세션 A. 검증(트리거)이 UPDATE 문 끝에서 실행된 뒤,
-- 3초를 기다렸다가 커밋해 두 세션의 검증 구간이 겹치게 만든다.
\echo '[세션A] 계좌 101에 20,000주 대체입고, 검증 후 3초 뒤 커밋'
BEGIN;
UPDATE holdings SET shares = shares + 20000 WHERE account_id = 101;
SELECT pg_sleep(3) AS wait \gset
COMMIT;
\echo '[세션A] 커밋 완료'
