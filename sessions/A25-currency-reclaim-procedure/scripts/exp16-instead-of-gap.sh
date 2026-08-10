#!/usr/bin/env bash
# 실험 16. INSTEAD OF 트리거가 다른 갱신을 떠안는다는 것.
#
# 실험 12는 INSTEAD OF 를 이렇게 적었다.
#   "갱신을 가로채므로 그 표에 오는 **모든 갱신을 그 트리거가 책임집니다.** 지급 말고
#    다른 갱신이 추가될 때마다 트리거를 고쳐야 하고, 하나를 빠뜨리면 그 갱신이
#    **조용히 사라집니다.**"
#
# **주장만 하고 안 보였다.** 지급만 다루는 트리거를 걸어 두고 다른 갱신을 던진다.
#
# 여기서 볼 것은 둘이다.
#   1 지급 말고 다른 갱신이 사라지는가        조용히 사라지는지가 핵심이다
#   2 AFTER 트리거는 같은 상황에서 어떤가     비교가 있어야 판단이 선다
#
# 그리고 마지막에 DB 가 클라이언트에 무엇을 보장할 수 있는지 본다. 음수 잔액을
# 읽는 앱 코드는 이 랩 밖이지만, **DB 가 그 앱에 무엇을 알려 줄 수 있는지**는
# 안에 있다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
TBL=io_gap
N=${IO_ROWS:-1000}

wait_ready || exit 2
REC=$(num "$(Q "SELECT CASE WHEN is_recursive_triggers_on = 1 THEN 'ON' ELSE 'OFF' END
                  FROM sys.databases WHERE name = '$DB'")")
[ "$REC" = "OFF" ] || { echo "중단: RECURSIVE_TRIGGERS 가 ON 입니다" >&2; exit 2; }

setup(){
  QDX "SET NOCOUNT ON;
  IF OBJECT_ID('$TBL') IS NOT NULL DROP TABLE $TBL;
  CREATE TABLE $TBL (
      account_id INT          NOT NULL PRIMARY KEY,
      balance    BIGINT       NOT NULL,
      debt       BIGINT       NOT NULL,
      grade      TINYINT      NOT NULL DEFAULT 1,   -- 지급과 무관한 컬럼
      note       VARCHAR(40)  NULL,                 -- 운영툴이 쓰는 컬럼
      CONSTRAINT CK_${TBL}_nonneg CHECK (balance >= 0)
  );
  WITH n AS (SELECT TOP ($N) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
               FROM sys.all_objects a CROSS JOIN sys.all_objects b)
  INSERT INTO $TBL (account_id, balance, debt, grade, note)
  SELECT i, 0, 1000, 1, NULL FROM n;" || return 2
  QD "IF EXISTS (SELECT 1 FROM sys.triggers WHERE name='trg_io')  DROP TRIGGER trg_io;
      IF EXISTS (SELECT 1 FROM sys.triggers WHERE name='trg_aft') DROP TRIGGER trg_aft;" >/dev/null
  local got; got=$(num "$(QD "SELECT COUNT(*) FROM $TBL")")
  [ "$got" = "$N" ] || { echo "중단: 적재가 ${got}행입니다" >&2; return 2; }
}

state(){ # "잔액합,빚합,등급2인행,note가찬행"
  num "$(QD "SET NOCOUNT ON;
    SELECT CAST(SUM(balance) AS varchar(20)) + ',' + CAST(SUM(debt) AS varchar(20)) + ','
         + CAST(SUM(CASE WHEN grade = 2 THEN 1 ELSE 0 END) AS varchar(12)) + ','
         + CAST(SUM(CASE WHEN note IS NOT NULL THEN 1 ELSE 0 END) AS varchar(12))
      FROM $TBL;")"
}

