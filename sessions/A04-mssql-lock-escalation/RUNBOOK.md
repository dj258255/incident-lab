# 운영 절차서: 대량 데이터 보정 배치

대상: SQL Server 재화·인벤토리 등 라이브 테이블의 대량 UPDATE·DELETE 작업
근거: 같은 디렉토리의 [README.md](README.md) 실측. 수치는 전부 그 실험에서 나온 값입니다.

이 문서는 "왜 그런가"가 아니라 "무엇을 할 것인가"만 적습니다. 근거가 궁금하면 README 를 봅니다.

---

## 0. 한 줄 요약

**보정 배치는 쪼개고, 배치마다 커밋하고, 시작 전에 통계를 갱신한다.**
배치 크기는 **갱신 컬럼에 보조 인덱스가 붙어 있으면 2,000행 이하, 없으면 4,000행**이다.
안 그러면 보정 대상이 아닌 이용자의 조회까지 보정이 끝날 때까지 멈춘다.

---

## 1. 작업 전 확인 (필수)

| # | 확인 | 명령 | 통과 기준 |
|---|---|---|---|
| 1 | 대상 건수 | `SELECT COUNT(*) FROM <표> WHERE <조건>` | 2절에서 정한 배치 크기로 나눠 배치 수를 계산해 둔다 |
| 2 | 통계 상태 | `SELECT name, STATS_DATE(object_id, stats_id) FROM sys.stats WHERE object_id = OBJECT_ID('<표>')` | 최근 갱신. 낡았으면 3번 |
| 3 | 통계 갱신 | `UPDATE STATISTICS <표> WITH FULLSCAN` | 대상 표가 크면 `SAMPLE` 로 |
| 4 | 락 승격 설정 | `SELECT lock_escalation_desc FROM sys.tables WHERE name = '<표>'` | 기본 `TABLE`. `DISABLE` 이면 왜 그런지 확인 |
| 5 | 격리 수준 | `SELECT is_read_committed_snapshot_on FROM sys.databases WHERE name = DB_NAME()` | 켜져 있으면 읽기는 안 막힘 |
| 6 | 여는 트랜잭션 | `SELECT * FROM sys.dm_tran_session_transactions` | 남의 롱 트랜잭션이 있으면 먼저 정리 |
| 7 | 롤백 지점 | `BEGIN TRAN <이름> WITH MARK '<사유>'` 로 시작 | 복구 모델 FULL + 로그 백업 체인 필요 |

**3번을 건너뛰지 않습니다.** 통계가 낡으면 같은 행 수가 락을 더 잡아 승격 임계값을 넘길 수 있습니다.

---

## 2. 배치 크기 결정

**먼저 보정문이 갱신하는 컬럼에 보조 인덱스가 붙어 있는지 셉니다.** 이것이 배치 크기를
가릅니다. 갱신 컬럼이 보조 인덱스의 키이면 그 인덱스 행은 제자리에서 못 바뀌고 옛 자리에서
지워졌다 새 자리에 들어가므로, **행당 락이 2개 더 붙습니다.**

```sql
-- 보정문이 갱신하는 컬럼을 키로 담은 인덱스를 센다
SELECT i.name, i.type_desc
  FROM sys.indexes i
  JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
  JOIN sys.columns c ON c.object_id = i.object_id AND c.column_id = ic.column_id
 WHERE i.object_id = OBJECT_ID('<표>')
   AND i.type_desc = 'NONCLUSTERED'
   AND ic.key_ordinal > 0                        -- 포함 열이 아니라 키인 것만
   AND c.name IN ('<보정문이 갱신하는 컬럼들>')
 GROUP BY i.name, i.type_desc;
```

**임계값은 인덱스 하나에 락 5,000개입니다.** 엔진은 문장이 락을 1,250개 잡을 때마다
검사하고, 그 시점에 락이 5,000개 이상인 인덱스를 승격시킵니다. 문장 전체 락이 아니라
인덱스 하나가 기준입니다.

| 상황 | 행당 락 (그 인덱스 기준) | 배치 크기 | 근거 |
|---|---|---|---|
| 갱신 컬럼에 보조 인덱스 **없음** | 클러스터드 1개 | **4,000행** | 5,000/1 = 5,000 이 상한. 실측 경계 6,230행 |
| 갱신 컬럼에 보조 인덱스 **1개 이상** | 그 인덱스에 2개 | **2,000행 이하** | 5,000/2 = 2,500 이 상한. 실측 경계 2,907행(1개)·2,491행(2개) |
| 통계를 못 갱신함 | **2,000행 이하** | 계획이 락을 더 잡을 수 있다 |
| 표가 40만행 이상이고 전체 갱신 | 배치 분할 유지 | 엔진이 페이지 락을 골라 승격은 안 하지만, 페이지 락도 같은 페이지의 남의 행을 막는다 |

갱신하지 **않는** 컬럼의 인덱스는 세지 않습니다. 그 인덱스 행은 안 바뀌므로 락이 안 붙고,
실측에서도 경계가 6,230행으로 기준과 같았습니다.

