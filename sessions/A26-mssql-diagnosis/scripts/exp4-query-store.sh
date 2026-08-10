#!/usr/bin/env bash
# 실험 4. 계획이 캐시에서 밀려나면 범인이 사라진다, 그리고 Query Store.
#
# 못 한 것에 둘을 남겼다.
#   "계획이 캐시에서 밀려나는 것을 안 봤습니다. query_stats 는 계획이 사라지면
#    통계도 함께 사라집니다. 사고가 지나간 뒤에 들여다보면 범인이 이미 없을 수
#    있는데 그 상황을 만들지 않았습니다."
#   "Query Store 를 안 썼습니다. 2016 이후로는 그쪽이 표준에 가까운데 DMV 만
#    다뤘습니다."
#
# 둘은 같은 이야기의 앞뒤다. **DMV 기반 진단의 한계가 곧 Query Store 를 쓰는 이유**다.
# 캐시가 비면 dm_exec_query_stats 는 아무것도 못 말하고, Query Store 는 디스크에
# 남아 있으므로 말한다. 그것을 나란히 확인한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
RUNS=${QS_RUNS:-60}

wait_ready || exit 2
setup_db || exit 2

# setup_db 가 표를 다시 만들므로 실험 3이 붙인 tag 컬럼이 없다. 여기서 붙인다.
# 처음에 안 붙이고 돌렸더니 부하 60회가 전부 Msg 207 로 죽었는데, 결과를
# /dev/null 로 버려서 **아무 일도 안 일어난 채로 표가 0 으로 채워졌다.**
# ALTER 와 UPDATE 를 한 배치에 두면 컴파일에서 죽으므로 나눠 던진다.
QD "IF COL_LENGTH('account_currency','tag') IS NULL
      ALTER TABLE account_currency ADD tag TINYINT NULL;" >/dev/null
QD "UPDATE account_currency SET tag = account_id % 3 WHERE tag IS NULL;" >/dev/null
HAS_TAG=$(num "$(QD "SELECT CASE WHEN COL_LENGTH('account_currency','tag') IS NULL
                                 THEN 'NO' ELSE 'YES' END")")
[ "$HAS_TAG" = "YES" ] || { echo "중단: tag 컬럼을 못 만들었습니다" >&2; exit 2; }

