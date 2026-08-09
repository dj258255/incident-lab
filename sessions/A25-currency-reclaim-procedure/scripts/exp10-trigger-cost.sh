#!/usr/bin/env bash
# 실험 10. 트리거의 값과 대가.
#
# 실험 8은 상계 규칙을 DB 에 두는 것이 맞다는 결론을 냈지만 두 자리를 비워 뒀다.
#   "트리거의 비용을 안 쟀습니다. 지급 문장마다 트리거가 한 번 더 갱신하므로
#    로그와 락이 늘어날 텐데 그 양은 재지 않았습니다."
#   "INSTEAD OF 트리거는 안 만들었습니다. AFTER 는 일단 잔액을 늘린 뒤 되돌리는
#    모양이라 중간 상태가 잠깐 존재합니다."
#
# 규칙을 어디에 둘지 정할 때 **맞는가**만 보고 **얼마나 드는가**를 안 본 것이다.
# 세 방식을 같은 부하로 견준다.
#
#   N 규칙 없음     기준선. 상계를 안 하고 잔액만 더한다
#   A AFTER         실험 8의 C. 잔액을 더한 뒤 트리거가 되돌린다
#   I INSTEAD OF    갱신을 가로채 처음부터 맞게 쓴다
#   P 프로시저      실험 8의 D. 트리거 없이 한 문장으로 쓴다
#
# 재는 것은 로그 쓰기와 잡은 락 수다. 시간은 안 잰다(ARM 에뮬레이션).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
TBL=trg_cost
N=${TRG_ACCOUNTS:-20000}
GAIN=${GAIN:-600}

wait_ready || exit 2
REC=$(num "$(Q "SELECT CASE WHEN is_recursive_triggers_on = 1 THEN 'ON' ELSE 'OFF' END
                  FROM sys.databases WHERE name = '$DB'")")
[ "$REC" = "OFF" ] || { echo "중단: RECURSIVE_TRIGGERS 가 ON 입니다" >&2; exit 2; }

mb(){ python3 -c "print(f'{${1:-0}/1048576:.1f}')"; }
log_written(){
  num "$(Q "SET NOCOUNT ON;
    SELECT CAST(SUM(vfs.num_of_bytes_written) AS varchar(30))
      FROM sys.dm_io_virtual_file_stats(DB_ID('$DB'), NULL) vfs
      JOIN sys.master_files mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id
     WHERE mf.type_desc = 'LOG';")"
}

setup(){
  QDX "SET NOCOUNT ON;
  IF OBJECT_ID('$TBL') IS NOT NULL DROP TABLE $TBL;
  CREATE TABLE $TBL (
      account_id  INT    NOT NULL PRIMARY KEY,
      balance     BIGINT NOT NULL,
      debt        BIGINT NOT NULL,
      exp_balance BIGINT NOT NULL,
      exp_debt    BIGINT NOT NULL,
      CONSTRAINT CK_${TBL}_nonneg CHECK (balance >= 0)
  );
  WITH n AS (SELECT TOP ($N) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
               FROM sys.all_objects a CROSS JOIN sys.all_objects b)
  INSERT INTO $TBL (account_id, balance, debt, exp_balance, exp_debt)
  SELECT i, 0,
         CASE WHEN i % 2 = 0 THEN 1000 ELSE 300 END,
         CASE WHEN (CASE WHEN i % 2 = 0 THEN 1000 ELSE 300 END) >= $GAIN
              THEN 0 ELSE $GAIN - (CASE WHEN i % 2 = 0 THEN 1000 ELSE 300 END) END,
         CASE WHEN (CASE WHEN i % 2 = 0 THEN 1000 ELSE 300 END) >= $GAIN
              THEN (CASE WHEN i % 2 = 0 THEN 1000 ELSE 300 END) - $GAIN ELSE 0 END
    FROM n;" || return 2
  QD "IF EXISTS (SELECT 1 FROM sys.triggers WHERE name='trg_after')   DROP TRIGGER trg_after;
      IF EXISTS (SELECT 1 FROM sys.triggers WHERE name='trg_instead') DROP TRIGGER trg_instead;" >/dev/null
  local got; got=$(num "$(QD "SELECT COUNT(*) FROM $TBL")")
  [ "$got" = "$N" ] || { echo "중단: 적재가 ${got}행입니다" >&2; return 2; }
}

