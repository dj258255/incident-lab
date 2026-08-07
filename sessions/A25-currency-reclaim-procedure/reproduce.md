# A25 재현 기록

실행한 명령과 출력을 원문 그대로 붙입니다.

## 0. 측정 호스트

```console
$ uname -srm
Darwin 25.3.0 arm64
$ sysctl -n hw.ncpu hw.memsize
12
34359738368
```

## 1. 환경 기동

```console
$ docker compose up -d
[+] Running 1/1
 ✔ Container a25-mssql  Started
```

## 2. 실험 1. 스키마와 제약

```console
$ ./scripts/exp1-schema.sh
# 실험 1. 스키마와 보정 프로시저
# MicrosoftSQLServer2022(RTM-CU26)(KB509342

  계정 1000000개, 회수 대상 60000개.
  대상 중 3분의 1은 이미 재화를 써서 잔액이 회수액보다 적습니다.

## 1-1. 표
  account_currency, reclaim_target, correction_batch, correction_detail

## 1-2. 적재
  계정                   1000000개
  회수 대상            60000개
  잔액이 모자란 대상 20000개
  회수 총액            1839974000

## 1-3. 제약이 회수를 막는다

  계정 3 을 그대로 차감하면 막힙니다.
    Msg 547, Level 16, State 1, Server 6cd1d8134d56, Line 2

  **회수는 제약과 부딪힙니다.** 이미 쓴 재화를 되돌리려면 잔액이 음수가 돼야
  하는데 제약이 그것을 막습니다. 제약을 없애면 정상 흐름의 방어도 함께 사라집니다.

## 1-4. 두 설계

  A안 음수 잔액 허용   제약을 빼고 잔액이 음수로 내려가게 둔다.
                        이후 획득분이 자연스럽게 상계된다.
  B안 빚 컬럼 분리      잔액은 0 이상을 유지하고 못 받은 만큼을 debt 에 적는다.
                        제약이 살아 있고, 빚이 있는 계정을 따로 셀 수 있다.

  둘 다 만들고 실험 2에서 견줍니다.

  준비 완료. 회수 총액 1839974000, 배치 크기 4000.
```

## 3. 실험 2. 회수 실행과 두 설계

```console
$ ./scripts/exp2-reclaim.sh
# 실험 2. 회수 실행과 두 설계의 대조

  회수 대상 60000개, 그중 잔액이 모자란 계정 20000개.
  회수해야 할 총액 1839974000. 배치 크기 4000.

  시간은 적지 않습니다. ARM 에뮬레이션이라 이 호스트의 값이 아닙니다.
  회수 정확도, 승격 횟수, 감사 로그 완결성을 봅니다. 셋 다 시간이 아닙니다.

  usp_ReclaimCurrency 설치 완료

  설계     배치수 회수액        검산   승격     음수 계정 빚 계정
  NEGATIVE   15회    1839974000       일치   0회       20000개     0개
  DEBT       15회    1839974000       일치   0회       0개         20000개

## 2-2. 감사 로그가 회수를 재구성하는가

  이의 제기가 오면 감사 로그만으로 "이 계정에서 얼마를 왜 뺐는지"를
  답할 수 있어야 합니다. 로그의 전후 값이 실제 잔액과 맞는지 봅니다.

  감사 로그 행              60000건
  기록한 사후 잔액 = 실제 잔액 60000건
  적용액 + 빚 = 대상액    60000건

  **모든 행에서 맞습니다.** 감사 로그만으로 회수를 재구성할 수 있습니다.

## 2-3. 빚은 어떻게 갚히는가

  회수 뒤 이용자가 재화를 얻으면 빚이 상계돼야 합니다. 두 설계가 다릅니다.

  계정 3  획득 5000 전: 잔액/빚 0/12000  →  후: 0/7000

  DEBT 설계는 빚을 먼저 갚는 로직을 **따로 만들어야** 합니다. 획득 경로가
  여럿이면 그 전부에 같은 규칙이 들어가야 하고, 하나라도 빠지면 빚이 남습니다.
  NEGATIVE 설계는 잔액이 음수라 더하기만 해도 자연히 상계됩니다. 대신 잔액이
  음수인 동안 다른 코드가 그 값을 어떻게 다루는지 전부 확인해야 합니다.

==================================================================
## 정리
==================================================================

  두 설계 모두 회수 총액은 같습니다. 검산이 통과하고 감사 로그도 맞습니다.
  배치를 4000행으로 끊어 승격은 한 번도 일어나지 않았습니다.

  갈리는 것은 그 뒤입니다.
    NEGATIVE  제약을 빼야 한다. 상계는 공짜지만 음수 잔액을 읽는 모든 코드가 위험.
    DEBT      제약이 살아 있고 빚을 따로 셀 수 있다. 대신 상계 로직을 만들어야 한다.

  운영에서 고를 것은 DEBT 입니다. 제약을 빼는 것은 되돌리기 어렵고, 그 사이에
  들어온 다른 버그가 음수 잔액을 만들어도 아무도 모릅니다. 빚 컬럼은 늘어나는
  일이지만 무엇이 남았는지 셀 수 있습니다.
```

