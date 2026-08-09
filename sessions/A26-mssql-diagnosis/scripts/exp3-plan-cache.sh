#!/usr/bin/env bash
# 실험 3. 대기가 락이 아닐 때 범인 쿼리를 찾는다.
#
# 대기 차분이 PAGEIOLATCH 나 SOS_SCHEDULER_YIELD 를 가리키면 막고 있는 세션이 아니라
# **많이 읽는 쿼리**를 찾아야 한다. 정석은 sys.dm_exec_query_stats 를 총 논리 읽기로
# 정렬하는 것이다.
#
# 그런데 그 목록에 안 나오는 범인이 있다. 값을 리터럴로 박아 던지는 쿼리다.
# 값마다 다른 계획으로 캐시에 들어가므로, 수천 번 돌아도 각 계획은 실행 1회로 남는다.
# 상위 N 을 봐도 안 보인다. **부하는 다 주면서 순위에는 안 잡힌다.**
#
# 조건 둘이다. 읽는 양과 횟수는 같고 값을 넘기는 방법만 다르다.
#   A 파라미터로 넘긴다   계획 하나에 실행 N 회
#   B 리터럴로 박는다     계획 N 개에 실행 1 회씩
#
# 처음에는 단순한 SELECT COUNT(*) ... WHERE tag = <값> 으로 재다가 가설이 반박됐다.
# 리터럴 쪽도 계획 하나에 실행 60회로 모였다. 캐시를 열어 보니 텍스트가
# "(@1 tinyint)SELECT COUNT(*) FROM [account_currency] WHERE [tag]=@1" 이었다.
# **엔진이 알아서 파라미터화한 것이다(단순 매개 변수화).**
#
# 그것이 늘 되는 것은 아니다. 조인이 들어가면 안전하다고 판단하지 않아 안 해 준다.
# 그래서 두 조건 다 조인을 넣어 자동 파라미터화가 안 걸리게 하고 다시 잰다.
# 구분은 주석 표시로 한다. 텍스트 모양으로 가르려다 자동 파라미터화된 것이
# 대괄호와 공백까지 바꿔 놓아 안 잡혔다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
N=${N:-60}

wait_ready || exit 2
setup_db || exit 2
# 인덱스 없는 컬럼을 조건으로 써 매번 풀스캔이 되게 한다.
# ALTER 와 UPDATE 를 한 배치에 두면 컴파일 시점에 컬럼이 없어 Msg 207 로 죽는다.
# A04 에서 없는 컬럼을 참조하는 분기 때문에 같은 것을 밟았다. 배치를 나눈다.
QDX "IF COL_LENGTH('account_currency','tag') IS NULL
       ALTER TABLE account_currency ADD tag INT NOT NULL DEFAULT 0;" || exit 2
QDX "SET NOCOUNT ON;
     UPDATE account_currency SET tag = account_id % 1000;
     UPDATE STATISTICS account_currency WITH FULLSCAN;" || exit 2

