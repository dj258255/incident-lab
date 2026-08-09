#!/usr/bin/env bash
# 실험 11. 파티션의 값어치는 조사가 아니라 보존 정리에 있다.
#
# 실험 8은 파티셔닝이 조사 쿼리를 빠르게 하지 않았다는 것을 보이고 정리에 이렇게 적었다.
#   "그러면 파티션은 왜 두는가. 조사 속도가 아니라 다른 것 때문입니다.
#    보존 정리를 DELETE 가 아니라 파티션 스위치로 한다"
#
# **그렇게 적어 놓고 스위치를 해 보지 않았다.** 못 한 것에도 남겼다.
#   "파티션 스위치로 보존 정리하는 것을 재지 않았습니다. 조사 속도만 봤고,
#    파티션의 실제 값이 있는 쪽은 안 봤습니다."
#
# 재화 원장은 계속 쌓이므로 오래된 것을 주기적으로 버려야 한다. 두 방법을 견준다.
#   A DELETE   행마다 로그를 쓰고 락을 잡는다. 배치로 쪼개도 총량은 그대로다
#   B SWITCH   메타데이터만 바꾼다. 행을 안 건드린다
#
# 시간은 안 잰다(ARM 에뮬레이션). 로그 쓰기와 락 개수를 본다. 둘 다 하드웨어와
# 무관하고, 운영에서 보존 정리가 서비스를 세우는 이유도 그 둘이다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

wait_ready || exit 2
[ "$(num "$(QD "SELECT CASE WHEN OBJECT_ID('currency_ledger_p') IS NULL THEN 'NO' ELSE 'YES' END")")" = "YES" ] \
  || { echo "중단: currency_ledger_p 가 없습니다. 실험 8을 먼저 돌립니다" >&2; exit 2; }

mb(){ python3 -c "print(f'{${1:-0}/1048576:.1f}')"; }
log_written(){
  num "$(Q "SET NOCOUNT ON;
    SELECT CAST(SUM(vfs.num_of_bytes_written) AS varchar(30))
      FROM sys.dm_io_virtual_file_stats(DB_ID('$DB'), NULL) vfs
      JOIN sys.master_files mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id
     WHERE mf.type_desc = 'LOG';")"
}

# 가장 오래된 파티션을 고른다. 손으로 경계를 적지 않는다.
OLDEST=$(num "$(QD "SET NOCOUNT ON;
SELECT TOP 1 CAST(p.partition_number AS varchar(6))
  FROM sys.partitions p
 WHERE p.object_id = OBJECT_ID('currency_ledger_p') AND p.index_id = 1 AND p.rows > 0
 ORDER BY p.partition_number;")")
OLD_ROWS=$(num "$(QD "SET NOCOUNT ON;
SELECT CAST(p.rows AS varchar(20)) FROM sys.partitions p
 WHERE p.object_id = OBJECT_ID('currency_ledger_p') AND p.index_id = 1
   AND p.partition_number = $OLDEST;")")
BOUND=$(numsp "$(QD "SET NOCOUNT ON;
SELECT CONVERT(varchar(23), CAST(prv.value AS DATETIME2(3)), 121)
  FROM sys.partition_range_values prv
  JOIN sys.partition_functions pf ON pf.function_id = prv.function_id
 WHERE pf.name = 'pf_ledger' AND prv.boundary_id = $OLDEST;")")
[ "${OLD_ROWS:-0}" -gt 0 ] || { echo "중단: 비울 파티션을 못 찾았습니다" >&2; exit 2; }

