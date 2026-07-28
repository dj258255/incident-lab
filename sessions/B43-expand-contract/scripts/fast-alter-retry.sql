-- 해소 1의 나머지 절반. lock_timeout으로 끊었으면 다시 걸어야 한다.
-- 장기 트랜잭션이 끝난 뒤 같은 문장을 다시 실행한다.
\timing on
SET lock_timeout = '2s';
ALTER TABLE orders_v1 ADD COLUMN is_test2 boolean NOT NULL DEFAULT false;
