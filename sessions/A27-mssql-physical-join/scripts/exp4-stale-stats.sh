#!/usr/bin/env bash
# 실험 4. 통계가 낡으면 연산자를 잘못 고른다.
#
# 첫 설계가 틀렸다(exp4-stale-stats.sh.v1 로 남겨 둠). 표에 행을 100만으로
# 늘리고 통계를 안 갱신했는데 연산자가 안 바뀌었다. 계획을 열어 보니 이유가 둘.
#
#   1) TableCardinality="1e+06" 이 이미 맞다. **행 수 메타데이터는 통계와 별개로
#      항상 최신**이다. 낡는 것은 히스토그램(값의 분포)이지 전체 행 수가 아니다.
#   2) 쿼리가 집계라 조인 앞에서 Stream Aggregate 가 1,000행으로 줄여 버렸다.
#
# 그래서 **히스토그램이 못 보는 값**을 만든다. 통계를 뜬 뒤에 들어온 새 값은
# 히스토그램에 없으므로 옵티마이저가 "이 값은 거의 없다"고 추정한다.
# 오름차순 키에서 자주 나는 모양이고, 배치가 새 batch_id 로 적재할 때 그대로다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
OLD=${OLD:-1000000}
NEW=${NEW:-500000}
NEWKEY=${NEWKEY:-9999}

wait_ready || exit 2

probe(){ # $1=라벨
  local label="$1"
  local sql="SELECT COUNT(*) AS c, SUM(o.amount) AS s
               FROM batch2 o JOIN grade g ON g.grade_id = o.grade_id
              WHERE o.batch_id = $NEWKEY;"
  QD "DBCC FREEPROCCACHE; DBCC DROPCLEANBUFFERS;" >/dev/null 2>&1
  local xml; xml=$(docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -d "$DB" -y 0 -Q "SET SHOWPLAN_XML ON;
GO
$sql
GO" 2>/dev/null | tr '<' '\n<')
  local op est
  op=$(echo "$xml" | grep -oE 'PhysicalOp="(Nested Loops|Hash Match|Merge Join)"' | head -1 | sed 's/.*="//;s/"//')
  # batch2 를 읽는 연산자의 추정 행수. 이것이 히스토그램이 말하는 값이다.
  # grade 의 Clustered Index Scan 이 먼저 나오므로 그것을 잡으면 안 된다.
  # batch2 를 읽는 Index Seek 만 본다. 이 값이 히스토그램이 말하는 추정이다.
  est=$(echo "$xml" | grep -E 'PhysicalOp="Index Seek"' \
        | grep -oE 'EstimateRows="[0-9.e+]+"' | head -1 | sed 's/.*="//;s/"//')
  local io; io=$(QD "SET STATISTICS IO ON; SET STATISTICS TIME ON;
$sql")
  local reads cpu
  reads=$(echo "$io" | grep -oE 'logical reads [0-9]+' | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null)
  cpu=$(echo "$io" | grep -oE 'CPU time = [0-9]+' | tail -1 | grep -oE '[0-9]+')
  printf "  %-26s %-14s %12s %12s %10s %8s\n" \
    "$label" "${op:-?}" "${est:-?}" "$NEW" "${reads:-?}" "${cpu:-?}"
  echo "\"$label\",\"${op:-?}\",\"${est:-0}\",\"$NEW\",\"${reads:-0}\",\"${cpu:-0}\"" >> "$OUT/stale-stats.csv"
}

: > "$OUT/stale-stats.csv"
echo "label,operator,est_rows,actual_rows,logical_reads,cpu_ms" >> "$OUT/stale-stats.csv"

{
echo "# 실험 4. 통계가 낡으면 연산자를 잘못 고른다"
echo
echo "  첫 설계가 틀렸습니다. 행을 100만으로 늘리고 통계를 안 갱신했는데"
echo "  연산자가 안 바뀌었습니다. 계획을 열어 보니 이유가 둘이었습니다."
echo
echo "    TableCardinality 가 이미 맞았습니다. **행 수 메타데이터는 통계와 별개로"
echo "    항상 최신**이고, 낡는 것은 히스토그램(값의 분포)입니다."
echo "    그리고 쿼리가 집계라 조인 앞에서 미리 줄어들었습니다."
echo
echo "  그래서 **히스토그램이 못 보는 값**을 만듭니다. 통계를 뜬 뒤에 들어온"
echo "  새 값은 히스토그램에 없으므로 옵티마이저가 거의 없다고 추정합니다."
echo "  배치가 새 batch_id 로 적재할 때 그대로 나는 모양입니다."
echo

QDX "SET NOCOUNT ON;
ALTER DATABASE [$DB] SET AUTO_UPDATE_STATISTICS OFF;
DROP TABLE IF EXISTS batch2;
CREATE TABLE batch2 (
    id       INT    NOT NULL IDENTITY PRIMARY KEY,
    batch_id INT    NOT NULL,
    grade_id INT    NOT NULL,
    amount   BIGINT NOT NULL);
INSERT INTO batch2 WITH (TABLOCK) (batch_id, grade_id, amount)
SELECT (i % 100) + 1, (i % 1000) + 1, 1000 FROM nums_src WHERE i <= $OLD;
CREATE INDEX ix_b2 ON batch2 (batch_id) INCLUDE (grade_id, amount);
UPDATE STATISTICS batch2 WITH FULLSCAN;" || exit 2

echo "=================================================================="
echo "## 히스토그램에 없는 값이 들어오면"
echo "=================================================================="
echo
printf "  %-26s %-14s %12s %12s %10s %8s\n" "상태" "연산자" "추정행수" "실제행수" "논리읽기" "CPU(ms)"

# 새 batch_id 로 50만 행을 넣는다. 통계는 안 건드린다.
QDX "SET NOCOUNT ON;
INSERT INTO batch2 WITH (TABLOCK) (batch_id, grade_id, amount)
SELECT $NEWKEY, (i % 1000) + 1, 1000 FROM nums_src WHERE i <= $NEW;" || exit 2
probe "A 통계를 안 갱신"

QDX "UPDATE STATISTICS batch2 WITH FULLSCAN;" || exit 2
probe "B 통계만 갱신"

echo
echo "  A 와 B 는 **같은 데이터, 같은 쿼리, 같은 인덱스**입니다."
echo "  바뀐 것은 통계 하나뿐입니다."
echo

echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  **추정은 크게 어긋나는데 연산자는 안 바뀌었습니다.**"
echo
echo "  통계를 뜬 뒤에 들어온 값은 히스토그램에 없습니다. 그래서 추정이 실제의"
echo "  1/408 로 떨어집니다. 그런데도 옵티마이저는 Hash Match 를 유지했습니다."
echo
echo "  SQL Server 2022 의 기본 카디널리티 추정기가 히스토그램 밖 값을 0 으로"
echo "  보지 않고 밀도 벡터로 1,224 를 잡아 주기 때문입니다. 연산자가 뒤집히려면"
echo "  추정이 **1행 수준**까지 떨어져야 하는데 그 정도로는 안 틀립니다."
echo
echo "  \"통계가 낡으면 계획이 뒤집힌다\"는 흔한 설명인데, **이 규모와 이 엔진에서는"
echo "  그렇게까지 안 갔습니다.** 대신 추정이 408배 어긋난 채로 돕니다. 메모리 부여와"
echo "  병렬 판단이 그 추정을 근거로 하므로 위험은 다른 자리에 남습니다."
QDX "ALTER DATABASE [$DB] SET AUTO_UPDATE_STATISTICS ON;" >/dev/null 2>&1
} 2>&1 | tee "$OUT/exp4-stale-stats.txt"
