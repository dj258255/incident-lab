#!/usr/bin/env bash
# 실험 1. 같은 조인을 세 연산자로 강제하면 무엇이 달라지는가.
#
# 옵티마이저는 조인마다 물리 연산자를 하나 고른다. 셋뿐이다.
#   Nested Loops  바깥 행마다 안쪽을 찾는다. 바깥이 작을 때
#   Merge Join    양쪽을 정렬해 놓고 한 번씩 훑는다. 둘 다 정렬돼 있을 때
#   Hash Match    한쪽으로 해시 표를 만들고 다른 쪽을 던진다. 둘 다 클 때
#
# "이 쿼리 나가도 됩니까"를 판단하려면 **무엇이 골라졌고 왜 그것인지**를 알아야 한다.
# 여기서는 같은 조인에 셋을 차례로 강제해 대가를 잰다.
#
# 재는 것
#   논리 읽기   하드웨어와 무관. 이 랩의 기준값
#   메모리 부여 Hash/Merge 는 메모리를 요구한다. Nested Loops 는 안 쓴다
#   CPU 시간    같은 호스트 안에서의 상대 비교로만 쓴다
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

BIG=${BIG:-1000000}     # 주문
SMALL=${SMALL:-1000}    # 회원 등급

wait_ready || exit 2

# ── 데이터 ──────────────────────────────────────────────────────────────
# 조인 컬럼에 인덱스가 있어야 Nested Loops 와 Merge Join 이 성립한다.
# 인덱스가 없으면 옵티마이저에 선택지가 사실상 Hash 하나뿐이라 비교가 안 된다.
Q "IF DB_ID('$DB') IS NULL CREATE DATABASE [$DB]" >/dev/null
QDX "SET NOCOUNT ON;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS grade;

CREATE TABLE grade (
    grade_id  INT          NOT NULL PRIMARY KEY,
    grade_name VARCHAR(20) NOT NULL,
    bonus_rate INT         NOT NULL);

CREATE TABLE orders (
    order_id  INT    NOT NULL PRIMARY KEY,
    grade_id  INT    NOT NULL,
    amount    BIGINT NOT NULL,
    filler    CHAR(50) NOT NULL DEFAULT '');

WITH n AS (SELECT TOP ($SMALL) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
             FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO grade (grade_id, grade_name, bonus_rate) SELECT i, 'G' + CAST(i AS varchar(10)), i % 30 FROM n;

-- 3중 CROSS JOIN(2,641^3 = 184억)은 TOP 이 있어도 계획을 못 세우고 멈춘다.
-- 숫자 표를 먼저 만들고 거기서 뽑는다.
DROP TABLE IF EXISTS nums;
CREATE TABLE nums (i INT NOT NULL PRIMARY KEY);
WITH n AS (SELECT TOP ($BIG) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
             FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO nums WITH (TABLOCK) (i) SELECT i FROM n;

INSERT INTO orders WITH (TABLOCK) (order_id, grade_id, amount)
SELECT i, (i % $SMALL) + 1, 1000 + (i % 977) FROM nums;
DROP TABLE nums;

CREATE INDEX ix_orders_grade ON orders (grade_id) INCLUDE (amount);
UPDATE STATISTICS orders WITH FULLSCAN;
UPDATE STATISTICS grade  WITH FULLSCAN;" || exit 2

GOT_O=$(num "$(QD "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS varchar(20)) FROM orders")")
GOT_G=$(num "$(QD "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS varchar(20)) FROM grade")")
[ "$GOT_O" = "$BIG" ] && [ "$GOT_G" = "$SMALL" ] || {
  echo "중단: 적재가 주문 ${GOT_O}행 / 등급 ${GOT_G}행 입니다" >&2; exit 2; }