# 범인 쿼리. 실험 3과 같은 모양으로, 조인을 넣어 단순 매개 변수화를 막는다.
noisy(){ # $1=회수
  local i out bad=0
  for i in $(seq 1 "$1"); do
    out=$(QD "SET NOCOUNT ON;
        SELECT /*CULPRIT*/ COUNT(*)
          FROM account_currency a
          JOIN account_currency b ON b.account_id = a.account_id
         WHERE a.tag = $(( i % 3 ));")
    echo "$out" | grep -qE '^(Msg|메시지) [0-9]+' && bad=$(( bad + 1 ))
  done
  # 조용히 실패하면 표가 0 으로 차고 그것이 '캐시가 비었다'로 읽힌다.
  [ "$bad" = 0 ] || { echo "중단: 부하 ${bad}/${1} 회가 실패했습니다" >&2; return 2; }
}

dmv_count(){
  num "$(QD "SET NOCOUNT ON;
    SELECT CAST(COUNT(*) AS varchar(12)) FROM sys.dm_exec_query_stats qs
     CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
     WHERE t.text LIKE '%/*CULPRIT*/%';")"
}
dmv_reads(){
  num "$(QD "SET NOCOUNT ON;
    SELECT CAST(ISNULL(SUM(qs.total_logical_reads), 0) AS varchar(30))
      FROM sys.dm_exec_query_stats qs
     CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
     WHERE t.text LIKE '%/*CULPRIT*/%';")"
}
qs_count(){
  num "$(QD "SET NOCOUNT ON;
    SELECT CAST(COUNT(*) AS varchar(12))
      FROM sys.query_store_query q
      JOIN sys.query_store_query_text t ON t.query_text_id = q.query_text_id
     WHERE t.query_sql_text LIKE '%/*CULPRIT*/%';")"
}
qs_reads(){
  num "$(QD "SET NOCOUNT ON;
    SELECT CAST(ISNULL(SUM(rs.count_executions * rs.avg_logical_io_reads), 0) AS varchar(30))
      FROM sys.query_store_runtime_stats rs
      JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
      JOIN sys.query_store_query q ON q.query_id = p.query_id
      JOIN sys.query_store_query_text t ON t.query_text_id = q.query_text_id
     WHERE t.query_sql_text LIKE '%/*CULPRIT*/%';")"
}

{
echo "# 실험 4. 캐시가 비면 범인도 사라진다"
echo
echo "  실험 3은 계획 캐시로 범인을 찾았습니다. 그 방법에는 전제가 있습니다."
echo "  **계획이 캐시에 남아 있어야 합니다.** 사고가 지나간 뒤에 들여다보면"
echo "  이미 밀려났을 수 있는데, 그 상황을 안 만들어 봤습니다."
echo

echo "=================================================================="
echo "## 4-1. Query Store 를 켠다"
echo "=================================================================="
echo
QSOUT=$(Q "ALTER DATABASE [$DB] SET QUERY_STORE = ON;
           ALTER DATABASE [$DB] SET QUERY_STORE (
             OPERATION_MODE = READ_WRITE,
             DATA_FLUSH_INTERVAL_SECONDS = 60,
             INTERVAL_LENGTH_MINUTES = 1,
             QUERY_CAPTURE_MODE = ALL);")
QSMSG=$(echo "$QSOUT" | grep -oE '^(Msg|메시지) [0-9]+' | head -1)
[ -z "$QSMSG" ] || { echo "  중단: Query Store 를 못 켰습니다 ($QSMSG)"; echo "$QSOUT" | head -3; exit 2; }
QSSTATE=$(numsp "$(QD "SET NOCOUNT ON;
  SELECT actual_state_desc + ' / capture ' + query_capture_mode_desc
    FROM sys.database_query_store_options;")")
printf "  %-24s %s\n" "Query Store 상태" "${QSSTATE:-확인 못 함}"
echo
echo "  캡처 모드를 ALL 로 둡니다. 기본값 AUTO 는 가벼운 쿼리를 안 담는데,"
echo "  **조사에서 찾고 싶은 것이 늘 무거운 쿼리인 것은 아닙니다.**"
echo "  리터럴로 흩어진 쿼리는 하나하나가 가벼워서 AUTO 에서 빠질 수 있습니다."
echo

# 상태를 비우고 시작한다.
QD "ALTER DATABASE [$DB] SET QUERY_STORE CLEAR;" >/dev/null
Q "DBCC FREEPROCCACHE WITH NO_INFOMSGS;" >/dev/null

echo "=================================================================="
echo "## 4-2. 부하를 걸고 두 곳에서 본다"
echo "=================================================================="
echo
noisy "$RUNS" || exit 2
sleep 3
QD "EXEC sp_query_store_flush_db;" >/dev/null

: > "$OUT/query-store.csv"
echo "phase,dmv_plans,dmv_reads,qs_queries,qs_reads" >> "$OUT/query-store.csv"
printf "  %-30s %-14s %-16s %-14s %s\n" "시점" "DMV 계획" "DMV 논리읽기" "QS 쿼리" "QS 논리읽기"

snap(){ # $1=라벨
  local a b c d
  a=$(dmv_count); b=$(dmv_reads); c=$(qs_count); d=$(qs_reads)
  printf "  %-30s %-14s %-16s %-14s %s\n" "$1" "${a:-?}" "${b:-?}" "${c:-?}" "${d:-?}"
  echo "\"$1\",${a:-0},${b:-0},${c:-0},${d:-0}" >> "$OUT/query-store.csv"
  LAST="$a|$b|$c|$d"
}
snap "부하 직후"
BEFORE="$LAST"

echo
echo "=================================================================="
echo "## 4-3. 캐시가 비면"
echo "=================================================================="
echo
echo "  사고가 지나가고 시간이 흐르면 계획이 밀려납니다. 메모리 압박, 통계 갱신,"
echo "  인덱스 변경, 재시작이 전부 그 원인입니다. 여기서는 그 결과만 만듭니다."
echo
Q "DBCC FREEPROCCACHE WITH NO_INFOMSGS;" >/dev/null
sleep 2
snap "계획 캐시를 비운 뒤"
AFTER="$LAST"

IFS='|' read -r B_DMV B_DMVR B_QS B_QSR <<<"$BEFORE"
IFS='|' read -r A_DMV A_DMVR A_QS A_QSR <<<"$AFTER"

echo
if [ "${A_DMV:-0}" = "0" ] && [ "${A_QS:-0}" != "0" ]; then
  echo "  **DMV 쪽은 통째로 사라졌습니다.** ${B_DMV}개 계획, 논리 읽기 ${B_DMVR} 이"
  echo "  0 이 됐습니다. \`dm_exec_query_stats\` 는 이름 그대로 **캐시에 있는 계획의**"
  echo "  통계이고, 계획이 없어지면 통계도 함께 없어집니다."
  echo
  echo "  **Query Store 는 그대로 있습니다.** ${A_QS}개 쿼리, 논리 읽기 ${A_QSR}."
  echo "  디스크에 쓰기 때문입니다. 사고가 지나간 뒤에 들여다봐도 남아 있습니다."
elif [ "${A_DMV:-0}" != "0" ]; then
  echo "  **캐시를 비웠는데 DMV 에 아직 남아 있습니다(${A_DMV}개).** 비우는 것과"
  echo "  통계가 사라지는 것이 이 판에서는 같이 안 움직였습니다. 이 절은"
  echo "  판정할 수 없습니다."
else
  echo "  **양쪽 다 비었습니다.** Query Store 에도 안 남았습니다. 플러시가 안 됐거나"
  echo "  캡처가 안 된 것으로 보여 이 절은 판정할 수 없습니다."
fi
echo

echo "=================================================================="
echo "## 4-4. Query Store 가 대신 못 하는 것"
echo "=================================================================="
echo
echo "  그러면 DMV 를 버리고 Query Store 만 보면 되는가. **아닙니다.**"
echo
printf "  %-34s %-16s %s\n" "물어보는 것" "DMV" "Query Store"
qrow(){ printf "  %-34s %-16s %s\n" "$1" "$2" "$3"; echo "\"$1\",\"$2\",\"$3\",,," >> "$OUT/query-store.csv"; }
qrow "지금 무엇이 돌고 있나" "dm_exec_requests" "못 한다"
qrow "지금 누가 누구를 막고 있나" "dm_tran_locks" "못 한다"
qrow "지난 사고의 범인 쿼리" "캐시에 남아야" "**남아 있다**"
qrow "그때의 실행 계획" "밀려나면 없음" "**버전별로 보관**"
qrow "계획이 바뀌어 느려진 것" "못 본다" "**계획 회귀로 본다**"
echo
echo "  **Query Store 는 지난 일을 보는 도구이고 DMV 는 지금을 보는 도구입니다.**"
echo "  실험 2의 블로킹 사슬은 Query Store 로 못 찾습니다. 지금 누가 누구를 막고"
echo "  있는지는 저장되는 값이 아니기 때문입니다."
echo
echo "  그래서 순서가 이렇게 갈립니다."
echo "    사고가 **지금** 나고 있다        DMV. 대기 -> 사슬 -> 뿌리"
echo "    사고가 **지나갔다**              Query Store. 그 구간의 쿼리와 계획"
echo "    같은 쿼리가 **갑자기 느려졌다**  Query Store 의 계획 회귀"

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  실험 3의 방법에는 전제가 있었습니다. **계획이 캐시에 남아 있어야 합니다.**"
echo "  캐시를 비우자 ${B_DMV}개 계획과 논리 읽기 ${B_DMVR} 이 통째로 사라졌습니다."
echo "  사고 대응이 늦어지면 범인이 이미 없을 수 있습니다."
echo
echo "  **Query Store 는 그 자리를 메웁니다.** 디스크에 쓰므로 재시작에도 남고,"
echo "  구간별로 쪼개 두므로 \"어제 그 시간대\"를 물을 수 있습니다."
echo
echo "  다만 **대체재가 아니라 짝**입니다. 지금 누가 막고 있는지는 Query Store 가"
echo "  모릅니다. 진단 순서에서 DMV 는 앞자리, Query Store 는 뒷자리입니다."
echo
echo "  켤 때 주의할 것이 하나 있습니다. **캡처 모드 기본값 AUTO 는 가벼운 쿼리를"
echo "  안 담습니다.** 실험 3에서 본 리터럴로 흩어진 범인은 하나하나가 가벼워서"
echo "  그 그물에서 빠질 수 있습니다. 그런 조사를 할 생각이면 ALL 로 둡니다."
} 2>&1 | tee "$OUT/exp4-query-store.txt"
