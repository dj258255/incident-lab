#!/usr/bin/env bash
# 실험 11. 승인 절차의 남은 구멍 넷.
#
# 실험 6은 승인 절차를 만들고 네 가지를 막았다. 그런데 못 한 것에 넷을 남겼다.
#   "승인 이력을 누가 고칠 수 있는지 안 봤습니다. 승인 기록을 지울 수 있으면
#    절차가 의미를 잃습니다."
#   "되돌리는 보정에 승인을 안 붙였습니다."
#   "승인자를 여러 명 요구하는 구조는 안 만들었습니다."
#   "승인의 유효 기간이 없습니다. 사흘 전 승인이 오늘도 통합니다."
#
# 넷 다 **절차가 있는데 그 절차를 우회하는 길**에 관한 것이다. 승인을 받게 만드는
# 것과 승인을 우회 못 하게 만드는 것은 다른 일이다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

wait_ready || exit 2

AS(){ docker exec "$CT" "$SQLCMD" -S localhost -U "$1" -P "$2" -C -h -1 -W -d "$DB" -Q "$3" 2>&1; }
LOGIN_PW='Lab_Passw0rd!'
msg(){ echo "$1" | grep -oE '^(Msg|메시지) [0-9]+' | head -1; }
why(){ echo "$1" | grep -viE '^(Msg|메시지)|^$|rows affected|개 행이' | head -1 | sed 's/^ *//' | cut -c1-64; }

