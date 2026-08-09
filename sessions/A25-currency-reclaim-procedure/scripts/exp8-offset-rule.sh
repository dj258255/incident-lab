#!/usr/bin/env bash
# 실험 8. 상계 규칙을 어디에 둘 것인가.
#
# 실험 2는 DEBT 설계에서 "획득하면 빚을 먼저 갚아야 한다"는 규칙을 한 계정에 손으로
# 흉내 내고, 정리에 이렇게 적었다.
#   "획득 경로가 여럿이면 그 전부에 같은 규칙이 들어가야 하고, 하나라도 빠지면
#    빚이 남습니다."
#
# 그러고는 **경로를 여럿 만들어 보지 않았다.** "그것이 DEBT 설계의 진짜 비용"이라고
# 적어 놓고 그 비용을 안 잰 것이다.
#
# 그리고 이 문장에는 숨은 전제가 있다. 규칙이 **애플리케이션에 있다**는 전제다.
# 규칙을 DB 에 두면 경로가 몇 개든 한 곳이다. 그것을 견준다.
#
#   A 앱 경로마다     경로 넷 중 하나가 규칙을 빠뜨린다
#   B 트리거(행 단위) 한 곳이지만 **한 행 기준으로 짰다**
#   C 트리거(집합)    한 곳이고 집합으로 짰다
#   D 프로시저 강제   직접 UPDATE 를 막고 프로시저로만 준다
#
# B 가 이 실험의 핵심이다. 규칙을 DB 로 옮기면 "빠뜨릴 자리"는 없어지지만 대신
# **다른 방식으로 틀릴 수 있다.** 트리거는 문장당 한 번 도는데, 한 행 기준으로 짜면
# 여러 행을 한 번에 갱신할 때 나머지를 조용히 놓친다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
TBL=offset_test
N=${OFFSET_ACCOUNTS:-5000}   # 빚이 있는 계정
GAIN=${GAIN:-600}            # 각 계정이 얻는 재화
PATHS=4                      # 획득 경로 수(퀘스트·거래·우편·이벤트)

wait_ready || exit 2

# 트리거가 자기 테이블을 다시 갱신한다. 재귀 트리거가 켜져 있으면 무한히 돈다.
# 기본값은 OFF 지만 믿지 않고 물어본다.
REC=$(num "$(Q "SELECT CASE WHEN is_recursive_triggers_on = 1 THEN 'ON' ELSE 'OFF' END
                  FROM sys.databases WHERE name = '$DB'")")
[ "$REC" = "OFF" ] || { echo "중단: RECURSIVE_TRIGGERS 가 ON 입니다" >&2; exit 2; }

# 계정 절반은 빚이 획득보다 많고(전액이 빚으로), 절반은 적다(남는 만큼 잔액으로).
# 두 갈래를 다 넣어야 CASE 가 제대로 도는지 보인다.
setup(){
  QDX "SET NOCOUNT ON;
  IF OBJECT_ID('$TBL') IS NOT NULL DROP TABLE $TBL;
  CREATE TABLE $TBL (
      account_id INT    NOT NULL PRIMARY KEY,
      balance    BIGINT NOT NULL,
      debt       BIGINT NOT NULL,
      exp_balance BIGINT NOT NULL,   -- 기대값을 만들 때 함께 적어 둔다
      exp_debt    BIGINT NOT NULL,
      CONSTRAINT CK_${TBL}_nonneg CHECK (balance >= 0)
  );
  WITH n AS (SELECT TOP ($N) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
               FROM sys.all_objects a CROSS JOIN sys.all_objects b)
  INSERT INTO $TBL (account_id, balance, debt, exp_balance, exp_debt)
  SELECT i, 0,
         CASE WHEN i % 2 = 0 THEN 1000 ELSE 300 END,
         -- 획득 $GAIN 을 받으면 min(빚, 획득) 만큼 빚이 줄고 나머지가 잔액이 된다
         CASE WHEN (CASE WHEN i % 2 = 0 THEN 1000 ELSE 300 END) >= $GAIN
              THEN 0 ELSE $GAIN - (CASE WHEN i % 2 = 0 THEN 1000 ELSE 300 END) END,
         CASE WHEN (CASE WHEN i % 2 = 0 THEN 1000 ELSE 300 END) >= $GAIN
              THEN (CASE WHEN i % 2 = 0 THEN 1000 ELSE 300 END) - $GAIN ELSE 0 END
    FROM n;" || return 2
  QD "IF EXISTS (SELECT 1 FROM sys.triggers WHERE name='trg_offset_row') DROP TRIGGER trg_offset_row;
      IF EXISTS (SELECT 1 FROM sys.triggers WHERE name='trg_offset_set') DROP TRIGGER trg_offset_set;" >/dev/null
  local got; got=$(num "$(QD "SELECT COUNT(*) FROM $TBL")")
  [ "$got" = "$N" ] || { echo "중단: 적재가 ${got}행입니다(기대 $N)" >&2; return 2; }
}

