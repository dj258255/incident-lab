-- VALIDATE CONSTRAINT가 락을 쥐고 있는 동안 계속 붙어 있는 읽기 세션.
-- 한 번만 읽으면 관측 창이 짧아 락 스냅샷에 잡히지 않으므로 세 번 연달아 읽는다.
\timing on
SELECT count(*) FROM orders_v2;
SELECT count(*) FROM orders_v2;
SELECT count(*) FROM orders_v2;
