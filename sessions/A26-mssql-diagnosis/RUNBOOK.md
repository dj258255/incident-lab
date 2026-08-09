# 운영 절차서: "느려졌다"는 신고를 받았을 때

대상: SQL Server 인스턴스의 응답 저하 신고
근거: 같은 디렉토리의 [README.md](README.md) 실측.

이 문서는 원인을 **좁히는 순서**만 다룹니다. 원인별 해소는 다른 절차서로 넘어갑니다.
락 승격이면 [A04](../A04-mssql-lock-escalation/RUNBOOK.md), 보정 배치가 원인이면
[A25](../A25-currency-reclaim-procedure/RUNBOOK.md)입니다.

---

## 0. 한 줄 요약

**대기 통계를 두 번 떠서 차분을 보고, 락이면 사슬을 재귀로 따라가 뿌리를 찾는다.**
뿌리는 보통 `sleeping` 이라 실행 중인 것만 보는 도구로는 안 보인다.

---

## 1. 먼저 스냅샷을 뜬다 (30초)

무엇을 볼지 정하기 전에 **기준부터 만듭니다.** 이걸 안 뜨면 나중에 차분을 못 봅니다.

```sql
DROP TABLE IF EXISTS #wait_base;
SELECT wait_type, waiting_tasks_count, wait_time_ms
  INTO #wait_base
  FROM sys.dm_os_wait_stats;
```

임시 표는 세션이 끊기면 사라집니다. 오래 볼 것이면 실제 표에 뜹니다.

---

## 2. 지금 막혀 있는 것부터 본다 (1분)

차분은 몇 분 기다려야 하므로, 그동안 현재 상태를 봅니다.

```sql
-- 지금 이 순간 막혀 있는 세션
SELECT r.session_id, r.blocking_session_id, r.wait_type, r.wait_time,
       DB_NAME(r.database_id) AS db, t.text
  FROM sys.dm_exec_requests r
  JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
 CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
 WHERE s.is_user_process = 1 AND r.blocking_session_id <> 0
 ORDER BY r.wait_time DESC;
```

한 건도 없으면 락 문제가 아닙니다. 4절로 갑니다.

---

## 3. 락이면 뿌리를 찾는다

**여기 나온 `blocking_session_id` 를 그대로 죽이지 않습니다.** 중간 세션일 수 있습니다.
그것을 죽여도 뿌리가 그대로라 다시 같은 일이 납니다.

```sql
WITH blocked AS (
    SELECT r.session_id, r.blocking_session_id
      FROM sys.dm_exec_requests r
      JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
     WHERE s.is_user_process = 1 AND r.blocking_session_id <> 0
),
chain AS (
    SELECT b.session_id, b.blocking_session_id, 1 AS depth,
           CAST(b.session_id AS varchar(200)) AS path
      FROM blocked b
     WHERE NOT EXISTS (SELECT 1 FROM blocked x WHERE x.blocking_session_id = b.session_id)
    UNION ALL
    SELECT c.session_id,
           ISNULL((SELECT b2.blocking_session_id FROM blocked b2
                    WHERE b2.session_id = c.blocking_session_id), 0),
           c.depth + 1,
           CAST(c.path + ' <- ' + CAST(c.blocking_session_id AS varchar(8)) AS varchar(200))
      FROM chain c
     WHERE c.blocking_session_id <> 0
)
SELECT TOP 1 path FROM chain ORDER BY depth DESC;
```

> 재귀부에 `LEFT JOIN` 을 쓰면 막힙니다. 스칼라 서브쿼리로 씁니다. `path` 타입도
> 앵커와 정확히 맞춰야 `Msg 240` 이 안 납니다. **이 쿼리는 사고 전에 검증해 둡니다.**
> 사고 중에 이런 걸 만나면 원인 찾는 시간이 쿼리 고치는 시간에 먹힙니다.

### 뿌리가 안 보이면

뿌리는 보통 **아무것도 안 하고 있습니다.** 실행 중인 요청이 없어 `dm_exec_requests` 에
안 나옵니다. 이렇게 찾습니다.

```sql
-- 요청은 없는데 트랜잭션은 열려 있는 세션
SELECT s.session_id, s.login_name, s.host_name, s.program_name,
       s.status, s.last_request_end_time,
       DATEDIFF(second, s.last_request_end_time, SYSDATETIME()) AS idle_sec
  FROM sys.dm_exec_sessions s
  JOIN sys.dm_tran_session_transactions t ON t.session_id = s.session_id
 WHERE s.is_user_process = 1
   AND NOT EXISTS (SELECT 1 FROM sys.dm_exec_requests r WHERE r.session_id = s.session_id)
 ORDER BY idle_sec DESC;
```

`program_name` 과 `host_name` 을 꼭 봅니다. 운영툴에서 트랜잭션을 열어 둔 채 자리를
뜬 세션이 흔한 원인입니다.

---

## 4. 락이 아니면 대기 차분을 본다

1절 스냅샷에서 몇 분 지난 뒤 봅니다.

