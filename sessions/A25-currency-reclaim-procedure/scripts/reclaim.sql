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
