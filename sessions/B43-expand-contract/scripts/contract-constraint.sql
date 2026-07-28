-- 해소 2, 3단계(contract) 앞부분. NOT VALID로 제약을 먼저 등록한다.
-- NOT VALID는 기존 행을 검사하지 않으므로 테이블을 읽지 않는다. 락은 ACCESS EXCLUSIVE지만 즉시 끝난다.
-- 락 수준을 추측하지 않으려고 명시 트랜잭션 안에서 실행하고 pg_locks로 직접 확인한다.
\timing on
BEGIN;
ALTER TABLE orders_v2
  ADD CONSTRAINT orders_v2_trace_id_not_null CHECK (trace_id IS NOT NULL) NOT VALID;
\timing off

SELECT mode AS "이 문장이 orders_v2에 잡은 락", granted AS "획득"
  FROM pg_locks
 WHERE relation = 'orders_v2'::regclass AND pid = pg_backend_pid();
COMMIT;

SELECT conname AS "제약", convalidated AS "검증됨"
  FROM pg_constraint WHERE conrelid = 'orders_v2'::regclass AND conname LIKE 'orders_v2_trace%';