```sql
SELECT TOP 10 c.wait_type,
       c.wait_time_ms - ISNULL(b.wait_time_ms, 0) AS delta_ms,
       c.waiting_tasks_count - ISNULL(b.waiting_tasks_count, 0) AS delta_count
  FROM sys.dm_os_wait_stats c
  LEFT JOIN #wait_base b ON b.wait_type = c.wait_type
 WHERE c.wait_type NOT IN (
       -- 유휴 대기. 안 빼면 매번 이것들이 1위로 나온다
       'SLEEP_TASK','LAZYWRITER_SLEEP','XE_TIMER_EVENT','XE_DISPATCHER_WAIT',
       'REQUEST_FOR_DEADLOCK_SEARCH','LOGMGR_QUEUE','CHECKPOINT_QUEUE','DIRTY_PAGE_POLL',
       'SP_SERVER_DIAGNOSTICS_SLEEP','QDS_ASYNC_QUEUE','QDS_SHUTDOWN_QUEUE','WAITFOR',
       'BROKER_TO_FLUSH','BROKER_EVENTHANDLER','BROKER_TASK_STOP','SLEEP_SYSTEMTASK',
       'SOS_WORK_DISPATCHER','DISPATCHER_QUEUE_SEMAPHORE','ONDEMAND_TASK_QUEUE',
       'FT_IFTS_SCHEDULER_IDLE_WAIT','CLR_AUTO_EVENT','CLR_MANUAL_EVENT')
   AND c.wait_time_ms - ISNULL(b.wait_time_ms, 0) > 0
 ORDER BY delta_ms DESC;
```

**누적을 그대로 읽지 않습니다.** 인스턴스가 뜬 뒤로 쌓인 값이라 어제 사고와 지난주
배치가 섞여 있습니다. 실측에서 같은 `LCK_M_IS` 가 누적 430,521ms 인데 이번 사고가
만든 것은 107,453ms 였습니다. 누적만 보면 크기를 네 배로 봅니다.

| 차분 상위 | 의심할 곳 |
|---|---|
| `LCK_M_*` | 3절로 돌아가 뿌리를 찾는다 |
| `PAGEIOLATCH_*` | 디스크 읽기. 인덱스가 없어 풀스캔하는 쿼리 |
| `WRITELOG` | 로그 쓰기. 커밋이 잦거나 로그 디스크가 느림 |
| `RESOURCE_SEMAPHORE` | 메모리 부여 대기. 큰 정렬·해시가 몰림 |
| `CXPACKET` / `CXCONSUMER` | 병렬 처리. 그 자체가 원인인 경우는 드물다 |
| `SOS_SCHEDULER_YIELD` | CPU 경합 |

---

## 4-2. 락이 아니면 범인 쿼리를 찾는다

차분이 `PAGEIOLATCH_*` 나 `SOS_SCHEDULER_YIELD` 를 가리키면 많이 읽는 쿼리를 찾습니다.

```sql
-- 계획 단위가 아니라 query_hash 로 묶어서 본다
SELECT TOP 20
       COUNT(*)                        AS plans,
       SUM(qs.execution_count)         AS execs,
       SUM(qs.total_logical_reads)     AS logical_reads,
       SUM(qs.total_worker_time)/1000  AS cpu_ms,
       MIN(t.text)                     AS sample_text
  FROM sys.dm_exec_query_stats qs
 CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
 GROUP BY qs.query_hash
 ORDER BY SUM(qs.total_logical_reads) DESC;
```

**계획 단위로만 보면 범인을 놓칩니다.** 값을 리터럴로 박아 던지는 쿼리는 값마다 다른
계획으로 흩어져 각각 실행 1회에 소량으로 남습니다. 상위 N 에 안 옵니다.

실측에서 같은 부하를 절반씩 나눠 걸었더니, 계획 단위 1위는 151,326 인데 `query_hash`
로 묶으면 304,086 이었습니다. **묶기 전에는 실제 부하의 절반만 보였습니다.**

| `plans` 열이 | 뜻 |
|---|---|
| 1 | 파라미터로 잘 넘기고 있다 |
| 수십~수천 | 리터럴을 박고 있다. 캐시가 부풀고 매번 컴파일한다 |

`plans` 가 큰 줄이 보이면 진단으로 끝낼 것이 아니라 **애플리케이션이 값을 파라미터로
넘기게 고치는 것**이 근본 해소입니다.

> 아주 단순한 쿼리는 엔진이 알아서 파라미터화해 줍니다(단순 매개 변수화). 조인이 하나만
> 들어가도 안 해 주므로, 실무 쿼리는 대부분 흩어지는 쪽입니다.

> `query_stats` 는 계획이 캐시에서 밀려나면 **통계도 함께 사라집니다.** 사고가 지나간
> 뒤에 들여다보면 범인이 이미 없을 수 있습니다.

---

## 5. 뿌리를 죽이기 전에

- [ ] `program_name`, `host_name`, `login_name` 을 **기록했는가** (같은 일이 반복된다)
- [ ] 그 세션이 무엇을 하던 중이었는지 남겼는가 (`dm_exec_sql_text`, 마지막 요청 시각)
- [ ] 죽였을 때 롤백이 얼마나 걸릴지 가늠했는가 (`KILL n WITH STATUSONLY`)
- [ ] 죽이는 대신 애플리케이션에서 닫게 할 수 있는지 확인했는가

---

## 6. 이 절차가 답하지 못하는 것

- **범인 쿼리 찾기.** 대기가 IO 나 CPU 를 가리킬 때 `sys.dm_exec_query_stats` 로
  좁히는 단계가 이 문서에 없습니다.
- **사고가 지나간 뒤.** 스냅샷을 미리 안 떴으면 차분을 못 봅니다. 주기적으로 떠 두는
  수집기가 필요한데 이 세션은 만들지 않았습니다.
- **Query Store.** 2016 이후로는 그쪽이 표준에 가까운데 DMV 만 다뤘습니다.