문서의 5,000 을 그대로 쓰지 않는 이유는 여유가 문서로 보장되지 않기 때문이고,
인덱스가 셋 이상인 경우는 재지 않았으므로 그때는 더 내려 잡습니다.

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

### 반대로 승격이 안 났을 때

**승격이 안 났다고 안심하지 않습니다.** 옆 세션이 같은 표에 락을 들고 있으면 승격이
실패하고 행 락을 그대로 들고 갑니다. 실측에서 20,000행 갱신이 행 락 20,000개를 끝까지
들고 있었습니다.

```sql
-- 행 락이 대량으로 남아 있는가
SELECT COUNT(*) FROM sys.dm_tran_locks
 WHERE resource_type = 'KEY' AND resource_database_id = DB_ID();
```

수만 개가 보이면 승격이 실패한 상태입니다. 락 매니저 메모리를 그만큼 쓰고 있고,
**옆 세션이 커밋하는 순간 다음 재시도가 성공해 테이블이 잠깁니다.** 배치를 쪼개지 않은
채 "오늘은 승격 안 났다"고 넘기면 안 됩니다.

### 파티션 테이블이면

기본값 `TABLE` 은 파티션이 있어도 테이블 전체를 잠급니다. `AUTO` 로 바꾸면 파티션
단위(`HOBT` 락)로 승격해 그 파티션 밖은 안 막힙니다.

```sql
ALTER TABLE <표> SET (LOCK_ESCALATION = AUTO);
```

**AUTO 는 공짜가 아닙니다.** 실측에서 두 세션이 파티션 둘을 반대 순서로 건드리자
`TABLE` 은 0건, `AUTO` 는 3회 중 3회 데드락이 났습니다. 건드리는 행이 겹치지 않았는데도
그렇습니다. 각자 자기 파티션을 잡고 상대 파티션을 기다려 순환이 생깁니다.

AUTO 를 쓰려면 셋을 지킵니다.

1. 보정 배치가 **한 파티션 안에서 끝나도록** 짠다
2. 여러 파티션을 건드려야 하면 **파티션 순서를 모든 작업에서 같게 고정한다**
3. 데드락(1205) 재시도를 배치 루프에 넣는다

2번이 제일 자주 빠집니다. 보정 배치는 계정 순으로 도는데 다른 작업이 다른 순서로
돌면 그 둘이 만납니다.

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

---

## 데드락 재시도 루프

`LOCK_ESCALATION = AUTO` 를 쓰거나 보정 배치가 게임 트래픽과 같은 표를 건드리면
데드락(1205)이 납니다. 재시도는 **트랜잭션 경계 밖**에 둡니다.

```sql
SET DEADLOCK_PRIORITY LOW;   -- 보정 배치가 진다. 게임 트래픽이 이긴다

DECLARE @try INT = 0, @max INT = 5, @ok INT = 0;
WHILE @try < @max AND @ok = 0
BEGIN
    SET @try = @try + 1;
    BEGIN TRY
        BEGIN TRAN;
            /* 배치 하나. 진행 위치 갱신까지 같은 트랜잭션 안에 둔다 */
        COMMIT;
        SET @ok = 1;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() <> 1205 THROW;   -- 1205 만 재시도한다
        DECLARE @ms INT = 200 + ABS(CHECKSUM(NEWID())) % 1500;
        DECLARE @d VARCHAR(12) = '00:00:'
             + RIGHT('0'  + CAST(@ms / 1000 AS varchar(2)), 2) + '.'
             + RIGHT('00' + CAST(@ms % 1000 AS varchar(3)), 3);
        WAITFOR DELAY @d;
    END CATCH
END
IF @ok = 0 THROW 50030, '재시도 상한 도달. 사람이 본다', 1;
```

| 항목 | 이유 |
|---|---|
| `SET DEADLOCK_PRIORITY LOW` | 안 주면 **엔진이 고른다.** 실측에서 9회 모두 게임 트래픽 쪽이 죽었다 |
| `ROLLBACK` 을 CATCH 첫 줄에 | 희생자의 트랜잭션은 이미 되돌아갔지만 `@@TRANCOUNT` 는 남는다 |
| `IF ERROR_NUMBER() <> 1205 THROW` | 나머지 오류를 같이 삼키면 사고를 재시도로 덮는다 |
| 지터 백오프 | 같은 간격으로 물러나면 같은 순서로 다시 만난다 |
| 시도 상한 | 상한에 닿으면 멈추고 사람을 부른다 |

재시도가 안전한 것은 재시도 코드 때문이 아니라 **배치 경계** 때문입니다. 진행 위치를
배치와 같은 트랜잭션에서 옮겨 두면 죽은 배치는 위치까지 함께 되돌아갑니다.
실측에서 네 조건 모두 결과 정합이 어긋난 회차가 없었습니다.

> `WAITFOR DELAY` 는 `'hh:mm:ss.mmm'` 만 받습니다. `CONVERT(..., 114)` 는 밀리초 앞에
> 콜론을 넣어 `'00:00:01:234'` 가 되고 그 모양은 시간으로 안 읽힙니다. 문자열을 손으로
> 만듭니다.
