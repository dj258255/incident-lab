-- 후원 원장. 프라이머리 실험은 50만 행 전량을 긴 트랜잭션이 갱신하고
-- 리더가 그 범위를 읽는다. 서브트랜잭션 XID가 SLRU 32페이지(65,536개)를
-- 충분히 넘어서야 캐시 미스가 생기므로 행 수가 이만큼 필요하다.
-- 스탠바이 실험은 이 중 1~10000만 쓴다.
DROP TABLE IF EXISTS sponsor;
CREATE TABLE sponsor (id bigint PRIMARY KEY, live_id int NOT NULL, amount int NOT NULL);
INSERT INTO sponsor SELECT i, (i % 100) + 1, 1000 FROM generate_series(1, 500000) AS i;
ANALYZE sponsor;
