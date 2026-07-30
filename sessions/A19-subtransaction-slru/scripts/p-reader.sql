-- 긴 트랜잭션이 갱신한 범위 안에서만 읽는다.
\set id random(1, 500000)
SELECT amount FROM sponsor WHERE id = :id;
