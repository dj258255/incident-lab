#!/usr/bin/env bash
# 실험 3. 메모리 부여를 제대로 재고, 옵티마이저가 잘못 고르는 자리를 판다.
#
# 실험 2에서 둘이 남았다.
#   1) 메모리 부여를 못 쟀다. 실험 1은 쿼리 텍스트 LIKE 로 찾다 다른 회차와
#      섞였고, 실험 2는 아예 뺐다. Hash 가 메모리를 얼마나 요구하는지가
#      이 주제의 핵심인데 비어 있다.
#   2) 인덱스 없는 표의 10% 구간에서 **옵티마이저가 Nested Loops(3,317)를
#      골랐는데 Merge/Hash 가 3,119 로 더 적었다.** 최적을 안 골랐다.
#
# 메모리는 계획에 적힌 값을 쓴다. dm_exec_query_memory_grants 는 실행 중에만
# 채워지는데 이 쿼리가 짧아 못 잡는다. 계획의 MemoryGrant 는 **옵티마이저가
# 요구한 값**이지 실제 받은 값이 아니므로 표에 그렇게 적는다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
BIG=${BIG:-1000000}
SMALL=${SMALL:-1000}

wait_ready || exit 2

# 계획 XML 에서 연산자와 요구 메모리를 뽑는다.
plan_of(){ # $1=SQL  → "연산자|요구메모리KB|추정행수"
  # 계획 XML 은 한 줄이 매우 길다. -h -1 은 -y 0 과 같이 못 쓰므로(Sqlcmd 오류)
  # -h 를 빼고 -y 0 만 준다. 그리고 '<' 마다 줄을 나눠야 grep 이 잡는다.
  local xml; xml=$(docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -d "$DB" -y 0 -Q "SET SHOWPLAN_XML ON;
GO
$1
GO" 2>/dev/null | tr '<' '\n<')
  local op grant est
  op=$(echo "$xml" | grep -oE 'PhysicalOp="(Nested Loops|Hash Match|Merge Join)"' | head -1 | sed 's/.*="//;s/"//')
  grant=$(echo "$xml" | grep -oE 'SerialDesiredMemory="[0-9]+"' | head -1 | grep -oE '[0-9]+')
  # 조인 연산자가 나온 뒤 첫 EstimateRows 를 쓴다. 파일 첫 줄은 최종 집계라 항상 1이다.
  est=$(echo "$xml" | grep -A2 -E 'PhysicalOp="(Nested Loops|Hash Match|Merge Join)"' \
        | grep -oE 'EstimateRows="[0-9.e+]+"' | head -1 | sed 's/.*="//;s/"//')
  echo "${op:-?}|${grant:-0}|${est:-?}"
}

: > "$OUT/grant-and-misjudge.csv"
echo "table,selectivity,label,operator,grant_kb,est_rows,actual_rows,logical_reads" >> "$OUT/grant-and-misjudge.csv"

row(){ # $1=라벨 $2=표 $3=힌트 $4=선택도
  local label="$1" tbl="$2" hint="$3" sel="$4"
  local sql="SELECT COUNT(*) AS c, SUM(o.amount) AS s
               FROM $tbl o JOIN grade g ON g.grade_id = o.grade_id
              WHERE g.grade_id <= $sel$hint;"
  QD "DBCC FREEPROCCACHE; DBCC DROPCLEANBUFFERS;" >/dev/null 2>&1
  local p; p=$(plan_of "$sql")
  # local 은 인자를 전부 먼저 확장한다. 한 줄에 local a=X b=$a 를 쓰면
  # b 를 만들 때 a 가 아직 비어 있다. 그래서 나눠 쓴다.
  local op rest grant est
  op="${p%%|*}"; rest="${p#*|}"; grant="${rest%%|*}"; est="${rest##*|}"
  local io; io=$(QD "SET STATISTICS IO ON;
$sql")
  local reads; reads=$(echo "$io" | grep -oE 'logical reads [0-9]+' | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null)
  local act; act=$(num "$(QD "SET NOCOUNT ON;
    SELECT CAST(COUNT(*) AS varchar(20)) FROM $tbl o JOIN grade g ON g.grade_id=o.grade_id WHERE g.grade_id <= $sel;")")
  printf "  %-12s %-14s %10s %12s %12s %10s\n" "$label" "$op" "${grant}" "${est}" "${act}" "${reads:-?}"
  echo "\"$tbl\",\"$sel\",\"$label\",\"$op\",\"$grant\",\"$est\",\"$act\",\"${reads:-0}\"" >> "$OUT/grant-and-misjudge.csv"
}

{
echo "# 실험 3. 메모리 부여와 옵티마이저가 잘못 고르는 자리"
echo
echo "  메모리 값은 **옵티마이저가 계획에 적은 요구량**입니다(SerialDesiredMemory)."
echo "  실행 중 실제 부여량이 아닙니다. 이 쿼리가 짧아 dm_exec_query_memory_grants"
echo "  에는 안 잡힙니다. 그래서 구분해 적습니다."
echo

echo "=================================================================="
echo "## 3-1. 연산자별 메모리 요구량"
echo "=================================================================="
echo
for T in orders orders_noidx; do
  echo "  [$T] 등급 1000개 (주문 100만행 전부)"
  printf "  %-12s %-14s %10s %12s %12s %10s\n" "조건" "연산자" "요구메모리KB" "추정행수" "실제행수" "논리읽기"
  row "LOOP 강제"  "$T" " OPTION (LOOP JOIN)"  1000
  row "MERGE 강제" "$T" " OPTION (MERGE JOIN)" 1000
  row "HASH 강제"  "$T" " OPTION (HASH JOIN)"  1000
  echo
done
echo "  **Nested Loops 는 메모리를 안 씁니다.** 바깥 행마다 안쪽을 찾을 뿐이라"
echo "  중간 자료구조가 없습니다. Merge 는 정렬이 필요하면 그때 쓰고, Hash 는"
echo "  해시 표를 들고 있어야 하므로 항상 씁니다."
echo

echo "=================================================================="
echo "## 3-2. 옵티마이저가 최적을 안 고르는 자리"
echo "=================================================================="
echo
echo "  실험 2에서 인덱스 없는 표의 10% 구간이 이상했습니다."
echo "  옵티마이저가 Nested Loops 를 골랐는데 Merge/Hash 가 논리 읽기가 더 적었습니다."
echo "  그 구간을 좁혀 봅니다."
echo
for SEL in 50 100 200 400; do
  echo "  [orders_noidx] 등급 ${SEL}개 (전체의 $(( SEL * 100 / SMALL ))%)"
  printf "  %-12s %-14s %10s %12s %12s %10s\n" "조건" "연산자" "요구메모리KB" "추정행수" "실제행수" "논리읽기"
  row "옵티마이저" orders_noidx ""                     "$SEL"
  row "MERGE 강제" orders_noidx " OPTION (MERGE JOIN)" "$SEL"
  row "HASH 강제"  orders_noidx " OPTION (HASH JOIN)"  "$SEL"
  echo
done

echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  추정 행수와 실제 행수를 나란히 두었습니다. 옵티마이저의 선택은"
echo "  **추정을 근거로** 하므로, 추정이 어긋난 자리에서 선택도 어긋납니다."
} 2>&1 | tee "$OUT/exp3-grant-and-misjudge.txt"
