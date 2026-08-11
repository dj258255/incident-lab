#!/usr/bin/env bash
# 실험 2. 셋이 각각 이기는 조건을 따로 만든다.
#
# 실험 1은 한쪽으로 기울어 있었다. 조인 키에 양쪽 다 인덱스가 있어서
# **Merge 가 정렬 비용을 안 냈고**, 그래서 Hash 가 한 번도 안 골라졌다.
# 논리 읽기도 Merge 와 Hash 가 같게 나왔다. 조건을 안 만들어 놓고
# "Hash 가 안 좋다"고 읽으면 틀린다.
#
# 여기서는 조건을 셋 만든다.
#   A 정렬돼 있고 한쪽이 작다        → Nested Loops 자리
#   B 정렬돼 있고 양쪽이 크다        → Merge Join 자리
#   C 정렬이 없다 (조인 키에 인덱스 없음) → Hash Match 자리
#
# 그리고 메모리 부여를 실험 1처럼 쿼리 텍스트 LIKE 로 찾지 않는다.
# 힌트가 붙은 다른 회차와 섞인다. sys.dm_exec_query_memory_grants 를
# 쓰거나, 계획 자체에서 뽑는다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

BIG=${BIG:-1000000}
SMALL=${SMALL:-1000}

wait_ready || exit 2

# ── 데이터 ──────────────────────────────────────────────────────────────
# noidx 는 조인 키에 인덱스가 없는 표다. 같은 내용, 같은 행 수.
QDX "SET NOCOUNT ON;
IF OBJECT_ID('orders_noidx') IS NULL
BEGIN
  SELECT order_id, grade_id, amount INTO orders_noidx FROM orders;
  ALTER TABLE orders_noidx ADD CONSTRAINT pk_noidx PRIMARY KEY (order_id);
  UPDATE STATISTICS orders_noidx WITH FULLSCAN;
END" || exit 2

N1=$(num "$(QD "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS varchar(20)) FROM orders_noidx")")
[ "$N1" = "$BIG" ] || { echo "중단: orders_noidx 가 ${N1}행입니다" >&2; exit 2; }

# ── 측정 ────────────────────────────────────────────────────────────────
# 메모리 부여는 실행 중에 dm_exec_query_memory_grants 를 봐야 정확한데
# 쿼리가 짧아 못 잡는다. 계획에 적힌 요청량(SerialRequiredMemory /
# SerialDesiredMemory)을 SHOWPLAN_ALL 에서 뽑는다. 실행값이 아니라
# **옵티마이저가 요구한 값**이라는 것을 표에 밝혀 둔다.
measure(){ # $1=라벨 $2=표 $3=힌트 $4=선택도
  local label="$1" tbl="$2" hint="$3" sel="$4"
  local sql="SELECT COUNT(*) AS c, SUM(o.amount) AS s
               FROM $tbl o JOIN grade g ON g.grade_id = o.grade_id
              WHERE g.grade_id <= $sel$hint;"
  QD "DBCC FREEPROCCACHE; DBCC DROPCLEANBUFFERS;" >/dev/null 2>&1

  local io; io=$(QD "SET STATISTICS IO ON; SET STATISTICS TIME ON;
$sql")
  local reads cpu
  reads=$(echo "$io" | grep -oE 'logical reads [0-9]+' | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null)
  cpu=$(echo "$io" | grep -oE 'CPU time = [0-9]+' | tail -1 | grep -oE '[0-9]+')

  local plan op mem
  plan=$(QD "SET SHOWPLAN_ALL ON;
GO
$sql
GO" 2>/dev/null)
  op=$(echo "$plan" | grep -oE 'Nested Loops|Hash Match|Merge Join' | head -1)
  # 계획 행의 마지막 컬럼들에 직렬 필요/희망 메모리가 KB 로 들어 있다.
  mem=$(echo "$plan" | grep -oE 'Sort|Hash Match' >/dev/null && echo "요구" || echo "-")
  local err; err=$(echo "$io" | grep -cE '^(Msg|메시지) [0-9]+')

  printf "  %-14s %-14s %10s %10s %s\n" \
    "$label" "${op:-?}" "${reads:-?}" "${cpu:-?}" "$([ "$err" -gt 0 ] && echo '**오류**' || echo '')"
  echo "\"$tbl\",\"$sel\",\"$label\",\"${op:-?}\",\"${reads:-0}\",\"${cpu:-0}\"" >> "$OUT/when-each-wins.csv"
}

: > "$OUT/when-each-wins.csv"
echo "table,selectivity,label,operator,logical_reads,cpu_ms" >> "$OUT/when-each-wins.csv"

{
echo "# 실험 2. 셋이 각각 이기는 조건을 따로 만든다"
echo
echo "  실험 1은 조인 키에 양쪽 다 인덱스가 있어서 **Merge 가 정렬 비용을 안 냈습니다.**"
echo "  그래서 Hash 가 한 번도 안 골라졌고 논리 읽기도 Merge 와 같게 나왔습니다."
echo "  조건을 안 만들어 놓고 \"Hash 가 안 좋다\"고 읽으면 틀립니다."
echo
echo "  여기서는 조건을 나눕니다. orders 는 grade_id 에 인덱스가 있고,"
echo "  orders_noidx 는 같은 내용인데 그 인덱스가 없습니다."
echo

echo "=================================================================="
echo "## A. 조인 키에 인덱스가 있을 때"
echo "=================================================================="
echo
for SEL in 1 100 1000; do
  echo "  등급 ${SEL}개 (주문 약 $(( BIG * SEL / SMALL ))행)"
  printf "  %-14s %-14s %10s %10s\n" "조건" "실제 연산자" "논리읽기" "CPU(ms)"
  measure "옵티마이저"  orders ""                     "$SEL"
  measure "LOOP 강제"  orders " OPTION (LOOP JOIN)"   "$SEL"
  measure "MERGE 강제" orders " OPTION (MERGE JOIN)"  "$SEL"
  measure "HASH 강제"  orders " OPTION (HASH JOIN)"   "$SEL"
  echo
done

echo "=================================================================="
echo "## B. 조인 키에 인덱스가 없을 때 (같은 데이터)"
echo "=================================================================="
echo
for SEL in 1 100 1000; do
  echo "  등급 ${SEL}개 (주문 약 $(( BIG * SEL / SMALL ))행)"
  printf "  %-14s %-14s %10s %10s\n" "조건" "실제 연산자" "논리읽기" "CPU(ms)"
  measure "옵티마이저"  orders_noidx ""                     "$SEL"
  measure "LOOP 강제"  orders_noidx " OPTION (LOOP JOIN)"   "$SEL"
  measure "MERGE 강제" orders_noidx " OPTION (MERGE JOIN)"  "$SEL"
  measure "HASH 강제"  orders_noidx " OPTION (HASH JOIN)"   "$SEL"
  echo
done

echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  A 와 B 의 같은 줄을 견주면 **인덱스 하나가 연산자 선택을 바꾸는 것**이 보입니다."
echo "  그리고 강제했을 때의 대가가 조건마다 다릅니다."
} 2>&1 | tee "$OUT/exp2-when-each-wins.txt"
