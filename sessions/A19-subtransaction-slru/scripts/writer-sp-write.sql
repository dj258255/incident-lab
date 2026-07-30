-- SAVEPOINT마다 쓰기를 한다. 쓰지 않는 서브트랜잭션은 XID를 받지 않으므로
-- 스탠바이에 알려질 것도 없다. 이 세션에서 확인한 함정이다.
\set id random(1, 10000)
\set id2 random(1, 10000)
\set id3 random(1, 10000)
begin;
savepoint s1;
update sponsor set amount = amount + 1 where id = :id;
savepoint s2;
update sponsor set amount = amount + 1 where id = :id2;
savepoint s3;
update sponsor set amount = amount + 1 where id = :id3;
commit;
