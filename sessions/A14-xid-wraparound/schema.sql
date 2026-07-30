-- 후원 원장. wraparound가 다가올 때 쓰기가 막히는 대상이다.
DROP TABLE IF EXISTS sponsor;
CREATE TABLE sponsor (id bigserial PRIMARY KEY, live_id int NOT NULL, amount int NOT NULL);
INSERT INTO sponsor (live_id, amount) SELECT (i % 100) + 1, 1000 FROM generate_series(1, 50000) AS i;
ANALYZE sponsor;
