-- 해소 2, 3단계 뒷부분. 300만 행을 전부 훑어 제약을 검증한다.
-- 여기서 시간이 걸리지만 락은 SHARE UPDATE EXCLUSIVE라 SELECT와 충돌하지 않는다.
-- 락 수준을 추측하지 않으려고 명시 트랜잭션 안에서 실행하고 pg_locks로 직접 확인한다.
-- 커밋 전에 5초를 붙들어, 락을 쥔 채로 다른 세션의 SELECT가 정말 통과하는지 본다.
-- 실제 배포에서 이렇게 붙들 이유는 없다. 관측을 위해 일부러 늘린 구간이다.
\timing on
BEGIN;
ALTER TABLE orders_v2 VALIDATE CONSTRAINT orders_v2_trace_id_not_null;
\timing off

SELECT mode AS "이 문장이 orders_v2에 잡은 락", granted AS "획득"
  FROM pg_locks
 WHERE relation = 'orders_v2'::regclass AND pid = pg_backend_pid();

SELECT pg_sleep(5);
COMMIT;

SELECT conname AS "제약", convalidated AS "검증됨"
  FROM pg_constraint WHERE conrelid = 'orders_v2'::regclass AND conname LIKE 'orders_v2_trace%';
