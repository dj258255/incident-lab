-- 트랜잭션마다 쓰기 서브트랜잭션 70개. 64를 넘으므로 XLOG_XACT_ASSIGNMENT가
-- 기록되고, 스탠바이의 lastOverflowedXid가 전진한다. 이것이 스탠바이 절벽의 전제다.
begin;
do $$
begin
  for i in 1..70 loop
    begin
      update sponsor set amount = amount + 1 where id = (random() * 9999)::int + 1;
    exception when others then null;
    end;
  end loop;
end $$;
commit;