{
echo "# 실험 3. 순위에 안 잡히는 범인"
echo
echo "  같은 부하를 두 방법으로 겁니다. 읽는 양과 횟수는 같고 값을 넘기는 방법만 다릅니다."
echo "    A 파라미터로 넘긴다"
echo "    B 값을 리터럴로 박는다"
echo "  각각 ${N}회씩. 조인을 넣어 **자동 파라미터화가 안 걸리게** 했습니다."
echo

QD "DBCC FREEPROCCACHE WITH NO_INFOMSGS;" >/dev/null

echo "## 3-1. 부하를 건다"
for i in $(seq 1 "$N"); do
  QD "SET NOCOUNT ON;
      EXEC sp_executesql N'/*PARAM*/ SELECT COUNT(*) FROM account_currency a
                            JOIN account_currency b ON b.account_id = a.account_id
                           WHERE a.tag = @t',
                         N'@t INT', @t = $i;" >/dev/null
done
for i in $(seq 1 "$N"); do
  QD "SET NOCOUNT ON;
      /*LITERAL*/ SELECT COUNT(*) FROM account_currency a
        JOIN account_currency b ON b.account_id = a.account_id
       WHERE a.tag = $i;" >/dev/null
done
echo "  각 ${N}회 실행 완료"
echo

echo "## 3-2. 계획 캐시에 어떻게 들어갔나"
echo
STAT=$(num "$(QD "SET NOCOUNT ON;
SELECT CAST(SUM(CASE WHEN t.text LIKE '%/*PARAM*/%'   THEN 1 ELSE 0 END) AS varchar(8))
     + ',' + CAST(SUM(CASE WHEN t.text LIKE '%/*PARAM*/%'   THEN qs.execution_count ELSE 0 END) AS varchar(12))
     + ',' + CAST(SUM(CASE WHEN t.text LIKE '%/*LITERAL*/%' THEN 1 ELSE 0 END) AS varchar(8))
     + ',' + CAST(SUM(CASE WHEN t.text LIKE '%/*LITERAL*/%' THEN qs.execution_count ELSE 0 END) AS varchar(12))
  FROM sys.dm_exec_query_stats qs
 CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t;")")
IFS=, read -r a_plans a_exec b_plans b_exec <<<"$STAT"
printf "  %-18s %-14s %s\n" "" "계획 개수" "총 실행 횟수"
printf "  %-18s %-14s %s\n" "A 파라미터" "${a_plans}개" "${a_exec}회"
printf "  %-18s %-14s %s\n" "B 리터럴" "${b_plans}개" "${b_exec}회"
echo
echo "  같은 횟수를 돌렸는데 A 는 계획 하나에 모이고 B 는 흩어집니다."
echo

echo "## 3-3. 총 논리 읽기 상위를 보면"
echo
echo "  정석대로 total_logical_reads 로 정렬해 상위 3개를 봅니다."
echo
QD "SET NOCOUNT ON;
SELECT TOP 3 CAST(qs.execution_count AS varchar(10)) + '|' + CAST(qs.total_logical_reads AS varchar(20))
     + '|' + LEFT(LTRIM(REPLACE(REPLACE(t.text, CHAR(13), ' '), CHAR(10), ' ')), 34)
  FROM sys.dm_exec_query_stats qs
 CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
 WHERE t.text LIKE '%/*PARAM*/%' OR t.text LIKE '%/*LITERAL*/%'
 ORDER BY qs.total_logical_reads DESC;" | grep -E '^[0-9]+\|' \
 | while IFS='|' read -r ec lr tx; do printf "    실행 %-6s 논리읽기 %-12s %s\n" "$ec" "$lr" "$tx"; done
echo
echo "  A 는 한 줄로 크게 잡힙니다. B 는 각 계획이 1회·소량이라 상위에 못 옵니다."
echo "  **부하는 절반을 B 가 주는데 순위에는 A 만 보입니다.**"
echo

echo "## 3-4. query_hash 로 묶으면"
echo
QD "SET NOCOUNT ON;
SELECT TOP 3 CAST(COUNT(*) AS varchar(8)) + '|' + CAST(SUM(qs.execution_count) AS varchar(12))
     + '|' + CAST(SUM(qs.total_logical_reads) AS varchar(20))
  FROM sys.dm_exec_query_stats qs
 CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
 WHERE t.text LIKE '%/*PARAM*/%' OR t.text LIKE '%/*LITERAL*/%'
 GROUP BY qs.query_hash
 ORDER BY SUM(qs.total_logical_reads) DESC;" | grep -E '^[0-9]+\|' \
 | while IFS='|' read -r pc ec lr; do printf "    계획 %-6s 실행 %-8s 논리읽기 %s\n" "$pc" "$ec" "$lr"; done
echo
echo "  같은 모양의 쿼리는 값이 달라도 query_hash 가 같습니다. 파라미터로 넘긴 것과"
echo "  리터럴로 박은 것도 모양이 같으므로 한 줄로 모입니다."
TOP1=$(num "$(QD "SET NOCOUNT ON;
SELECT TOP 1 CAST(qs.total_logical_reads AS varchar(20)) FROM sys.dm_exec_query_stats qs
 CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
 WHERE t.text LIKE '%/*PARAM*/%' OR t.text LIKE '%/*LITERAL*/%'
 ORDER BY qs.total_logical_reads DESC;")")
GRP=$(num "$(QD "SET NOCOUNT ON;
SELECT TOP 1 CAST(SUM(qs.total_logical_reads) AS varchar(20)) FROM sys.dm_exec_query_stats qs
 CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
 WHERE t.text LIKE '%/*PARAM*/%' OR t.text LIKE '%/*LITERAL*/%'
 GROUP BY qs.query_hash ORDER BY SUM(qs.total_logical_reads) DESC;")")
echo
printf "  %-30s %s\n" "묶기 전 상위 1위" "$TOP1"
printf "  %-30s %s\n" "query_hash 로 묶은 뒤" "$GRP"
echo
echo "  **묶기 전에는 실제 부하의 절반만 보였습니다.**"

{ echo "method,plans,executions"
  echo "parameterized,$a_plans,$a_exec"
  echo "literal,$b_plans,$b_exec"; } > "$OUT/plan-cache.csv"

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  **엔진이 알아서 파라미터화해 주는 구간이 있습니다.** 처음에는 단순한"
echo "  SELECT COUNT(*) ... WHERE tag = <값> 으로 쟀는데 리터럴 쪽도 계획 하나에"
echo "  모였습니다. 캐시 텍스트가 (@1 tinyint)SELECT ... WHERE [tag]=@1 이었습니다."
echo "  단순 매개 변수화가 걸린 것이고, 그 구간에서는 리터럴을 써도 안 흩어집니다."
echo
echo "  다만 그것은 엔진이 안전하다고 판단하는 아주 단순한 쿼리에만 걸립니다."
echo "  조인 하나만 넣어도 안 해 줍니다. 실무의 조사 쿼리는 대부분 그쪽입니다."
echo
echo "  대기가 락이 아니면 많이 읽는 쿼리를 찾아야 하는데, **total_logical_reads 로"
echo "  정렬한 상위 N 은 리터럴 쿼리를 못 잡습니다.** 값마다 다른 계획으로 흩어져"
echo "  각각은 실행 1회에 소량이기 때문입니다. 부하는 다 주면서 순위에는 안 잡힙니다."
echo
echo "  **query_hash 로 묶어서 봅니다.** 같은 모양이면 값이 달라도 해시가 같습니다."
echo "  묶고 나면 흩어져 있던 것이 한 줄로 모여 상위에 올라옵니다."
echo
echo "  덧붙여 계획이 많이 흩어지는 것 자체가 문제입니다. 계획 캐시가 부풀고,"
echo "  매번 컴파일하느라 CPU 를 씁니다. 근본 해소는 진단이 아니라 **애플리케이션이"
echo "  값을 파라미터로 넘기게 고치는 것**입니다."
echo
echo "  대기 통계와 같은 함정이 하나 더 있습니다. query_stats 도 누적이고, 게다가"
echo "  **계획이 캐시에서 밀려나면 그 통계도 함께 사라집니다.** 사고가 지나간 뒤에"
echo "  들여다보면 범인이 이미 없을 수 있습니다."
} 2>&1 | tee "$OUT/exp3-plan-cache.txt"
