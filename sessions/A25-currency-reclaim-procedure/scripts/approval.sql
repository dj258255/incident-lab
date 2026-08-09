-- 회수 승인 절차.
--
-- usp_ReclaimCurrency 는 실행하면 바로 돈다. 회수는 이용자 자산을 줄이는 작업인데
-- 한 사람이 마음먹으면 그대로 나간다. 승인 대기를 붙인다.
--
-- 승인만 붙이면 뚫리는 자리가 하나 있다. 승인은 "이 목록을 회수해도 된다"는 뜻인데,
-- 승인 뒤에 목록을 바꿔치기하면 승인은 그대로 유효하다. 그래서 **승인 시점의 대상
-- 지문을 저장해 두고 실행할 때 다시 대조한다.** 실험 5에서 이관 검증에 쓴 것과
-- 같은 지문이다.
CREATE TABLE correction_request (
    request_id   INT IDENTITY(1,1) PRIMARY KEY,
    reason       NVARCHAR(200) NOT NULL,
    target_rows  INT           NOT NULL,   -- 요청 시점 대상 건수
    target_sum   BIGINT        NOT NULL,   -- 요청 시점 대상 합계
    target_chk   BIGINT        NOT NULL,   -- 요청 시점 대상 체크섬
    requested_by SYSNAME       NOT NULL,
    requested_at DATETIME2(3)  NOT NULL DEFAULT SYSDATETIME(),
    approved_by  SYSNAME       NULL,
    approved_at  DATETIME2(3)  NULL,
    status       VARCHAR(20)   NOT NULL DEFAULT 'PENDING',  -- PENDING|APPROVED|EXECUTED
    batch_id     INT           NULL
);
GO

-- 대상 지문. 건수·합계·체크섬 셋을 함께 본다.
CREATE OR ALTER FUNCTION dbo.fn_TargetFingerprint()
RETURNS TABLE
AS RETURN
    SELECT COUNT(*) AS rows_,
           ISNULL(SUM(extra_amount), 0) AS sum_,
           ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(account_id, extra_rows, extra_amount)), 0) AS chk_
      FROM reclaim_target;
GO

-- 요청자(maker). 지금 대상 목록의 지문을 찍어 대기로 남긴다.
CREATE OR ALTER PROCEDURE usp_RequestReclaim
    @reason     NVARCHAR(200),
    @request_id INT = NULL OUTPUT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO correction_request (reason, target_rows, target_sum, target_chk, requested_by)
    SELECT @reason, rows_, sum_, chk_, ORIGINAL_LOGIN()
      FROM dbo.fn_TargetFingerprint();
    SET @request_id = CAST(SCOPE_IDENTITY() AS INT);
    SELECT @request_id AS request_id;
END
GO

-- 승인자(checker). 요청자와 같은 사람이면 거부한다.
CREATE OR ALTER PROCEDURE usp_ApproveReclaim
    @request_id INT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @status VARCHAR(20), @requester SYSNAME;
    SELECT @status = status, @requester = requested_by
      FROM correction_request WHERE request_id = @request_id;

    IF @status IS NULL       THROW 50020, N'없는 요청입니다', 1;
    IF @status <> 'PENDING'  THROW 50021, N'대기 상태가 아닙니다', 1;
    IF @requester = ORIGINAL_LOGIN()
        THROW 50022, N'요청자가 자기 요청을 승인할 수 없습니다', 1;

    UPDATE correction_request
       SET status = 'APPROVED', approved_by = ORIGINAL_LOGIN(), approved_at = SYSDATETIME()
     WHERE request_id = @request_id;
END
GO

-- 승인을 확인한 뒤에만 회수를 돌린다.
CREATE OR ALTER PROCEDURE usp_ReclaimCurrencyGated
    @request_id INT,
    @mode       VARCHAR(10) = 'DEBT',
    @chunk      INT         = 4000
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @status VARCHAR(20), @reason NVARCHAR(200),
            @rows INT, @sum BIGINT, @chk BIGINT;
    SELECT @status = status, @reason = reason,
           @rows = target_rows, @sum = target_sum, @chk = target_chk
      FROM correction_request WHERE request_id = @request_id;

    IF @status IS NULL        THROW 50023, N'없는 요청입니다', 1;
    IF @status = 'EXECUTED'   THROW 50024, N'이미 실행된 요청입니다', 1;
    IF @status <> 'APPROVED'  THROW 50025, N'승인되지 않은 요청입니다', 1;

    -- 승인 뒤에 목록이 바뀌지 않았는지 본다. 승인은 그 목록에 대한 승인이다.
    DECLARE @now_rows INT, @now_sum BIGINT, @now_chk BIGINT;
    SELECT @now_rows = rows_, @now_sum = sum_, @now_chk = chk_ FROM dbo.fn_TargetFingerprint();
    IF @now_rows <> @rows OR @now_sum <> @sum OR @now_chk <> @chk
        THROW 50026, N'승인 뒤에 회수 대상이 바뀌었습니다', 1;

    DECLARE @b INT;
    EXEC usp_ReclaimCurrency @reason = @reason, @mode = @mode, @chunk = @chunk, @batch_id = @b OUTPUT;

    UPDATE correction_request SET status = 'EXECUTED', batch_id = @b WHERE request_id = @request_id;
END
GO