{
echo "# 실험 16. INSTEAD OF 가 떠안는 것"
echo
echo "  실험 12는 INSTEAD OF 가 \"그 표에 오는 모든 갱신을 책임진다\"고 적고"
echo "  **그것을 안 보였습니다.** 지급만 다루는 트리거를 걸고 다른 갱신을 던집니다."
echo
echo "  표에 지급과 무관한 컬럼을 둘 뒀습니다. 등급(grade)과 운영툴 메모(note)입니다."
echo "  실제 표에는 늘 이런 컬럼이 있고, 그것을 고치는 경로도 따로 있습니다."
echo

: > "$OUT/instead-of-gap.csv"
echo "trigger,change,balance_sum,debt_sum,grade2_rows,note_rows,verdict" >> "$OUT/instead-of-gap.csv"
printf "  %-16s %-24s %-12s %-12s %-10s %s\n" "트리거" "던진 갱신" "잔액합" "빚합" "등급2" "판정"

probe(){ # $1=트리거 라벨 $2=갱신 라벨 $3=SQL $4=기대(반영|사라짐)
  local before after
  before=$(state)
  QDX "$3" || true
  after=$(state)
  IFS=, read -r B_BAL B_DEBT B_G B_N <<<"$before"
  IFS=, read -r A_BAL A_DEBT A_G A_N <<<"$after"
  local changed="반영됨"
  [ "$before" = "$after" ] && changed="**사라짐**"
  local ok="  "; [ "$changed" = "$4" ] && ok="OK"
  printf "  %-16s %-24s %-12s %-12s %-10s %s\n" "$1" "$2" "$A_BAL" "$A_DEBT" "$A_G" "$changed"
  echo "\"$1\",\"$2\",$A_BAL,$A_DEBT,$A_G,$A_N,\"$changed\"" >> "$OUT/instead-of-gap.csv"
}

echo "### 16-1. INSTEAD OF 를 걸고 여러 갱신을 던진다"
echo
setup || exit 2
QF "SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
-- 지급만 생각하고 짠 트리거다. balance 가 늘어난 경우만 다룬다.
CREATE TRIGGER trg_io ON $TBL INSTEAD OF UPDATE AS
BEGIN
    SET NOCOUNT ON;
    UPDATE t
       SET balance = t.balance + (i.balance - d.balance)
                   - CASE WHEN t.debt >= (i.balance - d.balance)
                          THEN (i.balance - d.balance) ELSE t.debt END,
           debt    = t.debt - CASE WHEN t.debt >= (i.balance - d.balance)
                                   THEN (i.balance - d.balance) ELSE t.debt END
      FROM $TBL t
      JOIN inserted i ON i.account_id = t.account_id
      JOIN deleted  d ON d.account_id = t.account_id
     WHERE i.balance > d.balance;
END
GO" >/dev/null

probe "INSTEAD OF" "지급 (balance +600)" \
  "SET NOCOUNT ON; UPDATE $TBL SET balance = balance + 600;" "반영됨"
probe "INSTEAD OF" "등급 변경 (grade=2)" \
  "SET NOCOUNT ON; UPDATE $TBL SET grade = 2;" "**사라짐**"
probe "INSTEAD OF" "운영툴 메모 (note)" \
  "SET NOCOUNT ON; UPDATE $TBL SET note = 'checked';" "**사라짐**"
probe "INSTEAD OF" "빚 직접 조정 (debt -100)" \
  "SET NOCOUNT ON; UPDATE $TBL SET debt = CASE WHEN debt >= 100 THEN debt - 100 ELSE 0 END;" "**사라짐**"
QD "DROP TRIGGER trg_io;" >/dev/null

echo
echo "  **오류가 하나도 안 났습니다.** 갱신이 성공했다고 돌려주고 아무 일도 안 일어납니다."
echo "  트리거가 다루는 조건(balance 가 늘어난 행)에 안 걸리면 그 갱신은 통째로 버려집니다."
echo "  등급을 바꾼 운영툴도, 메모를 남긴 사람도 성공했다고 알고 넘어갑니다."
echo

echo "### 16-2. 같은 갱신을 AFTER 트리거에 던지면"
echo
setup || exit 2
QF "SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
CREATE TRIGGER trg_aft ON $TBL AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(balance) RETURN;
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

probe "AFTER" "지급 (balance +600)" \
  "SET NOCOUNT ON; UPDATE $TBL SET balance = balance + 600;" "반영됨"
probe "AFTER" "등급 변경 (grade=2)" \
  "SET NOCOUNT ON; UPDATE $TBL SET grade = 2;" "반영됨"
probe "AFTER" "운영툴 메모 (note)" \
  "SET NOCOUNT ON; UPDATE $TBL SET note = 'checked';" "반영됨"
probe "AFTER" "빚 직접 조정 (debt -100)" \
  "SET NOCOUNT ON; UPDATE $TBL SET debt = CASE WHEN debt >= 100 THEN debt - 100 ELSE 0 END;" "반영됨"
QD "DROP TRIGGER trg_aft;" >/dev/null

echo
echo "  **AFTER 는 원래 갱신을 안 건드립니다.** 자기가 볼 것만 보고(UPDATE(balance))"
echo "  아니면 물러납니다. 다른 경로가 추가돼도 트리거를 안 고쳐도 됩니다."
echo

echo "### 16-3. DB 가 클라이언트에 무엇을 보장할 수 있는가"
echo
echo "  음수 잔액을 읽는 **앱 코드**는 이 랩 밖입니다. 다만 DB 가 그 앱에 무엇을"
echo "  알려 줄 수 있는지는 안에 있습니다. 제약은 **읽을 수 있는 메타데이터**입니다."
echo
QDX "SET NOCOUNT ON;
DROP TABLE IF EXISTS guard_with;
DROP TABLE IF EXISTS guard_without;
CREATE TABLE guard_with    (account_id INT PRIMARY KEY, balance BIGINT NOT NULL
                            CONSTRAINT CK_guard CHECK (balance >= 0));
CREATE TABLE guard_without (account_id INT PRIMARY KEY, balance BIGINT NOT NULL);" || exit 2
printf "  %-22s %-16s %s\n" "표" "CHECK 제약" "클라이언트가 알 수 있는 것"
for T in guard_with guard_without; do
  CK=$(num "$(QD "SET NOCOUNT ON;
    SELECT CAST(COUNT(*) AS varchar(4)) FROM sys.check_constraints
     WHERE parent_object_id = OBJECT_ID('$T');")")
  DEF=$(numsp "$(QD "SET NOCOUNT ON;
    SELECT TOP 1 definition FROM sys.check_constraints
     WHERE parent_object_id = OBJECT_ID('$T');")")
  if [ "${CK:-0}" -gt 0 ]; then
    printf "  %-22s %-16s %s\n" "$T" "있음" "$DEF"
  else
    printf "  %-22s %-16s %s\n" "$T" "없음" "**음수가 올 수 있다는 것만 안다**"
  fi
  echo "\"$T\",\"CHECK\",0,0,0,0,\"${CK:-0}개 / ${DEF:-없음}\"" >> "$OUT/instead-of-gap.csv"
done
QD "DROP TABLE IF EXISTS guard_with; DROP TABLE IF EXISTS guard_without;" >/dev/null
echo
echo "  **제약이 있으면 그 사실이 카탈로그에 남습니다.** ORM 과 코드 생성기, 스키마"
echo "  문서화 도구가 전부 이것을 읽습니다. 제약을 빼면 클라이언트 쪽은 \"음수가 올 수"
echo "  있다\"만 알게 되고, 그것을 어떻게 다룰지는 각 코드가 알아서 정합니다."
echo "  **그 순간부터 통일된 규칙이 없어집니다.**"
echo
echo "  그래서 \"클라이언트가 음수에 어떻게 반응하는가\"는 DB 밖이지만"
echo "  **\"클라이언트가 음수를 예상해야 하는가\"는 DB 가 정합니다.**"

QD "DROP TABLE IF EXISTS $TBL;" >/dev/null

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  실험 12가 주장만 하고 안 보인 것을 보였습니다."
echo
echo "  **INSTEAD OF 는 지급이 아닌 갱신 셋을 통째로 버렸습니다.** 오류도 경고도 없이"
echo "  성공했다고 돌려줍니다. 등급을 바꾼 운영툴도, 메모를 남긴 사람도 그것이"
echo "  반영된 줄 압니다. 표에 컬럼이 늘거나 갱신 경로가 추가될 때마다 트리거를"
echo "  같이 고쳐야 하고, **안 고치면 그 경로가 조용히 죽습니다.**"
echo
echo "  AFTER 는 자기가 볼 것만 보고 아니면 물러납니다. 로그를 두 배 쓰는 대신"
echo "  **원래 갱신을 안 건드립니다.** 실험 12에서 INSTEAD OF 가 로그는 싸고 락은"
echo "  비쌌는데, 여기서 세 번째 대가가 나왔습니다."
echo
echo "  세 가지를 놓고 보면 순서가 정해집니다."
echo "    프로시저 강제  지급 경로를 통제할 수 있으면 이것. 제일 싸고 단순하다"
echo "    AFTER 트리거   경로를 통제 못 하면 이것. 대가는 로그 2배"
echo "    INSTEAD OF     권하지 않는다. 락이 안 접히고 다른 갱신을 떠안는다"
} 2>&1 | tee "$OUT/exp16-instead-of-gap.txt"
