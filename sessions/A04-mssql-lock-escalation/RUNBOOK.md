# 운영 절차서: 대량 데이터 보정 배치

대상: SQL Server 재화·인벤토리 등 라이브 테이블의 대량 UPDATE·DELETE 작업
근거: 같은 디렉토리의 [README.md](README.md) 실측. 수치는 전부 그 실험에서 나온 값입니다.

이 문서는 "왜 그런가"가 아니라 "무엇을 할 것인가"만 적습니다. 근거가 궁금하면 README 를 봅니다.

---

## 0. 한 줄 요약

**보정 배치는 5,000행 미만으로 쪼개고, 배치마다 커밋하고, 시작 전에 통계를 갱신한다.**
안 그러면 보정 대상이 아닌 이용자의 조회까지 보정이 끝날 때까지 멈춘다.

---

## 1. 작업 전 확인 (필수)

| # | 확인 | 명령 | 통과 기준 |
|---|---|---|---|
| 1 | 대상 건수 | `SELECT COUNT(*) FROM <표> WHERE <조건>` | 배치 수 = 건수 / 5000 을 계산해 둔다 |
| 2 | 통계 상태 | `SELECT name, STATS_DATE(object_id, stats_id) FROM sys.stats WHERE object_id = OBJECT_ID('<표>')` | 최근 갱신. 낡았으면 3번 |
| 3 | 통계 갱신 | `UPDATE STATISTICS <표> WITH FULLSCAN` | 대상 표가 크면 `SAMPLE` 로 |
| 4 | 락 승격 설정 | `SELECT lock_escalation_desc FROM sys.tables WHERE name = '<표>'` | 기본 `TABLE`. `DISABLE` 이면 왜 그런지 확인 |
| 5 | 격리 수준 | `SELECT is_read_committed_snapshot_on FROM sys.databases WHERE name = DB_NAME()` | 켜져 있으면 읽기는 안 막힘 |
| 6 | 여는 트랜잭션 | `SELECT * FROM sys.dm_tran_session_transactions` | 남의 롱 트랜잭션이 있으면 먼저 정리 |
| 7 | 롤백 지점 | `BEGIN TRAN <이름> WITH MARK '<사유>'` 로 시작 | 복구 모델 FULL + 로그 백업 체인 필요 |

**3번을 건너뛰지 않습니다.** 통계가 낡으면 같은 5,000행이 락을 더 잡아 승격 임계값을 넘길 수 있습니다.

---

## 2. 배치 크기 결정

| 상황 | 배치 크기 | 이유 |
|---|---|---|
| 기본 | **4,000행** | 실측 발동 지점은 테이블 락 6,250개. 여유를 둔다 |
| 보조 인덱스가 여럿 | **2,000행 이하** | 인덱스마다 락이 붙어 같은 행 수에 락이 더 잡힌다 |
| 통계를 못 갱신함 | **2,000행 이하** | 계획이 락을 더 잡을 수 있다 |
| 표가 40만행 이상이고 전체 갱신 | 배치 분할 유지 | 엔진이 페이지 락을 골라 승격은 안 하지만, 페이지 락도 같은 페이지의 남의 행을 막는다 |

문서의 5,000 을 그대로 쓰지 않고 4,000 으로 잡는 이유는 여유가 문서로 보장되지 않기 때문입니다.

---

## 3. 표준 배치 골격

```sql
DECLARE @lo INT = 0, @batch INT = 4000, @max INT;
SELECT @max = MAX(account_id) FROM <표>;          -- 시작 시점 워터마크로 고정

WHILE @lo < @max
BEGIN
    BEGIN TRAN;
        UPDATE <표>
           SET <컬럼> = <식>
         WHERE account_id > @lo
           AND account_id <= @lo + @batch
           AND <보정 조건>;
    COMMIT;                                        -- 배치마다 커밋해 락을 놓는다

    SET @lo += @batch;

    -- 라이브 부하가 지나갈 틈을 준다. 필요 없으면 지운다.
    WAITFOR DELAY '00:00:00.050';
END
```

지키는 것 셋:
1. **워터마크를 시작 시점에 고정한다.** 진행 중 들어오는 신규 행을 쫓으면 루프가 안 끝난다
2. **배치마다 커밋한다.** 쪼개기만 하고 트랜잭션 하나 안에서 돌면 락이 누적돼 결국 승격한다
3. **진행 위치를 남긴다.** 실제 운영에서는 `@lo` 를 진행 테이블에 기록해 재시작이 가능하게 한다

---

## 4. 작업 중 감시

다른 세션에서 30초 간격으로 확인합니다.