## 4. 실험 3. 실패와 재시작, 동시성

```console
$ ./scripts/exp3-restart.sh
# 실험 3. 중간에 죽었을 때와 동시에 썼을 때

## 3-1. 다섯 번째 배치에서 죽인다

  주입한 실패가 던져졌습니다: Msg 50001, Level 16, State 1, Server 6cd1d8134d56, Procedure usp_ReclaimCurrency, Line 58
  처리된 계정         16000개
  진행 지점(last_done) 16000
  배치 상태            RUNNING
  여기까지 회수한 금액 490597000

  앞 배치는 커밋돼 남아 있습니다. 원자성을 내준 대가입니다.
  대신 진행 지점이 같은 트랜잭션에서 옮겨졌으므로 어디까지 했는지는 정확합니다.

## 3-2. 같은 배치를 이어서 돌린다

  처리된 계정         60000개
  두 번 처리된 계정 0개
  빠진 계정            0개
  회수 총액            1839974000
  배치 상태            DONE

  **두 번 뺀 계정도, 빠진 계정도 없습니다.** 진행 지점을 배치와 같은 트랜잭션에서
  옮긴 것이 여기서 값을 합니다. 밖에서 옮겼으면 커밋과 기록 사이에 죽었을 때
  같은 배치를 두 번 돌아 이중 회수가 됩니다.

## 3-3. 보정 중에 이용자가 재화를 쓰면

  보정이 도는 동안 같은 계정의 잔액을 이용자가 바꿉니다.
  회수는 성공으로 기록되는데 실제 잔액은 안 줄어 있을 수 있습니다.

  대상 계정                  60000
  회수해야 할 금액        85000
  보정 전 잔액              73000
  감사 로그의 전/후 잔액 68000 → 0
  감사 로그의 적용액/빚 68000/17000
  최종 잔액/빚              0/17000

  감사 로그는 보정 시점의 전후를 그대로 적습니다. 그 뒤 이용자가 더 쓴 것은
  로그에 안 남고 최종 잔액에만 반영됩니다. 로그의 사후 잔액과 지금 잔액이
  다른 것은 그래서이고, 회수 자체가 새는 것과는 다릅니다.

  **회수가 새는지는 갱신이 원자적인가로 갈립니다.** 이 프로시저는
  balance = balance - amount 로 읽고 쓰기를 한 문장에 두었습니다. 값을 먼저
  읽어 애플리케이션에서 뺀 뒤 써 넣었다면 그 사이의 사용이 덮여 사라집니다.

  회수액이 대상과 다른 계정 0개
  동시 사용이 있어도 회수 금액은 대상과 정확히 같습니다.

==================================================================
## 정리
==================================================================

  배치를 쪼개면 원자성을 내줍니다. 중간에 죽으면 앞 배치는 남습니다.
  그 대가를 감당할 수 있게 만드는 것이 **진행 지점을 배치와 같은 트랜잭션에서**
  옮기는 것입니다. 그러면 이어서 돌 때 두 번 빼지도 건너뛰지도 않습니다.

  동시 사용이 있어도 회수 금액은 정확했습니다. 갱신을 한 문장에 둔 덕입니다.
  읽고 계산하고 쓰는 것을 나누면 그 사이의 사용이 조용히 사라집니다.
```

## 5. 실험 4. 잘못된 보정 되돌리기

