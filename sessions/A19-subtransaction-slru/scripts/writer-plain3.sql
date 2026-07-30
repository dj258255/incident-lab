-- 대조군. 쓰기 3건은 같고 SAVEPOINT만 없다. WAL 양과 왕복 횟수를 맞춘다.
\set id random(1, 10000)
\set id2 random(1, 10000)
\set id3 random(1, 10000)
begin;
update sponsor set amount = amount + 1 where id = :id;
update sponsor set amount = amount + 1 where id = :id2;
update sponsor set amount = amount + 1 where id = :id3;
commit;
