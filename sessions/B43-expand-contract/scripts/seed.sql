-- 300만 행 주문 테이블을 같은 방식으로 두 벌 만든다.
--   orders_v1 = 문제 방식(한 방 ALTER)용
--   orders_v2 = 해소 방식(3단계 expand-contract)용
-- 두 벌이 같아야 "같은 300만 행에서의 전후 비교"가 성립한다. v2는 v1을 그대로 복사해 만든다.
\timing on

DROP TABLE IF EXISTS orders_v1;
DROP TABLE IF EXISTS orders_v2;

CREATE TABLE orders_v1 (
    id         bigint        NOT NULL,
    account_id integer       NOT NULL,
    symbol     text          NOT NULL,
    quantity   integer       NOT NULL,
    price      numeric(18,2) NOT NULL,
    created_at timestamptz   NOT NULL
);

-- 전부 g에서 파생한 결정적 시드다. 난수를 쓰지 않으므로 몇 번을 돌려도 같은 데이터가 나온다.
INSERT INTO orders_v1
SELECT g,
       (g % 100000) + 1,
       lpad((((g * 7) % 900) + 100)::text, 6, '0'),
       (g % 500) + 1,
       (((g * 13) % 90000) + 1000)::numeric / 100,
       timestamptz '2026-01-01 09:00:00+09' + ((g % 2592000) * interval '1 second')
FROM generate_series(1, :rows) AS g;

ALTER TABLE orders_v1 ADD PRIMARY KEY (id);

CREATE TABLE orders_v2 (LIKE orders_v1 INCLUDING ALL);
INSERT INTO orders_v2 SELECT * FROM orders_v1;

VACUUM ANALYZE orders_v1;
VACUUM ANALYZE orders_v2;

-- 시드가 만든 WAL 때문에 체크포인트가 계속 돌고 있다. 그 상태로 재면 밀리초짜리 DDL의
-- 커밋 fsync가 체크포인트 뒤에 줄을 서서 수백 ms로 부풀어 오른다(측정값이 아니라 잡음이다).
-- 측정 전에 한 번 밀어 두고 시작한다.
CHECKPOINT;

\timing off
SELECT relname                                AS "테이블",
       (SELECT count(*) FROM orders_v1)       AS "행 수",
       pg_size_pretty(pg_relation_size(oid))  AS "힙 크기",
       pg_size_pretty(pg_total_relation_size(oid)) AS "인덱스 포함",
       relfilenode                            AS "relfilenode"
  FROM pg_class
 WHERE relname IN ('orders_v1', 'orders_v2')
 ORDER BY relname;
