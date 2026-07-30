-- 스탠바이에서 방금 갱신된 범위를 읽는다.
\set id random(1, 10000)
select amount from sponsor where id = :id;
