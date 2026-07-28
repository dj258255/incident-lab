-- SERIALIZABLE 대안 실험, 세션 A. 트리거는 잠금 없는 기본형 그대로 두고
-- 격리 수준만 SERIALIZABLE로 올려 같은 경쟁을 다시 넣는다.
\echo '[직렬화A] 계좌 101에 20,000주 대체입고 (SERIALIZABLE), 검증 후 3초 뒤 커밋'
BEGIN ISOLATION LEVEL SERIALIZABLE;
UPDATE holdings SET shares = shares + 20000 WHERE account_id = 101;
SELECT pg_sleep(3) AS wait \gset
COMMIT;
\echo '[직렬화A] 커밋 완료'