# ── 측정 ────────────────────────────────────────────────────────────────
# 논리 읽기는 STATISTICS IO, 메모리 부여는 dm_exec_query_stats 에서 가져온다.
# 캐시를 비우고 재야 회차마다 같은 조건이 된다.
measure(){ # $1=라벨 $2=힌트 $3=선택도(등급 몇 개를 걸치나)
  local label="$1" hint="$2" sel="$3"
  local sql="SELECT COUNT(*) AS c, SUM(o.amount) AS s
               FROM orders o JOIN grade g ON g.grade_id = o.grade_id
              WHERE g.grade_id <= $sel$hint;"
  QD "DBCC FREEPROCCACHE; DBCC DROPCLEANBUFFERS;" >/dev/null 2>&1

  local io; io=$(QD "SET STATISTICS IO ON; SET STATISTICS TIME ON;
$sql")
  local reads cpu elapsed
  reads=$(echo "$io" | grep -oE 'logical reads [0-9]+' | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null)
  cpu=$(echo "$io" | grep -oE 'CPU time = [0-9]+' | tail -1 | grep -oE '[0-9]+')
  elapsed=$(echo "$io" | grep -oE 'elapsed time = [0-9]+' | tail -1 | grep -oE '[0-9]+')

  # 실제로 무엇이 골라졌는지, 메모리를 얼마나 부여받았는지
  local op grant
  op=$(QD "SET SHOWPLAN_TEXT ON;
GO
$sql
GO" 2>/dev/null | grep -oE 'Nested Loops|Hash Match|Merge Join' | head -1)
  grant=$(num "$(QD "SET NOCOUNT ON;
    SELECT TOP 1 CAST(ISNULL(max_grant_kb,0) AS varchar(20))
      FROM sys.dm_exec_query_stats qs
      CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
     WHERE t.text LIKE '%FROM orders o JOIN grade g%'
     ORDER BY qs.last_execution_time DESC;")")

  printf "  %-16s %-14s %10s %12s %10s %10s\n" \
    "$label" "${op:-?}" "${reads:-?}" "${grant:-0}" "${cpu:-?}" "${elapsed:-?}"
  echo "\"$sel\",\"$label\",\"${op:-?}\",\"${reads:-0}\",\"${grant:-0}\",\"${cpu:-0}\",\"${elapsed:-0}\"" >> "$OUT/three-operators.csv"
}

: > "$OUT/three-operators.csv"
echo "selectivity,label,operator,logical_reads,grant_kb,cpu_ms,elapsed_ms" >> "$OUT/three-operators.csv"

{
echo "# 실험 1. 같은 조인을 세 연산자로 강제하면"
echo
echo "  옵티마이저가 조인에 고를 수 있는 물리 연산자는 셋뿐입니다."
echo "  같은 조인에 셋을 차례로 강제해 각각 무엇을 대가로 내는지 잽니다."
echo
printf "  %-20s %s\n" "주문" "${BIG}행 (grade_id 에 인덱스 + amount 포함)"
printf "  %-20s %s\n" "등급" "${SMALL}행 (PK)"
printf "  %-20s %s\n" "조인" "orders.grade_id = grade.grade_id"
echo
echo "  시간은 같은 호스트 안에서의 상대 비교로만 씁니다. 기준은 논리 읽기입니다."
echo

for SEL in 1 10 100 1000; do
  PCT=$(( SEL * 100 / SMALL ))
  echo "=================================================================="
  echo "## 등급 ${SEL}개를 걸칠 때 (전체의 ${PCT}%, 주문 약 $(( BIG * SEL / SMALL ))행)"
  echo "=================================================================="
  echo
  printf "  %-16s %-14s %10s %12s %10s %10s\n" "조건" "실제 연산자" "논리읽기" "메모리(KB)" "CPU(ms)" "경과(ms)"
  measure "옵티마이저 선택" ""                            "$SEL"
  measure "LOOP 강제"      " OPTION (LOOP JOIN)"          "$SEL"
  measure "MERGE 강제"     " OPTION (MERGE JOIN)"         "$SEL"
  measure "HASH 강제"      " OPTION (HASH JOIN)"          "$SEL"
  echo
done

echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  표를 세로로 읽으면 옵티마이저가 무엇을 보고 고르는지가 나옵니다."
echo "  가로로 읽으면 잘못 고르면 얼마를 더 내는지가 나옵니다."
} 2>&1 | tee "$OUT/exp1-three-operators.txt"