```sql
-- (1) 테이블 락으로 승격됐는가. 나오면 즉시 배치를 멈추고 크기를 줄인다
SELECT resource_type, request_mode, COUNT(*) AS cnt
  FROM sys.dm_tran_locks
 WHERE resource_database_id = DB_ID()
 GROUP BY resource_type, request_mode;
-- OBJECT + X 가 보이면 승격. 정상은 KEY + X 다수 + OBJECT + IX 하나

-- (2) 누가 막혀 있는가
SELECT r.session_id, r.wait_type, r.wait_time, r.blocking_session_id,
       t.text
  FROM sys.dm_exec_requests r
 CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
 WHERE r.blocking_session_id <> 0;
-- wait_type 이 LCK_M_IS 면 조회가 의도 공유 락을 못 받고 있다는 뜻

-- (3) 진행률
SELECT COUNT(*) AS 남은건수 FROM <표> WHERE <보정 조건>;
```

**중단 기준**: (1) 에서 `OBJECT` + `X` 가 관측되거나, (2) 에서 서비스 세션이 막히기 시작하면 즉시 멈춥니다.

---

## 5. 승격이 이미 일어났을 때

`sys.dm_tran_locks` 에 `OBJECT` + `X` 가 보인다고 전부 에스컬레이션은 아닙니다. 두 경로가
같은 화면으로 보입니다.

| 원인 | 확인 | 처방 |
|---|---|---|
| 에스컬레이션 | 확장 이벤트 `sqlserver.lock_escalation` 에 기록이 남음 | 배치 크기를 줄인다 |
| 계획이 처음부터 테이블 락 선택 | 이벤트가 없음 | 통계 갱신, 조건 재작성, 인덱스 확인. **배치만 쪼개면 각 배치가 다시 같은 선택을 받는다** |

확인용 세션:

```sql
CREATE EVENT SESSION esc_watch ON SERVER
  ADD EVENT sqlserver.lock_escalation
  ADD TARGET package0.ring_buffer WITH (MAX_MEMORY = 4096 KB);
ALTER EVENT SESSION esc_watch ON SERVER STATE = START;
-- 작업이 끝나면 STOP 후 DROP 한다
```

---

## 6. 쓰면 안 되는 것

| 수단 | 왜 |
|---|---|
| `LOCK_ESCALATION = DISABLE` 를 켜 두고 잊기 | 락 매니저 메모리는 인스턴스 전체가 나눠 쓴다. 20만행 보정에 락 20만 개를 끝까지 든다. 켰으면 **끄는 시점을 같이 정한다** |
| `WITH (TABLOCK)` 로 처음부터 테이블 락 | 빠르지만 그 시간 내내 서비스가 멈춘다. 점검 중에만 |
| `NOLOCK` 으로 감시 쿼리 돌리기 | 락 상태를 보는 쿼리가 락을 안 보면 의미가 없다 |
| 전체를 한 트랜잭션으로 묶어 원자성 확보 | 원자성이 꼭 필요하면 **보정 단위를 계정 묶음으로 잘게 정의**하고 묶음마다 원자적으로 돈다 |

---

## 7. 원자성이 필요한 보정

배치 분할은 원자성을 내주고 가용성을 삽니다. 보정 전체가 한 트랜잭션이 아니므로 중간에
실패하면 앞 배치는 이미 커밋돼 있습니다. 전부 되돌려야 하는 성격이면 둘 중 하나입니다.

1. **묶음 단위 원자성** — 계정 단위로 원자적이면 충분한 경우가 대부분입니다. 진행 테이블에
   처리한 계정을 기록하고 실패한 묶음만 다시 돌립니다.
2. **트랜잭션 마크로 되돌리기** — 보정 시작 전에 `BEGIN TRAN <이름> WITH MARK` 를 찍어 두면
   `RESTORE LOG ... WITH STOPATMARK = '<이름>'` 으로 그 지점 직전까지 복원할 수 있습니다.
   벽시계 시각(`STOPAT`)으로 가리키면 초 단위 반올림 때문에 경계에서 샙니다.
   근거는 [A23 세션](../A23-backup-pitr/)에 있습니다.

---

## 8. 작업 후

- [ ] 대상 건수가 기대와 일치하는가 (`WHERE <보정 후 조건>` 으로 센다)
- [ ] **대상 밖이 안 바뀌었는가** (이 확인을 빠뜨리면 범위 실수를 못 잡는다)
- [ ] 감사 로그에 전후 값과 사유가 남았는가
- [ ] `LOCK_ESCALATION` 을 바꿨으면 되돌렸는가
- [ ] 확장 이벤트 세션을 껐는가
- [ ] 보정 내역을 문서로 남겼는가 (대상 조건, 건수, 시각, 실행자, 근거)
