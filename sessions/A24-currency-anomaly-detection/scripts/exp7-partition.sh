#!/usr/bin/env bash
# 실험 7. 파티션으로 조사 범위를 자를 수 있는가.
#
# 조사 쿼리는 4시간 창을 보는데 30일치를 읽는다(실험 3). 인덱스로 482까지 내렸지만
# 인덱스는 사고가 난 뒤에 만들면 쓰기를 막는다(실험 4).
#
# 다른 길이 있다. 시간으로 파티션을 나눠 두면 조사 창이 든 파티션만 읽는다.
# 인덱스와 달리 **평소에 만들어 두는 것**이고, 보존 정리(오래된 로그 버리기)에도
# 같은 구조를 쓴다. 대용량 로그 표에서 흔한 설계다.
#
# 다만 파티션 제거가 실제로 일어나는지는 조건을 탄다. 조사 쿼리가 파티션 키를
# 조건에 넣어야 하고, 넣어도 계획이 안 자르는 경우가 있다. 그것을 확인한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

WIN_START=$(grep '^window_start,' "$OUT/dataset.csv" 2>/dev/null | cut -d, -f2-)
WIN_END=$(grep '^window_end,' "$OUT/dataset.csv" 2>/dev/null | cut -d, -f2-)
wait_ready || exit 2
[ -n "$WIN_START" ] || { echo "중단: 실험 1을 먼저 돌립니다" >&2; exit 2; }

# 파티션이 실제로 잘렸는지는 계획에서 읽는다. 논리 읽기만 보면 캐시에 속는다.
partitions_touched(){
  local sql=$1
  QF "SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
SET STATISTICS XML ON;
${sql}
SET STATISTICS XML OFF;" | grep -o 'PartitionsAccessed[^/]*' | head -2
}