# 검산. 계정별 기대값과 어긋난 수를 돌려준다.
# "빚합계,잔액합계,어긋난계정수"
verify(){
  num "$(QD "SET NOCOUNT ON;
    SELECT CAST(SUM(debt) AS varchar(20)) + ',' + CAST(SUM(balance) AS varchar(20)) + ','
         + CAST(SUM(CASE WHEN debt <> exp_debt OR balance <> exp_balance THEN 1 ELSE 0 END) AS varchar(12))
      FROM $TBL;")"
}

{
echo "# 실험 8. 상계 규칙을 어디에 둘 것인가"
echo
echo "  빚이 있는 계정 ${N}개에 각각 ${GAIN} 을 지급합니다. 지급 경로는 ${PATHS}개이고"
echo "  경로마다 계정을 나눠 **한 문장으로 여러 행을 갱신**합니다. 실제 지급이 그렇습니다."
echo
echo "  올바른 결과는 계정마다 min(빚, ${GAIN}) 만큼 빚이 줄고 나머지가 잔액이 되는 것입니다."
echo "  기대값을 적재할 때 함께 적어 두고 계정 단위로 대조합니다."
echo

: > "$OUT/offset-rule.csv"
echo "case,where,debt_sum,balance_sum,wrong_accounts,verdict" >> "$OUT/offset-rule.csv"
printf "  %-24s %-14s %-14s %-14s %s\n" "조건" "남은 빚" "잔액 합계" "어긋난 계정" "판정"

report(){ # $1=라벨 $2=규칙 위치
  local r; r=$(verify)
  IFS=, read -r d b w <<<"$r"
  local verdict="맞음"; [ "${w:-0}" != "0" ] && verdict="**${w}개 어긋남**"
  printf "  %-24s %-14s %-14s %-14s %s\n" "$1" "$d" "$b" "${w}개" "$verdict"
  echo "\"$1\",\"$2\",$d,$b,$w,\"$verdict\"" >> "$OUT/offset-rule.csv"
}

# ── A 앱 경로마다 ────────────────────────────────────────────────────────
# 경로 넷 중 셋은 규칙을 넣었고 하나(이벤트)는 빠뜨렸다. 실제로 흔한 모양이다.
# 나중에 추가된 경로가 기존 규칙을 모르고 잔액만 더한다.
setup || exit 2
# 기대값은 표가 만들어진 뒤에 읽는다. 앞에서 읽으면 Msg 208 이 그대로 값이 된다.
EXP=$(num "$(QD "SELECT CAST(SUM(exp_debt) AS varchar(20)) + ',' + CAST(SUM(exp_balance) AS varchar(20)) FROM $TBL")")
for p in 0 1 2; do
  QDX "SET NOCOUNT ON;
  UPDATE $TBL
     SET debt    = debt - CASE WHEN debt >= $GAIN THEN $GAIN ELSE debt END,
         balance = balance + $GAIN - CASE WHEN debt >= $GAIN THEN $GAIN ELSE debt END
   WHERE account_id % $PATHS = $p;" || exit 2
done
# 이벤트 경로. 규칙이 없다.
QDX "SET NOCOUNT ON;
UPDATE $TBL SET balance = balance + $GAIN WHERE account_id % $PATHS = 3;" || exit 2
report "A 앱 경로마다" "애플리케이션"

# ── B 트리거, 한 행 기준 ────────────────────────────────────────────────
setup || exit 2
QF "SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
CREATE TRIGGER trg_offset_row ON $TBL AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(balance) RETURN;
    -- **여기가 함정이다.** inserted 가 여러 행이면 변수에는 마지막 하나만 남는다.
    -- 오류도 경고도 없다. 나머지 행은 조용히 안 다뤄진다.
    DECLARE @acc INT, @gain BIGINT;
    SELECT @acc = i.account_id, @gain = i.balance - d.balance
      FROM inserted i JOIN deleted d ON d.account_id = i.account_id
     WHERE i.balance > d.balance;
    IF @gain IS NULL OR @gain <= 0 RETURN;
    UPDATE $TBL
       SET debt    = debt - CASE WHEN debt >= @gain THEN @gain ELSE debt END,
           balance = balance - CASE WHEN debt >= @gain THEN @gain ELSE debt END
     WHERE account_id = @acc AND debt > 0;
END
GO" >/dev/null
for p in 0 1 2 3; do
  QDX "SET NOCOUNT ON; UPDATE $TBL SET balance = balance + $GAIN WHERE account_id % $PATHS = $p;" || exit 2
done
report "B 트리거(행 단위)" "DB"
QD "DROP TRIGGER trg_offset_row;" >/dev/null

# ── C 트리거, 집합 기준 ─────────────────────────────────────────────────
setup || exit 2
QF "SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
CREATE TRIGGER trg_offset_set ON $TBL AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(balance) RETURN;
    -- 변수에 담지 않고 inserted/deleted 를 그대로 조인한다. 행이 몇 개든 같다.
    UPDATE t
       SET debt    = t.debt    - CASE WHEN t.debt >= g.gain THEN g.gain ELSE t.debt END,
           balance = t.balance - CASE WHEN t.debt >= g.gain THEN g.gain ELSE t.debt END
      FROM $TBL t
      JOIN (SELECT i.account_id, i.balance - d.balance AS gain
              FROM inserted i JOIN deleted d ON d.account_id = i.account_id
             WHERE i.balance > d.balance) g ON g.account_id = t.account_id
     WHERE t.debt > 0;
END
GO" >/dev/null
for p in 0 1 2 3; do
  QDX "SET NOCOUNT ON; UPDATE $TBL SET balance = balance + $GAIN WHERE account_id % $PATHS = $p;" || exit 2
done
report "C 트리거(집합)" "DB"
QD "DROP TRIGGER trg_offset_set;" >/dev/null

# ── D 프로시저 강제 ─────────────────────────────────────────────────────
# 규칙을 빠뜨릴 자리를 아예 없앤다. 표를 직접 못 고치게 하고 프로시저만 준다.
setup || exit 2
QF "SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
CREATE OR ALTER PROCEDURE usp_GrantCurrency
    @path INT, @gain BIGINT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @gain <= 0 THROW 50040, N'지급액은 양수여야 합니다', 1;
    UPDATE $TBL
       SET debt    = debt - CASE WHEN debt >= @gain THEN @gain ELSE debt END,
           balance = balance + @gain - CASE WHEN debt >= @gain THEN @gain ELSE debt END
     WHERE account_id % $PATHS = @path;
END
GO" >/dev/null

QD "IF SUSER_ID('app_svc') IS NULL CREATE LOGIN app_svc WITH PASSWORD = 'App_Passw0rd!', CHECK_POLICY = OFF;" >/dev/null
QDX "IF DATABASE_PRINCIPAL_ID('app_svc') IS NULL CREATE USER app_svc FOR LOGIN app_svc;
     GRANT SELECT ON $TBL TO app_svc;
     DENY UPDATE ON $TBL TO app_svc;
     GRANT EXECUTE ON usp_GrantCurrency TO app_svc;" || exit 2

AS_APP(){ docker exec "$CT" "$SQLCMD" -S localhost -U app_svc -P 'App_Passw0rd!' -C -h -1 -W -d "$DB" -Q "$1" 2>&1; }
DIRECT=$(AS_APP "UPDATE $TBL SET balance = balance + $GAIN WHERE account_id % $PATHS = 3;")
DMSG=$(echo "$DIRECT" | grep -oE '^(Msg|메시지) [0-9]+' | head -1)
for p in 0 1 2 3; do
  AS_APP "EXEC usp_GrantCurrency @path = $p, @gain = $GAIN;" >/dev/null
done
report "D 프로시저 강제" "DB"

QD "DROP TABLE IF EXISTS $TBL;" >/dev/null

echo
IFS=, read -r EXP_D EXP_B <<<"$EXP"
printf "  %-24s %-14s %s\n" "기대값" "${EXP_D:-?}" "${EXP_B:-?}"
echo
echo "  D 에서 앱 계정이 표를 직접 고치려고 하면 이렇게 막힙니다."
echo "    ${DMSG:-차단 메시지를 못 읽음}  $(echo "$DIRECT" | grep -iE 'UPDATE 권한|permission was denied|denied on object' | head -1 | sed 's/^ *//')"

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  실험 2가 \"경로 전부에 같은 규칙이 들어가야 한다\"고만 적어 둔 자리를 만들었습니다."
echo
echo "  **A 는 경로 하나가 빠뜨렸고 그 몫이 그대로 남았습니다.** 오류가 안 납니다."
echo "  잔액은 늘었고 빚도 그대로라 이용자는 아무 이상을 못 느낍니다. 회수가 덜 된 것을"
echo "  아무도 모르고, 나중에 총량 대사에서야 어긋난 숫자로 나타납니다."
echo
echo "  **B 가 이 실험에서 제일 위험합니다.** 규칙을 DB 한 곳으로 옮겼는데도 틀렸습니다."
echo "  트리거는 **문장마다 한 번** 돌고 inserted 에는 그 문장이 건드린 행이 전부 들어옵니다."
echo "  그것을 변수에 담으면 마지막 한 행만 남습니다. 오류도 경고도 없습니다."
echo "  한 행씩 지급하는 동안에는 멀쩡하다가 지급을 묶는 순간 틀리기 시작합니다."
echo
echo "  C 와 D 는 맞습니다. 차이는 **빠뜨릴 수 있는가**입니다."
echo "    C 규칙은 한 곳이지만 표를 직접 고치는 경로가 여전히 열려 있습니다"
echo "    D 직접 갱신을 막았으므로 규칙을 우회할 자리 자체가 없습니다"
echo
echo "  그래서 실험 2의 \"DEBT 의 진짜 비용은 경로마다 규칙을 넣는 것\"이라는 문장은"
echo "  **절반만 맞습니다.** 규칙을 DB 에 두면 경로 수와 무관해집니다. 진짜 비용은"
echo "  경로 수가 아니라 **그 규칙을 집합으로 짜야 한다는 것**이고, 그것을 놓치면"
echo "  앱에 흩어 놓은 것보다 더 조용히 틀립니다."
echo
echo "  운영으로 옮기면 이렇게 됩니다."
echo
echo "    상계 규칙은 DB 에 둔다. 경로가 늘어도 고칠 곳이 하나다"
echo "    트리거는 inserted·deleted 를 **조인**으로 다룬다. 변수에 담지 않는다"
echo "    가능하면 표를 직접 못 고치게 하고 프로시저만 연다"
echo "    빚이 0 이 될 때까지 총량 대사를 돌린다. 규칙이 새면 거기서 잡힌다"
} 2>&1 | tee "$OUT/exp8-offset-rule.txt"