{
echo "# 실험 11. 보존 정리, DELETE 와 파티션 스위치"
echo
echo "  파티션 표(currency_ledger_p)의 가장 오래된 파티션 ${OLDEST}번을 버립니다."
echo "  ${OLD_ROWS}행이고 경계는 ${BOUND} 입니다."
echo
echo "  시간은 안 적습니다. **로그 쓰기와 락 개수**를 봅니다. 보존 정리가 서비스를"
echo "  세우는 이유가 그 둘이고, 둘 다 하드웨어와 무관합니다."
echo

: > "$OUT/partition-switch.csv"
echo "method,rows_removed,log_mb,max_locks,lock_shape,note" >> "$OUT/partition-switch.csv"
printf "  %-24s %-12s %-13s %-13s %s\n" "방법" "지운 행" "로그 쓰기" "최대 락 수" "락 모양"

# 지우는 동안의 락을 표본한다. 끝난 뒤에 재면 이미 놓은 뒤다.
lock_sample_start(){
  rm -f "$OUT/.lkstop"; : > "$OUT/.locks"
  ( while [ ! -f "$OUT/.lkstop" ]; do
      docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
        -Q "SET NOCOUNT ON;
            SELECT CAST(COUNT(*) AS varchar(12)) + ' '
                 + ISNULL(MAX(CASE WHEN l.resource_type = 'OBJECT' THEN l.request_mode END), '-')
              FROM sys.dm_tran_locks l
              JOIN sys.dm_exec_sessions s ON s.session_id = l.request_session_id
             WHERE s.is_user_process = 1 AND l.resource_type <> 'DATABASE';" 2>/dev/null \
        | grep -E '^[0-9]+ ' >> "$OUT/.locks"
    done ) &
  LK_PID=$!
}
lock_sample_stop(){ touch "$OUT/.lkstop"; wait "$LK_PID" 2>/dev/null; rm -f "$OUT/.lkstop"; }

run_case(){ # $1=라벨 $2=SQL $3=비고
  Q "CHECKPOINT;" >/dev/null; QD "CHECKPOINT;" >/dev/null
  local before_rows l0 l1 after_rows
  before_rows=$(num "$(QD "SELECT COUNT(*) FROM currency_ledger_p")")
  l0=$(log_written)
  lock_sample_start
  local out; out=$(QD "$2")
  lock_sample_stop
  l1=$(log_written)
  after_rows=$(num "$(QD "SELECT COUNT(*) FROM currency_ledger_p")")

  local removed=$(( before_rows - after_rows ))
  local logmb; logmb=$(mb $(( l1 - l0 )))
  local maxl shape
  maxl=$(awk '{if($1>m)m=$1} END{print m+0}' "$OUT/.locks")
  shape=$(awk '{print $2}' "$OUT/.locks" | sort -u | grep -v '^-$' | tr '\n' ' ' | sed 's/ $//')
  shape=${shape:-테이블 락 없음}
  if echo "$out" | grep -qE '^(Msg|메시지) [0-9]+'; then
    shape="**실패** $(echo "$out" | grep -oE '^(Msg|메시지) [0-9]+' | head -1)"
  fi
  printf "  %-24s %-12s %-13s %-13s %s\n" "$1" "${removed}행" "${logmb}MB" "$maxl" "$shape"
  echo "\"$1\",$removed,$logmb,$maxl,\"$shape\",\"$3\"" >> "$OUT/partition-switch.csv"
}

# ── A DELETE ────────────────────────────────────────────────────────────
# 한 방에 지우면 락 승격이 나고 로그가 통째로 쌓인다(A04). 실무 절차대로 쪼갠다.
run_case "A DELETE, 4000행씩" "
SET NOCOUNT ON;
DECLARE @n INT = 1;
WHILE @n > 0
BEGIN
    DELETE TOP (4000) FROM currency_ledger_p WHERE created_at < '$BOUND';
    SET @n = @@ROWCOUNT;
END" "배치 분할"

# 지운 것을 되돌린다. 다음 조건이 같은 상태에서 시작해야 한다.
QDX "SET NOCOUNT ON;
INSERT INTO currency_ledger_p WITH (TABLOCK) (ledger_id, account_id, delta, reason, ref_id, created_at)
SELECT ledger_id, account_id, delta, reason, ref_id, created_at
  FROM currency_ledger WHERE created_at < '$BOUND';" || exit 2
QD "UPDATE STATISTICS currency_ledger_p WITH FULLSCAN;" >/dev/null
RESTORED=$(num "$(QD "SELECT CAST(p.rows AS varchar(20)) FROM sys.partitions p
 WHERE p.object_id = OBJECT_ID('currency_ledger_p') AND p.index_id = 1
   AND p.partition_number = $OLDEST;")")
[ "$RESTORED" = "$OLD_ROWS" ] || { echo "중단: 되돌린 파티션이 ${RESTORED}행입니다(기대 ${OLD_ROWS})"; exit 2; }

# ── B SWITCH ────────────────────────────────────────────────────────────
# 받을 표는 **같은 파일 그룹에 같은 구조**여야 한다. 클러스터드 인덱스도 같아야 하고
# 경계 밖의 행이 들어오지 못하도록 CHECK 제약이 필요하다.
# 파티션 ${OLDEST} 번의 **아래 경계**도 읽는다. 나갈 때는 CHECK 가 필요 없지만
# 되돌려 넣을 때는 그 표의 모든 행이 그 파티션 범위 안에 있음을 제약으로 증명해야 한다.
# 처음에 위쪽 경계만 걸었다가 되돌리는 스위치가 Msg 4972 로 거부됐다.
LOW=$(numsp "$(QD "SET NOCOUNT ON;
SELECT ISNULL(CONVERT(varchar(23), CAST(prv.value AS DATETIME2(3)), 121), '')
  FROM sys.partition_range_values prv
  JOIN sys.partition_functions pf ON pf.function_id = prv.function_id
 WHERE pf.name = 'pf_ledger' AND prv.boundary_id = $(( OLDEST - 1 ));")")
LOWCK=""
[ -n "$LOW" ] && LOWCK="created_at >= '$LOW' AND "

QDX "SET NOCOUNT ON;
DROP TABLE IF EXISTS ledger_archive;
CREATE TABLE ledger_archive (
    ledger_id  BIGINT       NOT NULL,
    account_id INT          NOT NULL,
    delta      BIGINT       NOT NULL,
    reason     TINYINT      NOT NULL,
    ref_id     BIGINT       NULL,
    created_at DATETIME2(3) NOT NULL,
    CONSTRAINT CK_archive_range CHECK (${LOWCK}created_at < '$BOUND')
) ON [PRIMARY];
CREATE CLUSTERED INDEX CX_archive ON ledger_archive (created_at, ledger_id) ON [PRIMARY];" || exit 2

run_case "B SWITCH" "
ALTER TABLE currency_ledger_p SWITCH PARTITION $OLDEST TO ledger_archive;" "메타데이터"

ARCH=$(num "$(QD "SELECT COUNT(*) FROM ledger_archive")")
echo
printf "  %-24s %s\n" "받은 표에 들어온 행" "${ARCH}행"
echo

echo "## 11-1. 되돌리는 스위치는 조건이 하나 더 붙는다"
echo
echo "  받은 표를 파티션으로 도로 밀어 넣습니다. 나갈 때 통과한 표가 들어올 때도"
echo "  통과하는지 봅니다."
echo
BACK=$(QD "ALTER TABLE ledger_archive SWITCH TO currency_ledger_p PARTITION $OLDEST;")
BACK_MSG=$(echo "$BACK" | grep -oE '^(Msg|메시지) [0-9]+' | head -1)
if [ -n "$BACK_MSG" ]; then
  echo "  되돌리기 거부: $BACK_MSG"
  echo "$BACK" | grep -viE '^(Msg|메시지)|^$' | head -1 | sed 's/^ */    /' | cut -c1-90
  echo "\"되돌리는 스위치\",\"-\",\"-\",\"-\",\"$BACK_MSG\",\"거부\"" >> "$OUT/partition-switch.csv"
else
  echo "  되돌리기 성공. 파티션 ${OLDEST}번이 원래대로입니다."
  echo "\"되돌리는 스위치\",\"-\",\"-\",\"-\",\"됨\",\"양쪽 경계 CHECK\"" >> "$OUT/partition-switch.csv"
fi
# 되돌리기가 실패한 채로 표를 지우면 행이 사라진다. 확인하고 지운다.
LEFT=$(num "$(QD "SELECT COUNT(*) FROM ledger_archive")")
if [ "${LEFT:-0}" != "0" ]; then
  echo "  받은 표에 ${LEFT}행이 남아 있어 원장에서 다시 채웁니다."
  QDX "SET NOCOUNT ON;
  DELETE FROM currency_ledger_p WHERE created_at < '$BOUND';
  INSERT INTO currency_ledger_p WITH (TABLOCK) (ledger_id, account_id, delta, reason, ref_id, created_at)
  SELECT ledger_id, account_id, delta, reason, ref_id, created_at
    FROM currency_ledger WHERE created_at < '$BOUND';" || exit 2
fi
QD "DROP TABLE IF EXISTS ledger_archive;" >/dev/null
FINAL=$(num "$(QD "SELECT CAST(p.rows AS varchar(20)) FROM sys.partitions p
 WHERE p.object_id = OBJECT_ID('currency_ledger_p') AND p.index_id = 1
   AND p.partition_number = $OLDEST;")")
printf "  %-30s %s\n" "정리 후 파티션 ${OLDEST}번" "${FINAL}행 (시작 ${OLD_ROWS}행)"
[ "$FINAL" = "$OLD_ROWS" ] || { echo "중단: 상태를 못 되돌렸습니다" >&2; exit 2; }
echo
rm -f "$OUT/.locks"

echo "## 11-2. 나가는 스위치가 거부되는 조건"
echo
echo "  스위치는 조건이 까다롭습니다. 하나라도 어긋나면 거부됩니다."
echo
: > "$OUT/.sw"
sw_probe(){ # $1=라벨 $2=받을 표 DDL
  QD "DROP TABLE IF EXISTS sw_target;" >/dev/null
  QD "$2" >/dev/null 2>&1
  local out; out=$(QD "ALTER TABLE currency_ledger_p SWITCH PARTITION $OLDEST TO sw_target;")
  local msg; msg=$(echo "$out" | grep -oE '^(Msg|메시지) [0-9]+' | head -1)
  local why; why=$(echo "$out" | grep -viE '^(Msg|메시지)|^$' | head -1 | sed 's/^ *//' | cut -c1-72)
  if [ -z "$msg" ]; then
    printf "  %-30s %s\n" "$1" "됨"
    QD "ALTER TABLE sw_target SWITCH TO currency_ledger_p PARTITION $OLDEST;" >/dev/null 2>&1
  else
    printf "  %-30s %s\n" "$1" "$msg"
    [ -n "$why" ] && printf "  %-30s %s\n" "" "$why"
  fi
  echo "\"$1\",\"-\",\"-\",\"-\",\"${msg:-됨}\",\"$why\"" >> "$OUT/partition-switch.csv"
  QD "DROP TABLE IF EXISTS sw_target;" >/dev/null
}

sw_probe "CHECK 제약이 없으면" "
CREATE TABLE sw_target (ledger_id BIGINT NOT NULL, account_id INT NOT NULL,
  delta BIGINT NOT NULL, reason TINYINT NOT NULL, ref_id BIGINT NULL,
  created_at DATETIME2(3) NOT NULL) ON [PRIMARY];
CREATE CLUSTERED INDEX CX_sw ON sw_target (created_at, ledger_id) ON [PRIMARY];"

sw_probe "클러스터드 인덱스가 다르면" "
CREATE TABLE sw_target (ledger_id BIGINT NOT NULL, account_id INT NOT NULL,
  delta BIGINT NOT NULL, reason TINYINT NOT NULL, ref_id BIGINT NULL,
  created_at DATETIME2(3) NOT NULL,
  CONSTRAINT CK_sw CHECK (created_at < '$BOUND')) ON [PRIMARY];
CREATE CLUSTERED INDEX CX_sw ON sw_target (ledger_id) ON [PRIMARY];"

sw_probe "컬럼이 하나 더 있으면" "
CREATE TABLE sw_target (ledger_id BIGINT NOT NULL, account_id INT NOT NULL,
  delta BIGINT NOT NULL, reason TINYINT NOT NULL, ref_id BIGINT NULL,
  created_at DATETIME2(3) NOT NULL, extra INT NULL,
  CONSTRAINT CK_sw CHECK (created_at < '$BOUND')) ON [PRIMARY];
CREATE CLUSTERED INDEX CX_sw ON sw_target (created_at, ledger_id) ON [PRIMARY];"

sw_probe "구조가 전부 같으면" "
CREATE TABLE sw_target (ledger_id BIGINT NOT NULL, account_id INT NOT NULL,
  delta BIGINT NOT NULL, reason TINYINT NOT NULL, ref_id BIGINT NULL,
  created_at DATETIME2(3) NOT NULL,
  CONSTRAINT CK_sw CHECK (created_at < '$BOUND')) ON [PRIMARY];
CREATE CLUSTERED INDEX CX_sw ON sw_target (created_at, ledger_id) ON [PRIMARY];"

# 결론을 손으로 안 적는다. 측정값에서 뽑는다.
R=$(python3 - "$OUT/partition-switch.csv" <<'PY'
import csv, sys
rows = {r['method']: r for r in csv.DictReader(open(sys.argv[1])) if r['rows_removed'] not in ('-','')}
a = rows.get('A DELETE, 4000행씩'); b = rows.get('B SWITCH')
def f(r, k): return float(r[k]) if r else 0.0
def i(r, k): return int(r[k]) if r else 0
ratio = f(a,'log_mb') / f(b,'log_mb') if b and f(b,'log_mb') > 0 else None
print("|".join([a['log_mb'], b['log_mb'], a['max_locks'], b['max_locks'],
                (f"{ratio:.0f}" if ratio else "잴 수 없을 만큼 작음")]))
PY
)
IFS='|' read -r A_LOG B_LOG A_LK B_LK RATIO <<<"$R"

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  실험 8이 \"파티션의 값은 조사가 아니라 보존 정리에 있다\"고 적고 안 잰 것을"
echo "  여기서 쟀습니다."
echo
printf "  %-30s %s\n" "로그 쓰기" "DELETE ${A_LOG}MB / SWITCH ${B_LOG}MB"
printf "  %-30s %s\n" "동시에 잡은 최대 락 수" "DELETE ${A_LK} / SWITCH ${B_LK}"
echo
echo "  **같은 행을 없애는데 로그가 자릿수로 다릅니다.** DELETE 는 행마다 되돌릴 수"
echo "  있게 로그를 남기고, SWITCH 는 **행을 하나도 안 건드립니다.** 파티션이 어느"
echo "  표에 속하는지만 카탈로그에서 바꿉니다."
echo
echo "  운영에서 이 차이가 나타나는 자리는 셋입니다."
echo "    로그가 안 불어 로그 백업과 복제가 안 밀린다"
echo "    락을 안 잡아 그 사이 조회와 지급이 안 막힌다"
echo "    되돌리기 쉽다. 받은 표를 다시 스위치해 넣으면 원래대로다"
echo
echo "  대신 조건이 까다롭고, **나갈 때와 들어올 때가 다릅니다.**"
echo
echo "    나갈 때  받을 표가 구조가 같고 같은 파일 그룹에 있고 비어 있으면 된다."
echo "             **CHECK 제약은 필요 없다.** 11-2 에서 없이도 통과했다"
echo "    들어올 때 그 표의 모든 행이 그 파티션 범위 안에 있음을 **제약으로 증명**해야"
echo "             한다. 위쪽 경계만 걸었다가 Msg 4972 로 거부됐고 아래 경계까지"
echo "             넣고서야 들어갔다"
echo
echo "  이 비대칭이 운영에서 걸리는 자리입니다. 보존 정리는 나가는 쪽이라 쉽게 되는데,"
echo "  **잘못 뗀 것을 되돌리려는 순간 조건이 하나 더 붙습니다.** 급할 때 그 제약을"
echo "  만들려면 표 전체를 검증해야 하므로 시간이 걸립니다. 받을 표는 사고 중이 아니라"
echo "  **평소에 양쪽 경계 CHECK 까지 갖춰 만들어 두는 것**입니다."
echo
echo "  그래서 실험 8과 이 실험을 합치면 파티션의 자리가 정해집니다."
echo "    조사를 빠르게 하려고 파티션을 두는 것은 근거가 약하다(실험 8)"
echo "    보존 정리를 위해 두는 것은 근거가 분명하다(이 실험)"
echo "    조사 속도는 클러스터드 키를 시간 순으로 잡는 것으로 얻는다(실험 8)"
} 2>&1 | tee "$OUT/exp11-partition-switch.txt"