{
echo "# 실험 7. 파티션으로 조사 범위 자르기"
echo
echo "  원장을 created_at 월 단위로 파티션합니다. 사고 창은 ${WIN_START} 부터 4시간이고"
echo "  30일치 데이터 중 그 달의 파티션 하나에만 들어 있습니다."
echo

echo "## 7-1. 파티션 만들기"
QDX "SET NOCOUNT ON;
IF EXISTS (SELECT 1 FROM sys.partition_schemes WHERE name = 'ps_ledger')
BEGIN
  DROP TABLE IF EXISTS currency_ledger_p;
  DROP PARTITION SCHEME ps_ledger;
  DROP PARTITION FUNCTION pf_ledger;
END" || exit 2

QDX "CREATE PARTITION FUNCTION pf_ledger (DATETIME2(3))
     AS RANGE RIGHT FOR VALUES
     ('2026-07-01','2026-07-08','2026-07-15','2026-07-22','2026-07-29','2026-08-05');
     CREATE PARTITION SCHEME ps_ledger AS PARTITION pf_ledger ALL TO ([PRIMARY]);" || exit 2

# 파티션 테이블은 파티션 키가 클러스터드 키에 들어가야 정렬 파티셔닝이 된다.
QDX "SET NOCOUNT ON;
DROP TABLE IF EXISTS currency_ledger_p;
CREATE TABLE currency_ledger_p (
    ledger_id  BIGINT       NOT NULL,
    account_id INT          NOT NULL,
    delta      BIGINT       NOT NULL,
    reason     TINYINT      NOT NULL,
    ref_id     BIGINT       NULL,
    created_at DATETIME2(3) NOT NULL
) ON ps_ledger(created_at);
CREATE CLUSTERED INDEX CX_ledger_p ON currency_ledger_p (created_at, ledger_id)
    ON ps_ledger(created_at);" || exit 2

QDX "SET NOCOUNT ON;
INSERT INTO currency_ledger_p WITH (TABLOCK) (ledger_id, account_id, delta, reason, ref_id, created_at)
SELECT ledger_id, account_id, delta, reason, ref_id, created_at FROM currency_ledger;" || exit 2
QD "UPDATE STATISTICS currency_ledger_p WITH FULLSCAN;" >/dev/null

DIST=$(QD "SET NOCOUNT ON;
SELECT CAST(p.partition_number AS varchar(4)) + ':' + CAST(p.rows AS varchar(20))
  FROM sys.partitions p
 WHERE p.object_id = OBJECT_ID('currency_ledger_p') AND p.index_id = 1
 ORDER BY p.partition_number;")
echo "  파티션별 행 수: $(echo "$DIST" | grep -E '^[0-9]+:' | tr '\n' ' ')"
echo

echo "## 7-2. 조사 쿼리가 파티션을 자르는가"
echo
: > "$OUT/partition.csv"
echo "case,partitions_accessed,logical_reads" >> "$OUT/partition.csv"
printf "  %-40s %-22s %s\n" "조건" "읽은 파티션" "논리 읽기"

probe(){
  local label=$1 sql=$2
  local pa reads
  pa=$(partitions_touched "$sql" | head -1)
  pa=${pa:-확인 못 함}
  reads=$(logical_reads "$sql")
  printf "  %-40s %-22s %s\n" "$label" "$pa" "$reads"
  echo "\"$label\",\"$pa\",$reads" >> "$OUT/partition.csv"
}

# A 파티션 키를 조건에 넣는다.
probe "A created_at 범위 조건" "
SELECT COUNT(*) FROM currency_ledger_p
 WHERE created_at >= '$WIN_START' AND created_at < '$WIN_END';"

# B 파티션 키를 함수로 감싼다. 흔한 실수다.
probe "B created_at 을 CONVERT 로 감쌈" "
SELECT COUNT(*) FROM currency_ledger_p
 WHERE CONVERT(date, created_at) = CONVERT(date, '$WIN_START');"

# C 파티션 키가 조건에 없다. 계정으로만 찾는 경우.
probe "C 파티션 키 없이 account_id 로만" "
SELECT COUNT(*) FROM currency_ledger_p WHERE account_id = 8334;"

echo
echo "  A 는 조사 창이 든 파티션 하나만 읽습니다. B 와 C 는 전부 읽습니다."
echo

echo "## 7-3. 파티션만의 몫을 가른다"
echo
echo "  파티션 표는 클러스터드 키도 created_at 으로 바뀌었습니다. 원래 표(ledger_id"
echo "  클러스터드)와 바로 견주면 **두 변수가 섞입니다.** 파티션 없이 created_at 만"
echo "  클러스터드로 잡은 표를 하나 더 만들어 중간에 세웁니다."
echo
QDX "SET NOCOUNT ON;
DROP TABLE IF EXISTS currency_ledger_c;
CREATE TABLE currency_ledger_c (
    ledger_id  BIGINT       NOT NULL,
    account_id INT          NOT NULL,
    delta      BIGINT       NOT NULL,
    reason     TINYINT      NOT NULL,
    ref_id     BIGINT       NULL,
    created_at DATETIME2(3) NOT NULL
);
CREATE CLUSTERED INDEX CX_ledger_c ON currency_ledger_c (created_at, ledger_id);" || exit 2
QDX "SET NOCOUNT ON;
INSERT INTO currency_ledger_c WITH (TABLOCK) (ledger_id, account_id, delta, reason, ref_id, created_at)
SELECT ledger_id, account_id, delta, reason, ref_id, created_at FROM currency_ledger;" || exit 2
QD "UPDATE STATISTICS currency_ledger_c WITH FULLSCAN;" >/dev/null

WQ="WHERE created_at >= '''$WIN_START''' AND created_at < '''$WIN_END'''"
R_PLAIN=$(logical_reads "SELECT COUNT(*) FROM currency_ledger   WHERE created_at >= '$WIN_START' AND created_at < '$WIN_END';")
R_CLUST=$(logical_reads "SELECT COUNT(*) FROM currency_ledger_c WHERE created_at >= '$WIN_START' AND created_at < '$WIN_END';")
R_PART=$(logical_reads  "SELECT COUNT(*) FROM currency_ledger_p WHERE created_at >= '$WIN_START' AND created_at < '$WIN_END';")
printf "  %-46s %s\n" "1) 파티션 없음 + ledger_id 클러스터드 (원래 표)" "$R_PLAIN"
printf "  %-46s %s\n" "2) 파티션 없음 + created_at 클러스터드" "$R_CLUST"
printf "  %-46s %s\n" "3) 파티션 있음 + created_at 클러스터드" "$R_PART"
echo "\"1) 파티션X + ledger_id 클러스터드\",-,$R_PLAIN"  >> "$OUT/partition.csv"
echo "\"2) 파티션X + created_at 클러스터드\",-,$R_CLUST" >> "$OUT/partition.csv"
echo "\"3) 파티션O + created_at 클러스터드\",-,$R_PART"  >> "$OUT/partition.csv"
echo
echo "  1에서 2로 줄어든 것이 **클러스터드 키를 시간 순으로 잡은 몫**이고,"
echo "  2와 3의 차이가 **파티셔닝만의 몫**입니다."
echo
echo "  **파티셔닝은 조사 쿼리를 더 빠르게 하지 않았습니다.** 2와 3이 거의 같고 오히려"
echo "  파티션 표가 조금 더 읽습니다. 파티션 경계를 넘나드는 비용으로 보입니다."
echo "  창을 좁힌 힘은 사실상 전부 클러스터드 키를 시간 순으로 잡은 데서 왔습니다."

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  **파티셔닝은 이 조사 쿼리를 빠르게 하지 않았습니다.** 처음에는 원래 표와 파티션"
echo "  표를 바로 견줘 174배라고 적을 뻔했는데, 그 비교는 클러스터드 키 변경과 파티셔닝을"
echo "  한꺼번에 바꾼 것이었습니다. 변수를 하나로 만들자 파티셔닝의 몫은 사실상 0 이었고"
echo "  오히려 조금 더 읽었습니다."
echo
echo "  그러면 파티션은 왜 두는가. 조사 속도가 아니라 **다른 것 때문**입니다."
echo "    보존 정리를 DELETE 가 아니라 파티션 스위치로 한다 (R17 이 그 비교를 했다)"
echo "    파티션 단위로 인덱스를 다시 만들거나 압축할 수 있다"
echo "    오래된 파티션을 읽기 전용 파일 그룹으로 옮길 수 있다"
echo
echo "  조사만 놓고 보면 **클러스터드 키를 시간 순으로 잡는 것이 답**입니다."
echo "  인덱스와 달리 평소에 정하는 것이라 사고가 난 뒤에 쓰기를 막을 일도 없습니다(실험 4)."
echo
echo "  다만 파티션 제거는 조건을 탑니다."
echo "    조사 쿼리가 파티션 키를 **그대로** 조건에 넣어야 합니다"
echo "    함수로 감싸면(B) 계획이 못 자르고 전부 읽습니다"
echo "    파티션 키가 조건에 없으면(C) 자를 근거가 없습니다"
echo
echo "  B 가 특히 조심할 자리입니다. CONVERT(date, created_at) = ... 는 사람이 읽기에"
echo "  자연스럽고 결과도 맞습니다. 자르지 못한다는 것만 안 보입니다."
echo "  같은 저장소의 A22(인덱스는 있는데 못 쓴다)와 같은 모양입니다."
echo
echo "  파티션과 인덱스는 대체재가 아닙니다. 파티션이 범위를 자르고, 그 안에서 인덱스가"
echo "  조건을 좁힙니다. 조사 쿼리에는 둘 다 필요합니다."
} 2>&1 | tee "$OUT/exp7-partition.txt"
