-- 해소 1. 같은 ALTER에 lock_timeout만 걸었다.
-- 세션 단위로 거는 것이 요령이다. postgresql.conf에 넣으면 모든 세션에 영향을 준다.
\timing on
SET lock_timeout = '2s';
SHOW lock_timeout;
ALTER TABLE orders_v1 ADD COLUMN is_test2 boolean NOT NULL DEFAULT false;
