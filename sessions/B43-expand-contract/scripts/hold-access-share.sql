-- 장기 실행 트랜잭션 역할. 리포트 화면 하나가 커밋을 늦게 하는 흔한 상황이다.
-- 테이블을 한 번만 읽어도 ACCESS SHARE 락을 잡고, 그 락은 커밋할 때까지 풀리지 않는다.
\timing on
BEGIN;
SELECT id FROM orders_v1 ORDER BY id LIMIT 1;
SELECT pg_sleep(12);
COMMIT;
