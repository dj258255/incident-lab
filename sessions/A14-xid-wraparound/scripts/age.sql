-- 남은 여유를 보는 표준 관측. 21억(2^31)에서 현재 나이를 뺀 값이 남은 XID다.
SELECT datname,
       age(datfrozenxid) AS age,
       2147483648 - age(datfrozenxid) AS remaining,
       round((age(datfrozenxid)::numeric / 2147483648) * 100, 3) AS pct
  FROM pg_database WHERE datname NOT IN ('template0')
 ORDER BY age(datfrozenxid) DESC;