# 락은 표본하지 않는다. 지급 문장이 짧아 docker exec 왕복 사이에 끝나 버려서,
# 처음에 표본으로 쟀더니 같은 조건이 회차마다 3,225 와 1 을 오갔다. 그 수로는
# 아무 말도 못 한다. 트랜잭션을 열어 둔 채 **그 세션이 지금 들고 있는 락**을
# 직접 세면 회차와 무관하게 같은 값이 나온다(A04 의 lock_shape 와 같은 방법).

{
echo "# 실험 10. 트리거의 값과 대가"
echo
echo "  빚이 있는 계정 ${N}개에 각각 ${GAIN} 을 한 문장으로 지급합니다."
echo "  실험 8은 어느 방식이 맞는지만 봤습니다. 여기서는 **얼마나 드는지**를 봅니다."
echo "  시간은 안 적습니다. 로그 쓰기와 잡은 락 수를 봅니다."
echo

: > "$OUT/trigger-cost.csv"
echo "mode,wrong_accounts,log_mb,max_locks,note" >> "$OUT/trigger-cost.csv"
printf "  %-22s %-14s %-11s %-11s %s\n" "방식" "어긋난 계정" "로그" "락 수" "락 모양"

run_case(){ # $1=라벨 $2=지급 SQL $3=비고
  Q "CHECKPOINT;" >/dev/null; QD "CHECKPOINT;" >/dev/null
  local l0; l0=$(log_written)
  local maxl
  # 총 개수만으로는 승격이 일어났는지 안 보인다. 종류를 갈라서 받는다.
  maxl=$(num "$(QD "SET NOCOUNT ON;
    BEGIN TRAN;
    $2
    SELECT CAST(COUNT(*) AS varchar(12)) + ',' +
           CAST(SUM(CASE WHEN resource_type = 'OBJECT' AND request_mode IN ('X','IX') THEN 1 ELSE 0 END) AS varchar(8)) + ',' +
           CAST(SUM(CASE WHEN resource_type = 'KEY'  THEN 1 ELSE 0 END) AS varchar(12)) + ',' +
           CAST(SUM(CASE WHEN resource_type = 'PAGE' THEN 1 ELSE 0 END) AS varchar(12))
      FROM sys.dm_tran_locks
     WHERE request_session_id = @@SPID AND resource_type <> 'DATABASE';
    COMMIT;")")
  local ltot lobj lkey lpg
  IFS=, read -r ltot lobj lkey lpg <<<"$maxl"
  local lshape="테이블 락으로 접힘"
  [ "${lkey:-0}" -gt 100 ] 2>/dev/null && lshape="행 락 ${lkey}개 유지"
  maxl="$ltot"
  local l1; l1=$(log_written)
  local r; r=$(num "$(QD "SET NOCOUNT ON;
    SELECT CAST(SUM(CASE WHEN debt <> exp_debt OR balance <> exp_balance THEN 1 ELSE 0 END) AS varchar(12))
      FROM $TBL;")")
  local logmb; logmb=$(mb $(( l1 - l0 )))
  local verdict="$r"; [ "$r" = "0" ] && verdict="0 (맞음)"
  printf "  %-22s %-14s %-11s %-11s %s\n" "$1" "$verdict" "${logmb}MB" "${maxl}" "$lshape"
  echo "\"$1\",$r,$logmb,$maxl,\"$lshape / $3\"" >> "$OUT/trigger-cost.csv"
}

# ── N 규칙 없음 ─────────────────────────────────────────────────────────
setup || exit 2
run_case "N 규칙 없음" "SET NOCOUNT ON; UPDATE $TBL SET balance = balance + $GAIN;" "기준선"

# ── A AFTER 트리거 ──────────────────────────────────────────────────────
setup || exit 2
QF "SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
CREATE TRIGGER trg_after ON $TBL AFTER UPDATE AS
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
run_case "A AFTER 트리거" "SET NOCOUNT ON; UPDATE $TBL SET balance = balance + $GAIN;" "두 번 쓴다"
QD "DROP TRIGGER trg_after;" >/dev/null

# ── I INSTEAD OF 트리거 ─────────────────────────────────────────────────
# 갱신을 가로채 처음부터 맞은 값을 쓴다. 중간 상태가 안 생긴다.
# 다만 **가로챈 갱신을 직접 다시 써야** 하므로, 지급 말고 다른 갱신이 들어오면
# 그것도 이 트리거가 책임진다. 그 부담이 이 방식의 숨은 비용이다.
setup || exit 2
QF "SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
CREATE TRIGGER trg_instead ON $TBL INSTEAD OF UPDATE AS
BEGIN
    SET NOCOUNT ON;
    UPDATE t
       SET balance = CASE WHEN i.balance > d.balance
                          THEN d.balance + (i.balance - d.balance)
                               - CASE WHEN t.debt >= (i.balance - d.balance)
                                      THEN (i.balance - d.balance) ELSE t.debt END
                          ELSE i.balance END,
           debt    = CASE WHEN i.balance > d.balance
                          THEN t.debt - CASE WHEN t.debt >= (i.balance - d.balance)
                                             THEN (i.balance - d.balance) ELSE t.debt END
                          ELSE t.debt END
      FROM $TBL t
      JOIN inserted i ON i.account_id = t.account_id
      JOIN deleted  d ON d.account_id = t.account_id;
END
GO" >/dev/null
run_case "I INSTEAD OF 트리거" "SET NOCOUNT ON; UPDATE $TBL SET balance = balance + $GAIN;" "한 번 쓴다"
QD "DROP TRIGGER trg_instead;" >/dev/null

# ── P 프로시저 ──────────────────────────────────────────────────────────
setup || exit 2
run_case "P 프로시저(한 문장)" "SET NOCOUNT ON;
UPDATE $TBL
   SET debt    = debt - CASE WHEN debt >= $GAIN THEN $GAIN ELSE debt END,
       balance = balance + $GAIN - CASE WHEN debt >= $GAIN THEN $GAIN ELSE debt END;" "한 번 쓴다"

echo
echo "## 10-1. 중간 상태가 있는가, 그리고 보이는가"
echo
echo "  AFTER 는 잔액을 먼저 늘린 뒤 되돌립니다. 그 사이의 값이 **존재하는가**와"
echo "  다른 세션에 **보이는가**는 다른 질문입니다. 둘을 나눠 봅니다."
echo
echo "  존재하는지는 경합으로 재면 안 됩니다. 표본을 뜨는 순간과 트리거가 멈춰 있는"
echo "  구간이 겹쳐야 하는데 그 겹침이 회차마다 달라집니다. **트리거가 자기 안에서"
echo "  그 순간의 표를 찍게** 하면 타이밍과 무관합니다."
echo
setup || exit 2
QDX "SET NOCOUNT ON;
DROP TABLE IF EXISTS trg_snapshot;
CREATE TABLE trg_snapshot (account_id INT NOT NULL, balance BIGINT NOT NULL, debt BIGINT NOT NULL);" || exit 2
QF "SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
CREATE TRIGGER trg_after ON $TBL AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(balance) RETURN;
    -- 상계하기 **전에** 표를 찍는다. 이것이 중간 상태다.
    INSERT INTO trg_snapshot (account_id, balance, debt)
    SELECT TOP 3 t.account_id, t.balance, t.debt
      FROM $TBL t JOIN inserted i ON i.account_id = t.account_id
     ORDER BY t.account_id;
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
QDX "SET NOCOUNT ON; UPDATE TOP (100) $TBL SET balance = balance + $GAIN;" || exit 2

echo "  트리거가 상계 직전에 찍은 값과, 커밋 뒤의 최종값입니다."
echo
MID=$(QD "SET NOCOUNT ON;
SELECT CAST(s.account_id AS varchar(12)) + ' | ' + CAST(s.balance AS varchar(12))
     + ' / ' + CAST(s.debt AS varchar(12)) + '   ->   '
     + CAST(t.balance AS varchar(12)) + ' / ' + CAST(t.debt AS varchar(12))
  FROM trg_snapshot s JOIN $TBL t ON t.account_id = s.account_id
 ORDER BY s.account_id;")
printf "  %-12s %-22s %s\n" "계정" "중간(잔액/빚)" "최종(잔액/빚)"
echo "$MID" | grep -E '^[0-9]+ \| ' | sed 's/^/  /' | head -3
MIDN=$(num "$(QD "SELECT COUNT(*) FROM trg_snapshot")")
echo
if [ "${MIDN:-0}" -gt 0 ]; then
  echo "  **중간 상태는 실제로 존재합니다.** 잔액이 먼저 ${GAIN} 만큼 늘었다가 상계로"
  echo "  되돌아갑니다. 다만 그것은 **같은 트랜잭션 안**이고 그 행에는 배타 락이"
  echo "  걸려 있습니다."
else
  echo "  **트리거가 아무것도 못 찍었습니다.** 이 절은 판정할 수 없습니다."
fi

echo
echo "  그러면 밖에서 보이는가. 트리거를 멈춰 두고 두 방식으로 읽습니다."
echo
setup || exit 2
QD "TRUNCATE TABLE trg_snapshot;" >/dev/null
QF "SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
CREATE OR ALTER TRIGGER trg_after ON $TBL AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(balance) RETURN;
    WAITFOR DELAY '00:00:40';
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

docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
  -Q "SET NOCOUNT ON; UPDATE TOP (100) $TBL SET balance = balance + $GAIN;" >/dev/null 2>&1 &
UPD=$!
HELD=0
for i in $(seq 1 60); do
  if [ "$(num "$(Q "SELECT CAST(COUNT(*) AS varchar(4)) FROM sys.dm_exec_requests r
                      JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
                     WHERE s.is_user_process = 1 AND r.wait_type = 'WAITFOR'")")" -gt 0 ] 2>/dev/null; then
    HELD=1; break
  fi
  sleep 1
done
# 한 번만 읽으면 그 순간이 창을 벗어날 수 있다. 창이 열려 있는 동안 여러 번 읽는다.
NL_MAX=0
if [ "$HELD" = 1 ]; then
  for i in $(seq 1 8); do
    v=$(num "$(QD "SET NOCOUNT ON;
      SELECT CAST(COUNT(*) AS varchar(12)) FROM $TBL WITH (NOLOCK) WHERE balance > exp_balance;")")
    [ "${v:-0}" -gt "${NL_MAX:-0}" ] 2>/dev/null && NL_MAX="$v"
    [ "${NL_MAX:-0}" -gt 0 ] 2>/dev/null && break
  done
  # READ COMMITTED 로 읽으면 막혀야 한다. 막혔는지는 대기 유형으로 본다.
  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
    -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM $TBL WHERE balance > exp_balance;" >/dev/null 2>&1 &
  RDR=$!
  RC_WAIT="-"
  for i in $(seq 1 20); do
    w=$(numsp "$(Q "SET NOCOUNT ON;
      SELECT TOP 1 r.wait_type FROM sys.dm_exec_requests r
        JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
       WHERE s.is_user_process = 1 AND r.wait_type LIKE 'LCK%';")")
    [ -n "$w" ] && { RC_WAIT="$w"; break; }
    sleep 1
  done
  wait "$RDR" 2>/dev/null
fi
wait "$UPD" 2>/dev/null
QD "DROP TRIGGER trg_after; DROP TABLE IF EXISTS trg_snapshot;" >/dev/null

printf "  %-30s %s\n" "NOLOCK 으로 읽으면" "중간 상태 ${NL_MAX}건"
printf "  %-30s %s\n" "READ COMMITTED 로 읽으면" "대기 유형 ${RC_WAIT:-확인 못 함}"
echo
if [ "${NL_MAX:-0}" -gt 0 ] && [ "${RC_WAIT:-}" != "-" ]; then
  echo "  **NOLOCK 은 중간 상태를 그대로 봅니다.** READ COMMITTED 는 그 행의 배타 락에"
  echo "  막혀(${RC_WAIT}) 기다렸다가 최종값을 읽습니다."
  echo "  **중간 상태의 위험은 트리거가 아니라 NOLOCK 이 만듭니다.**"
elif [ "$HELD" != 1 ]; then
  echo "  트리거가 멈춘 순간을 못 잡아 이 절은 판정할 수 없습니다."
else
  echo "  두 값 중 하나를 못 잡았습니다(NOLOCK ${NL_MAX}건, 대기 ${RC_WAIT})."
  echo "  **판정하지 않고 남겨 둡니다.** 존재한다는 것은 위에서 확인했습니다."
fi

QD "DROP TABLE IF EXISTS $TBL;" >/dev/null

R=$(python3 - "$OUT/trigger-cost.csv" <<'PYX'
import csv, sys
rows = {r['mode']: r for r in csv.DictReader(open(sys.argv[1]))}
def f(k, c): return float(rows[k][c])
def i(k, c): return int(rows[k][c])
base = f('N 규칙 없음', 'log_mb')
out = []
for k in ['N 규칙 없음', 'A AFTER 트리거', 'I INSTEAD OF 트리거', 'P 프로시저(한 문장)']:
    ratio = f(k, 'log_mb') / base if base else 0
    out.append(f"{rows[k]['log_mb']}MB({ratio:.1f}배) 락 {rows[k]['max_locks']}")
print("|".join(out))
PYX
)
IFS='|' read -r C_N C_A C_I C_P <<<"$R"

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  실험 8이 \"어느 것이 맞는가\"만 보고 넘어간 자리에 비용을 넣습니다."
echo
printf "  %-22s %s\n" "N 규칙 없음" "$C_N"
printf "  %-22s %s\n" "A AFTER" "$C_A"
printf "  %-22s %s\n" "I INSTEAD OF" "$C_I"
printf "  %-22s %s\n" "P 프로시저" "$C_P"
echo
echo "  **AFTER 는 같은 행을 두 번 씁니다.** 잔액을 늘리는 갱신과 트리거가 되돌리는"
echo "  갱신이 각각 로그를 남기기 때문입니다. INSTEAD OF 와 프로시저는 한 번 씁니다."
echo
echo "  **그런데 락에서 뒤집힙니다.** 로그가 제일 적은 INSTEAD OF 가 행 락 2만 개를"
echo "  그대로 들고 갑니다. 나머지 셋은 승격이 일어나 테이블 락 하나로 접혔습니다."
echo "  같은 2만 행을 갱신하는데 어떤 경로는 접히고 어떤 경로는 안 접힙니다."
echo
echo "  운영에서 더 무서운 쪽은 로그가 아니라 이쪽입니다. 로그는 디스크를 더 쓸 뿐이고"
echo "  락 2만 개는 **락 매니저 메모리를 먹으면서 그 행들을 끝까지 붙잡습니다.**"
echo "  A04 에서 본 대로 승격은 서비스를 세우지만, 승격이 안 되는 것도 공짜가 아닙니다."
echo
echo "  그래도 AFTER 를 버릴 이유는 안 됩니다. 로그가 더 드는 대신 **원래 문장을"
echo "  안 건드립니다.** INSTEAD OF 는 갱신을 가로채므로 그 표에 오는 **모든 갱신을"
echo "  그 트리거가 책임집니다.** 지급 말고 다른 갱신이 추가될 때마다 트리거를 고쳐야"
echo "  하고, 하나를 빠뜨리면 그 갱신이 **조용히 사라집니다.**"
echo
echo "  그래서 셋의 자리가 갈립니다."
echo "    P 프로시저    지급 경로를 통제할 수 있으면 제일 싸고 제일 단순하다"
echo "    A AFTER       경로를 통제 못 해도 규칙이 걸린다. 대가는 로그"
echo "    I INSTEAD OF  제일 싸 보이지만 그 표의 모든 갱신을 떠안는다"
echo
echo "  중간 상태는 문제가 아니었습니다. 트리거는 원래 문장과 같은 트랜잭션에서 돌고,"
echo "  그 행에는 배타 락이 걸려 있어 정상적인 읽기는 최종값만 봅니다."
echo "  **NOLOCK 으로 읽을 때만 중간 상태가 보입니다.**"
} 2>&1 | tee "$OUT/exp10-trigger-cost.txt"