```console
$ ./scripts/exp4-undo.sh
# 실험 4. 잘못된 보정을 되돌린다

## 4-1. 보정 전 상태와 전체 백업
  보정 전 잔액 합계   67999983000
  전체 백업 완료

## 4-2. 되돌릴 지점에 이름을 붙인다
  BEGIN TRAN before_reclaim WITH MARK '보정 직전'

## 4-3. 잘못된 목록으로 보정한다
  잘못 포함된 정상 계정 600개
  잘못된 보정 뒤 잔액 합계 66394009600

## 4-4. 로그 백업 후 표시 지점으로 되돌린다
  복원 상태              ONLINE
  복원본의 잔액 합계 67999983000

  **보정 직전 상태로 정확히 돌아왔습니다.** 표시 지점 이후의 회수가 전부 사라졌습니다.

## 4-5. 벽시계로 가리키면

  같은 로그 백업을 시각으로 되돌려 봅니다. 표시가 아니라 초 단위 시각을 씁니다.
  표시 시각 2026-08-07 05:22:51.877 로 복원: 잔액 합계 67999983000
  이 회차에서는 시각으로도 같은 결과가 나왔습니다. 표시가 남긴 시각을 그대로
  썼기 때문입니다. 실무에서는 그 시각을 모르는 채 어림해야 하고, 초 단위
  반올림 때문에 같은 초에 커밋된 것이 함께 딸려 옵니다.

==================================================================
## 정리
==================================================================

  보정은 되돌릴 수 있어야 합니다. 회수 대상 목록이 틀릴 수 있기 때문입니다.
  A24 의 통계 이탈이 정상 계정 40개를 지목한 것을 그대로 회수했다면 그 상황입니다.

  되돌릴 지점은 이름으로 잡습니다. 보정을 시작하기 전에 BEGIN TRAN ... WITH MARK
  로 표시를 남기면 그 이름으로 정확히 그 지점까지만 복원할 수 있습니다.

  **표시의 이점은 시각이 안 통해서가 아닙니다.** 이 실험에서 표시가 남긴 시각을
  그대로 STOPAT 에 넣으니 같은 결과가 나왔습니다. 이점은 **그 시각을 안다**는
  것입니다. 표시가 없으면 사고 뒤에 "보정을 몇 시 몇 분에 시작했더라"를 로그에서
  어림해야 하고, 초 단위 반올림 때문에 같은 초의 다른 커밋이 함께 딸려 옵니다.

  전제가 둘 있습니다. 복구 모델이 FULL 이어야 하고 로그 백업 체인이 이어져
  있어야 합니다. 둘 중 하나라도 없으면 표시를 남겨도 쓸 수 없습니다.
```

## 6. 보정 프로시저

