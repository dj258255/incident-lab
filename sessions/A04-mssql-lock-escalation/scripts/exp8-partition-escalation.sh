#!/usr/bin/env bash
# 실험 8. 파티션 테이블에서 AUTO 와 TABLE 이 갈린다.
#
# 실험 3은 LOCK_ESCALATION 을 AUTO 와 DISABLE 만 비교했다. TABLE 은 안 쟀는데,
# 파티션이 없는 표에서는 AUTO 와 TABLE 이 같게 동작해 비교할 것이 없기 때문이다.
#
# 파티션 테이블에서는 다르다. 문서에 따르면 AUTO 는 파티션 단위로 승격하고
# TABLE 은 테이블 전체로 승격한다. 게임 로그·재화 표는 파티션을 두는 경우가 많으므로
# 이 차이가 실제로 갈리는지 본다.
#
# 판정은 락의 모양으로 한다. 파티션 단위 승격이면 HoBT 락이, 테이블 승격이면
# OBJECT 락이 잡힌다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
PTBL=expedition_currency_p
ROWS=${ROWS:-200000}
UPD=${UPD:-20000}

wait_ready || exit 2
OPTLOCK=$(assert_env) || exit 2

{
echo "# 실험 8. 파티션 테이블에서 AUTO 와 TABLE"
echo "# optimized locking: ${OPTLOCK}"
echo
echo "  계정 ${ROWS}개를 4개 파티션으로 나눕니다. 갱신은 한 파티션 안의 ${UPD}행입니다."
echo "  승격이 나는 크기이고, 파티션 하나만 건드리는 크기입니다."
echo

QDX "SET NOCOUNT ON;
DROP TABLE IF EXISTS $PTBL;
IF EXISTS (SELECT 1 FROM sys.partition_schemes WHERE name='ps_acct') DROP PARTITION SCHEME ps_acct;
IF EXISTS (SELECT 1 FROM sys.partition_functions WHERE name='pf_acct') DROP PARTITION FUNCTION pf_acct;" || exit 2
QDX "CREATE PARTITION FUNCTION pf_acct (INT) AS RANGE RIGHT
       FOR VALUES ($(( ROWS/4 )), $(( ROWS/2 )), $(( ROWS*3/4 )));
     CREATE PARTITION SCHEME ps_acct AS PARTITION pf_acct ALL TO ([PRIMARY]);" || exit 2
QDX "SET NOCOUNT ON;
CREATE TABLE $PTBL (
    account_id    INT     NOT NULL,
    currency_type TINYINT NOT NULL,
    balance       BIGINT  NOT NULL
) ON ps_acct(account_id);
CREATE CLUSTERED INDEX CX_p ON $PTBL (account_id) ON ps_acct(account_id);
WITH n AS (SELECT TOP ($ROWS) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
             FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO $PTBL WITH (TABLOCK) (account_id, currency_type, balance)
SELECT i, i % 3, 100000 FROM n;
UPDATE STATISTICS $PTBL WITH FULLSCAN;" || exit 2

PN=$(num "$(QD "SELECT COUNT(*) FROM sys.partitions WHERE object_id=OBJECT_ID('$PTBL') AND index_id=1")")
echo "  파티션 ${PN}개 생성, ${ROWS}행 적재"
echo

: > "$OUT/partition-escalation.csv"
echo "mode,escalation_events,object_locks,hobt_locks,key_locks,verdict" >> "$OUT/partition-escalation.csv"
printf "  %-14s %-12s %-12s %-12s %-12s %s\n" "설정" "승격 이벤트" "OBJECT 락" "HOBT 락" "KEY 락" "판정"

run_mode(){
  local mode=$1
  local desc; desc=$(num "$(QD "ALTER TABLE $PTBL SET (LOCK_ESCALATION = $mode);
                                SELECT lock_escalation_desc FROM sys.tables WHERE name='$PTBL'")")
  [ "$desc" = "$mode" ] || { echo "  ${mode}: 설정을 못 바꿨습니다(${desc})"; return; }
  xe_reset
  local r
  r=$(num "$(QD "SET NOCOUNT ON;
    BEGIN TRAN;
    UPDATE TOP ($UPD) $PTBL SET balance = balance - 1 WHERE account_id <= $(( ROWS/4 ));
    SELECT CAST(SUM(CASE WHEN resource_type='OBJECT' THEN 1 ELSE 0 END) AS varchar(8))
         + ',' + CAST(SUM(CASE WHEN resource_type='HOBT' THEN 1 ELSE 0 END) AS varchar(8))
         + ',' + CAST(SUM(CASE WHEN resource_type='KEY'  THEN 1 ELSE 0 END) AS varchar(12))
      FROM sys.dm_tran_locks WHERE request_session_id = @@SPID;
    ROLLBACK;")")
  IFS=, read -r obj hobt key <<<"$r"
  local ev; ev=$(xe_count)
  local verdict
  if   [ "${hobt:-0}" -gt 0 ]; then verdict="파티션(HoBT) 단위 승격"
  elif [ "${key:-0}" -gt 1000 ]; then verdict="승격 안 함"
  else verdict="테이블 단위 승격"
  fi
  printf "  %-14s %-12s %-12s %-12s %-12s %s\n" "$mode" "${ev}건" "$obj" "$hobt" "$key" "$verdict"
  echo "$mode,$ev,$obj,$hobt,$key,\"$verdict\"" >> "$OUT/partition-escalation.csv"
}

run_mode TABLE
run_mode AUTO

QD "ALTER TABLE $PTBL SET (LOCK_ESCALATION = TABLE);" >/dev/null
echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  파티션 테이블에서 AUTO 는 파티션 단위로 승격합니다. 잡히는 것이 OBJECT 락이"
echo "  아니라 HoBT 락이고, 그 파티션 밖의 행은 안 막힙니다."
echo
echo "  TABLE 은 파티션이 있어도 테이블 전체를 잠급니다. 기본값이 TABLE 이므로"
echo "  **파티션을 나눠 두고도 기본값 그대로면 파티션의 값을 못 씁니다.**"
echo
echo "  다만 AUTO 가 공짜는 아닙니다. 파티션 단위 승격은 여러 파티션을 건드리는"
echo "  트랜잭션에서 파티션마다 락을 잡아 데드락 가능성을 올립니다. 문서도 그 점을"
echo "  경고합니다. 보정 배치가 한 파티션 안에서 끝나도록 짜는 것이 전제입니다."
echo
echo "  A24 실험 7에서 파티션이 조사 속도에는 도움이 안 됐는데, 여기서는 락 범위를"
echo "  좁히는 값이 있습니다. 파티션을 두는 이유가 하나 더 있는 셈입니다."
} 2>&1 | tee "$OUT/exp8-partition-escalation.txt"
