-- 대상 테이블(:tbl)에 걸린 락과 대기 사슬을 한 화면에 찍는다.
-- pg_blocking_pids()는 "이 세션을 실제로 막고 있는 pid"를 돌려주므로,
-- SELECT를 막는 것이 장기 트랜잭션인지 그 앞에 끼어든 DDL인지를 구분할 수 있다.
SELECT a.pid                                             AS "pid",
       coalesce(nullif(a.application_name, ''), '-')      AS "세션",
       l.mode                                             AS "요청한 락",
       CASE WHEN l.granted THEN '획득' ELSE '대기' END     AS "상태",
       coalesce(a.wait_event_type || ':' || a.wait_event, '-') AS "대기 이벤트",
       pg_blocking_pids(a.pid)                            AS "막고 있는 pid",
       round(extract(epoch FROM (clock_timestamp() - a.query_start))::numeric, 1) AS "경과(초)",
       left(regexp_replace(a.query, '\s+', ' ', 'g'), 46)  AS "질의"
  FROM pg_locks l
  JOIN pg_stat_activity a ON a.pid = l.pid
 WHERE l.relation = (:'tbl')::regclass
   AND coalesce(a.application_name, '') <> 'lockwatch'
 ORDER BY l.granted DESC, a.query_start;