```sql
-- 재화 회수 프로시저.
--
-- 설계에서 정한 것 넷.
--   1) 배치마다 커밋한다. 전체를 한 트랜잭션으로 묶으면 락이 누적돼 승격하고,
--      그러면 보정 대상이 아닌 이용자의 조회까지 멈춘다(A04).
--   2) 배치 크기는 5,000 미만이다. 실측 발동 지점은 테이블 락 6,250개였다(A04).
--   3) 진행 지점을 배치와 같은 트랜잭션에서 기록한다. 중간에 죽어도 이어서 돈다.
--   4) 계정마다 전후 값을 남긴다. 이의 제기가 오면 이 기록이 근거가 된다.
--
-- 잔액이 모자란 계정의 처리는 두 가지다.
--   NEGATIVE  잔액을 음수로 내린다. 이후 획득분이 자연히 상계된다.
--   DEBT      잔액은 0 에서 멈추고 못 받은 만큼을 debt 에 적는다.
-- 어느 쪽이든 회수 총액은 같아야 한다. applied + debt = target.
CREATE OR ALTER PROCEDURE usp_ReclaimCurrency
    @reason   NVARCHAR(200),
    @mode     VARCHAR(10)  = 'NEGATIVE',   -- NEGATIVE | DEBT
    @chunk    INT          = 4000,
    @fail_at  INT          = NULL,          -- 실패 주입: 이 회차에서 던진다
    @batch_id INT          = NULL OUTPUT    -- 주면 그 배치를 이어서 돈다
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;   -- 오류가 나면 트랜잭션을 확실히 되돌린다

    IF @mode NOT IN ('NEGATIVE', 'DEBT')
        THROW 50010, N'@mode 는 NEGATIVE 또는 DEBT 여야 합니다', 1;
    IF @chunk >= 5000
        THROW 50011, N'@chunk 는 5000 미만이어야 합니다. 락 승격을 피하기 위한 상한입니다', 1;

    IF @batch_id IS NULL
    BEGIN
        INSERT INTO correction_batch (reason) VALUES (@reason);
        SET @batch_id = CAST(SCOPE_IDENTITY() AS INT);
    END

    DECLARE @lo INT = (SELECT last_done FROM correction_batch WHERE batch_id = @batch_id);
    DECLARE @round INT = 0;

    DECLARE @c   TABLE (account_id INT PRIMARY KEY, amount BIGINT);
    DECLARE @aud TABLE (account_id INT PRIMARY KEY, before_bal BIGINT, after_bal BIGINT,
                        before_debt BIGINT, after_debt BIGINT);

    WHILE 1 = 1
    BEGIN
        DELETE FROM @c;
        INSERT INTO @c (account_id, amount)
        SELECT TOP (@chunk) account_id, extra_amount
          FROM reclaim_target
         WHERE account_id > @lo
         ORDER BY account_id;

        IF NOT EXISTS (SELECT 1 FROM @c) BREAK;

        SET @round += 1;
        -- 실패 주입은 트랜잭션 밖에서 던진다. 앞 배치는 이미 커밋돼 있어야
        -- "이어서 돌 수 있는가"를 볼 수 있다.
        IF @fail_at IS NOT NULL AND @round = @fail_at
            THROW 50001, N'주입한 실패', 1;

        DELETE FROM @aud;

        BEGIN TRAN;

            IF @mode = 'NEGATIVE'
                UPDATE a
                   SET a.balance = a.balance - c.amount
                OUTPUT inserted.account_id, deleted.balance, inserted.balance,
                       deleted.debt, inserted.debt
                  INTO @aud (account_id, before_bal, after_bal, before_debt, after_debt)
                  FROM account_currency a
                  JOIN @c c ON c.account_id = a.account_id;
            ELSE
                UPDATE a
                   SET a.balance = CASE WHEN a.balance >= c.amount THEN a.balance - c.amount ELSE 0 END,
                       a.debt    = a.debt + CASE WHEN a.balance >= c.amount THEN 0 ELSE c.amount - a.balance END
                OUTPUT inserted.account_id, deleted.balance, inserted.balance,
                       deleted.debt, inserted.debt
                  INTO @aud (account_id, before_bal, after_bal, before_debt, after_debt)
                  FROM account_currency a
                  JOIN @c c ON c.account_id = a.account_id;

            INSERT INTO correction_detail
                (batch_id, account_id, target_amount, applied_amount, debt_amount,
                 balance_before, balance_after)
            SELECT @batch_id, c.account_id, c.amount,
                   u.before_bal - u.after_bal,          -- 잔액에서 실제로 뺀 금액
                   u.after_debt - u.before_debt,        -- 빚으로 남긴 금액
                   u.before_bal, u.after_bal
              FROM @c c JOIN @aud u ON u.account_id = c.account_id;

            SET @lo = (SELECT MAX(account_id) FROM @c);
            -- 진행 지점을 같은 트랜잭션에서 옮긴다. 밖에서 옮기면 커밋과 기록 사이에
            -- 죽었을 때 같은 배치를 두 번 돌게 된다.
            UPDATE correction_batch SET last_done = @lo WHERE batch_id = @batch_id;

        COMMIT;
    END

    -- 검산. 회수한 것과 회수해야 할 것이 맞는지 본다. 안 맞으면 배치를 실패로 남긴다.
    DECLARE @target BIGINT = (SELECT SUM(extra_amount) FROM reclaim_target);
    DECLARE @done   BIGINT = (SELECT ISNULL(SUM(applied_amount + debt_amount), 0)
                                FROM correction_detail WHERE batch_id = @batch_id);

    IF @target <> @done
    BEGIN
        UPDATE correction_batch SET status = 'MISMATCH' WHERE batch_id = @batch_id;
        THROW 50002, N'검산 불일치: 회수 합계가 대상 합계와 다릅니다', 1;
    END

    UPDATE correction_batch SET status = 'DONE' WHERE batch_id = @batch_id;
    SELECT @batch_id AS batch_id, @round AS rounds, @done AS reclaimed;
END
```

## 7. 결과 데이터

### results/dataset.csv

```
metric,value
accounts,1000000
targets,60000
short_targets,20000
reclaim_total,1839974000
chunk,4000
```

### results/reclaim.csv

```
mode,rounds,reclaimed,target,match,escalations,negative_accounts,debt_accounts,audit_rows
NEGATIVE,15,1839974000,1839974000,일치,0,20000,0,60000
DEBT,15,1839974000,1839974000,일치,0,0,20000,60000
audit,60000,60000,60000
```

### results/restart.csv

```
phase,accounts,dup,missing,total,status
after_fail,16000,,,490597000,RUNNING
after_resume,60000,0,0,1839974000,DONE
concurrency,60000,85000,73000,68000,0,0,17000,0
```

### results/undo.csv

```
metric,value
before_balance,67999983000
after_wrong_reclaim,66394009600
restored_stopatmark,67999983000
wrong_accounts,600
mark_time,2026-08-07 05:22:51.877
```

