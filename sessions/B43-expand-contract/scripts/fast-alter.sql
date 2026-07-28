-- 실험 4. 실험 1에서 4.9ms에 끝난 것과 같은 종류의 ALTER다.
-- 혼자 돌리면 밀리초지만, 앞에 장기 트랜잭션이 있으면 락을 얻을 때까지 기다린다.
-- lock_timeout이 기본값 0이라 이 대기에는 상한이 없다.
\timing on
SHOW lock_timeout;
ALTER TABLE orders_v1 ADD COLUMN is_test boolean NOT NULL DEFAULT false;