{
echo "# 실험 11. 승인 절차의 남은 구멍"
echo
echo "  실험 6은 승인을 받게 만들었습니다. 여기서는 **그 승인을 우회할 수 있는지**"
echo "  봅니다. 넷을 하나씩 막고 막혔는지 확인합니다."
echo

# ── 기반 ────────────────────────────────────────────────────────────────
QDX "SET NOCOUNT ON;
DROP TABLE IF EXISTS approval_log;
DROP TABLE IF EXISTS approval_req;
CREATE TABLE approval_req (
    req_id       INT IDENTITY(1,1) PRIMARY KEY,
    reason       NVARCHAR(100) NOT NULL,
    target_rows  INT           NOT NULL,
    target_sum   BIGINT        NOT NULL,
    requested_by SYSNAME       NOT NULL DEFAULT ORIGINAL_LOGIN(),
    requested_at DATETIME2(3)  NOT NULL DEFAULT SYSDATETIME(),
    status       VARCHAR(20)   NOT NULL DEFAULT 'PENDING',
    -- 승인 유효 기간. 이 시각을 넘기면 다시 받아야 한다.
    expires_at   DATETIME2(3)  NOT NULL,
    -- 몇 명의 승인이 필요한가. 금액이 크면 늘어난다.
    need_approvals TINYINT     NOT NULL DEFAULT 1
);
CREATE TABLE approval_log (
    log_id      INT IDENTITY(1,1) PRIMARY KEY,
    req_id      INT      NOT NULL REFERENCES approval_req(req_id),
    approved_by SYSNAME  NOT NULL DEFAULT ORIGINAL_LOGIN(),
    approved_at DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT UQ_approval UNIQUE (req_id, approved_by)   -- 한 사람이 두 번 못 누른다
);" || exit 2

# 로그인 셋. 요청자, 승인자 둘.
# 로그인이 이미 있으면 만들지 않고 **비밀번호를 맞춰 준다.**
# 처음에 IF NOT EXISTS 로만 짰다가, 실험 6이 같은 이름을 다른 비밀번호로 만들어 둔
# 탓에 전부 "Login failed" 가 났다. 그런데 그 실패가 sqlcmd 의 오류라 Msg 로 안 잡혀
# **모든 확인이 "통과"로 찍혔다.** 막혔는지 보는 실험에서 제일 나쁜 실패다.
LOGIN_PW='Lab_Passw0rd!'
for L in maker checker1 checker2; do
  QD "IF SUSER_ID('$L') IS NULL
        CREATE LOGIN $L WITH PASSWORD = '$LOGIN_PW', CHECK_POLICY = OFF;
      ELSE
        ALTER LOGIN $L WITH PASSWORD = '$LOGIN_PW', CHECK_POLICY = OFF;" >/dev/null
  QDX "IF DATABASE_PRINCIPAL_ID('$L') IS NULL CREATE USER $L FOR LOGIN $L;" || exit 2
  # 붙을 수 있는지 확인하고 시작한다. 못 붙으면 이 실험은 성립하지 않는다.
  [ "$(num "$(AS "$L" "$LOGIN_PW" "SELECT 'O'+'K'")")" = "OK" ] \
    || { echo "중단: $L 로 못 붙습니다" >&2; exit 2; }
done

# 프로시저. 금액이 크면 승인자를 둘 요구하고, 유효 기간을 넣는다.
QF "SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
CREATE OR ALTER PROCEDURE usp_Request
    @reason NVARCHAR(100), @rows INT, @sum BIGINT, @hours INT = 24, @req_id INT OUTPUT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    -- 금액이 크면 승인자를 둘 요구한다. 기준은 정책이 정한다.
    DECLARE @need TINYINT = CASE WHEN @sum >= 1000000 THEN 2 ELSE 1 END;
    INSERT INTO approval_req (reason, target_rows, target_sum, expires_at, need_approvals, requested_by)
    VALUES (@reason, @rows, @sum, DATEADD(hour, @hours, SYSDATETIME()), @need, ORIGINAL_LOGIN());
    SET @req_id = SCOPE_IDENTITY();
END
GO
CREATE OR ALTER PROCEDURE usp_Approve @req_id INT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @by SYSNAME = ORIGINAL_LOGIN(), @maker SYSNAME, @exp DATETIME2(3), @need TINYINT;
    SELECT @maker = requested_by, @exp = expires_at, @need = need_approvals
      FROM approval_req WHERE req_id = @req_id;
    IF @maker IS NULL THROW 50060, N'no such request', 1;
    IF @maker = @by  THROW 50061, N'self approval', 1;
    IF SYSDATETIME() > @exp THROW 50062, N'approval expired', 1;
    INSERT INTO approval_log (req_id, approved_by) VALUES (@req_id, @by);
    IF (SELECT COUNT(*) FROM approval_log WHERE req_id = @req_id) >= @need
        UPDATE approval_req SET status = 'APPROVED' WHERE req_id = @req_id;
END
GO
CREATE OR ALTER PROCEDURE usp_Execute @req_id INT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @st VARCHAR(20), @exp DATETIME2(3), @need TINYINT, @got INT;
    SELECT @st = status, @exp = expires_at, @need = need_approvals FROM approval_req WHERE req_id = @req_id;
    SELECT @got = COUNT(*) FROM approval_log WHERE req_id = @req_id;
    IF @st IS NULL THROW 50063, N'no such request', 1;
    IF @got < @need THROW 50064, N'not enough approvals', 1;
    -- **실행 시점에도 유효 기간을 다시 본다.** 승인 때만 보면 그 뒤로 무한정 통한다.
    IF SYSDATETIME() > @exp THROW 50065, N'approval expired at execution', 1;
    SELECT 'EXECUTED' AS result;
END
GO" >/dev/null

QDX "GRANT EXECUTE ON usp_Request TO maker;
     GRANT EXECUTE ON usp_Approve TO checker1;
     GRANT EXECUTE ON usp_Approve TO checker2;
     GRANT EXECUTE ON usp_Execute TO maker;
     GRANT SELECT ON approval_req TO maker;
     GRANT SELECT ON approval_req TO checker1;
     -- 이력은 읽기만 준다. 고치는 것은 아무에게도 안 준다.
     GRANT SELECT ON approval_log TO maker;
     GRANT SELECT ON approval_log TO checker1;" || exit 2

: > "$OUT/approval-hardening.csv"
echo "check,actor,result,msg,detail" >> "$OUT/approval-hardening.csv"
printf "  %-38s %-12s %-12s %s\n" "확인" "누가" "결과" "메시지"

probe(){ # $1=라벨 $2=로그인 $3=SQL $4=기대(BLOCK|PASS)
  local out m v
  out=$(AS "$2" 'Lab_Passw0rd!' "$3")
  m=$(msg "$out")
  # sqlcmd 가 못 붙거나 죽은 것은 "통과"가 아니다. Msg 가 없어도 오류다.
  if echo "$out" | grep -qE 'Sqlcmd: Error'; then
    m="접속 실패"; v="**오류**"
  elif [ -n "$m" ]; then v="막힘"; else v="통과"; fi
  local ok="  "
  if [ "$4" = "BLOCK" ] && [ "$v" = "막힘" ]; then ok="OK"; fi
  if [ "$4" = "PASS"  ] && [ "$v" = "통과" ]; then ok="OK"; fi
  [ "$ok" = "OK" ] || v="**$v (기대와 다름)**"
  printf "  %-38s %-12s %-12s %s\n" "$1" "$2" "$v" "${m}  $(why "$out")"
  echo "\"$1\",\"$2\",\"$v\",\"$m\",\"$(why "$out")\"" >> "$OUT/approval-hardening.csv"
  LAST_OUT="$out"
}

echo "### 11-1. 승인 이력을 고칠 수 있는가"
echo
REQ=$(num "$(AS maker 'Lab_Passw0rd!' "SET NOCOUNT ON;
  DECLARE @id INT; EXEC usp_Request @reason=N'ghost reclaim', @rows=100, @sum=50000, @req_id=@id OUTPUT;
  SELECT CAST(@id AS varchar(12));")")
AS checker1 'Lab_Passw0rd!' "EXEC usp_Approve @req_id = $REQ;" >/dev/null

probe "승인 기록을 지운다" maker "DELETE FROM approval_log WHERE req_id = $REQ;" BLOCK
probe "승인자를 바꿔치기한다" maker "UPDATE approval_log SET approved_by = 'checker2' WHERE req_id = $REQ;" BLOCK
probe "요청 금액을 승인 뒤에 키운다" maker "UPDATE approval_req SET target_sum = 999999999 WHERE req_id = $REQ;" BLOCK
probe "승인 상태를 직접 APPROVED 로" maker "UPDATE approval_req SET status = 'APPROVED' WHERE req_id = 999;" BLOCK
probe "이력을 읽는 것은 된다" maker "SELECT COUNT(*) FROM approval_log WHERE req_id = $REQ;" PASS
echo
echo "  **표에 직접 쓰는 길은 전부 막혔습니다.** 아무에게도 UPDATE·DELETE 를 안 줬기"
echo "  때문입니다. 프로시저는 EXECUTE AS OWNER 로 돌아 자기 권한으로 씁니다."
echo "  읽기는 열어 둡니다. 이력을 못 읽으면 감사가 안 됩니다."
echo

echo "### 11-2. 승인자를 여러 명 요구한다"
echo
BIG=$(num "$(AS maker 'Lab_Passw0rd!' "SET NOCOUNT ON;
  DECLARE @id INT; EXEC usp_Request @reason=N'big reclaim', @rows=60000, @sum=2000000, @req_id=@id OUTPUT;
  SELECT CAST(@id AS varchar(12));")")
NEED=$(num "$(QD "SELECT CAST(need_approvals AS varchar(4)) FROM approval_req WHERE req_id = $BIG")")
echo "  금액 2,000,000 요청은 승인자 ${NEED}명을 요구합니다."
echo
probe "한 명만 승인하고 실행" checker1 "EXEC usp_Approve @req_id = $BIG;" PASS
probe "  그 상태로 실행하면" maker "EXEC usp_Execute @req_id = $BIG;" BLOCK
probe "같은 사람이 또 승인" checker1 "EXEC usp_Approve @req_id = $BIG;" BLOCK
probe "두 번째 승인자가 승인" checker2 "EXEC usp_Approve @req_id = $BIG;" PASS
probe "  이제 실행하면" maker "EXEC usp_Execute @req_id = $BIG;" PASS
echo
echo "  **한 사람이 두 번 눌러 정족수를 채우는 길이 막혀 있습니다.** 유일 제약"
echo "  (요청, 승인자) 하나가 그것을 합니다. 로직이 아니라 제약으로 막는 편이 낫습니다."
echo "  로직은 다른 경로가 생기면 빠뜨릴 수 있지만 제약은 표에 붙어 있습니다."
echo

echo "### 11-3. 승인에 유효 기간이 있는가"
echo
# 이미 지난 시각으로 만료되는 요청을 만든다.
OLD=$(num "$(AS maker 'Lab_Passw0rd!' "SET NOCOUNT ON;
  DECLARE @id INT; EXEC usp_Request @reason=N'stale', @rows=10, @sum=1000, @hours=-1, @req_id=@id OUTPUT;
  SELECT CAST(@id AS varchar(12));")")
probe "만료된 요청을 승인" checker1 "EXEC usp_Approve @req_id = $OLD;" BLOCK

# 승인은 제때 받고 그 뒤에 만료되는 경우. 실행 시점에도 막혀야 한다.
FRESH=$(num "$(AS maker 'Lab_Passw0rd!' "SET NOCOUNT ON;
  DECLARE @id INT; EXEC usp_Request @reason=N'expiring', @rows=10, @sum=1000, @hours=24, @req_id=@id OUTPUT;
  SELECT CAST(@id AS varchar(12));")")
AS checker1 'Lab_Passw0rd!' "EXEC usp_Approve @req_id = $FRESH;" >/dev/null
QD "UPDATE approval_req SET expires_at = DATEADD(hour, -1, SYSDATETIME()) WHERE req_id = $FRESH;" >/dev/null
probe "승인은 받았고 그 뒤 만료됨" maker "EXEC usp_Execute @req_id = $FRESH;" BLOCK
echo
echo "  **승인 시점과 실행 시점 둘 다 봐야 합니다.** 승인할 때만 보면 그 승인이"
echo "  영원히 유효해집니다. 사고 대응은 급해서 승인을 미리 받아 두는 일이 흔한데,"
echo "  그 승인이 사흘 뒤에도 통하면 그것은 승인이 아니라 백지 수표입니다."
echo

echo "### 11-4. 되돌리는 보정도 승인을 타는가"
echo
echo "  실험 8절의 되돌리기는 바로 실행됩니다. 되돌리기도 이용자 자산을 바꾸므로"
echo "  같은 절차를 타야 합니다. 되돌리기 요청을 같은 표에 올려 봅니다."
echo
UNDO=$(num "$(AS maker 'Lab_Passw0rd!' "SET NOCOUNT ON;
  DECLARE @id INT; EXEC usp_Request @reason=N'UNDO of req $BIG', @rows=600, @sum=1500000, @req_id=@id OUTPUT;
  SELECT CAST(@id AS varchar(12));")")
UNEED=$(num "$(QD "SELECT CAST(need_approvals AS varchar(4)) FROM approval_req WHERE req_id = $UNDO")")
echo "  되돌리기 요청도 금액이 커서 승인자 ${UNEED}명을 요구합니다."
probe "승인 없이 되돌리기 실행" maker "EXEC usp_Execute @req_id = $UNDO;" BLOCK
AS checker1 'Lab_Passw0rd!' "EXEC usp_Approve @req_id = $UNDO;" >/dev/null
AS checker2 'Lab_Passw0rd!' "EXEC usp_Approve @req_id = $UNDO;" >/dev/null
probe "둘이 승인한 뒤 실행" maker "EXEC usp_Execute @req_id = $UNDO;" PASS
echo
echo "  **되돌리기를 다른 절차로 만들지 않는 것이 요점입니다.** 같은 표에 같은 모양으로"
echo "  올리면 승인·정족수·유효 기간이 전부 그대로 걸립니다. 되돌리기 전용 경로를"
echo "  따로 파면 그 경로에 같은 방어를 다시 만들어야 하고, 실험 8에서 본 대로"
echo "  **같은 규칙을 두 곳에 두면 한 곳을 빠뜨립니다.**"

QD "DROP PROCEDURE IF EXISTS usp_Request;
    DROP PROCEDURE IF EXISTS usp_Approve;
    DROP PROCEDURE IF EXISTS usp_Execute;
    DROP TABLE IF EXISTS approval_log;
    DROP TABLE IF EXISTS approval_req;" >/dev/null

FAIL=$(grep -c '기대와 다름' "$OUT/approval-hardening.csv" || true)

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
if [ "${FAIL:-0}" = "0" ]; then
  echo "  **여덟 가지 우회 시도가 전부 기대대로 막히거나 통과했습니다.**"
else
  echo "  **${FAIL}건이 기대와 다릅니다.** 위 표에서 그 줄을 봅니다."
fi
echo
echo "  실험 6이 만든 것은 \"승인을 받게 하는 것\"이었고 여기서 채운 것은"
echo "  \"승인을 우회 못 하게 하는 것\"입니다. 둘은 다른 일입니다."
echo
echo "    이력을 못 고친다   표에 쓰기 권한을 아무에게도 안 준다"
echo "    정족수를 못 채운다 유일 제약 (요청, 승인자) 하나로 막는다"
echo "    승인이 안 늙는다   승인 시점과 **실행 시점** 둘 다 유효 기간을 본다"
echo "    되돌리기도 탄다    되돌리기를 같은 표에 같은 모양으로 올린다"
echo
echo "  둘째와 셋째가 특히 실무에서 빠지는 자리입니다. 승인자 수를 세는 로직은"
echo "  있는데 같은 사람이 두 번 누르는 것은 안 막고, 유효 기간은 승인할 때만 보고"
echo "  실행할 때는 안 봅니다. **둘 다 로직이 아니라 제약과 재확인으로 막습니다.**"
} 2>&1 | tee "$OUT/exp11-approval-hardening.txt"
