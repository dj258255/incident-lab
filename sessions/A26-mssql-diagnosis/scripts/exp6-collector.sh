#!/usr/bin/env bash
# 실험 6. 사고가 난 뒤에 스냅샷을 뜨면 이미 늦다.
#
# 못 한 것에 이렇게 적었다.
#   "자동 수집을 만들지 않았습니다. 사고가 난 뒤에 스냅샷을 뜨면 이미 늦습니다.
#    주기적으로 떠 두는 수집기가 있어야 하는데 만들지 않았습니다."
#
# 실험 1의 처방은 "사고가 의심되면 먼저 스냅샷을 뜨고 몇 분 뒤 다시 뜬다"였다.
# **그 처방은 사고가 아직 진행 중일 때만 통한다.** 신고가 늦게 오거나 이미 끝난
# 뒤에 들여다보면 기준으로 삼을 앞 스냅샷이 없다.
#
# 여기서 확인할 것이 셋이다.
#   1 수집기가 없으면 지난 사고를 못 잰다        기준이 없다
#   2 수집기가 있으면 잰다                        구간을 골라 차분한다
#   3 수집기 자체가 얼마나 무거운가              들여다보는 값이 비싸면 못 켠다
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
TICKS=${TICKS:-8}          # 수집 회차
INCIDENT_AT=${INCIDENT_AT:-4}   # 몇 번째 회차 뒤에 사고를 낼지

wait_ready || exit 2
setup_db || exit 2

IGNORE="$IDLE_WAITS"

{
echo "# 실험 6. 사고가 지나간 뒤에도 재려면"
echo
echo "  실험 1의 처방은 \"사고가 의심되면 먼저 스냅샷을 뜨고 몇 분 뒤 다시 뜬다\"였습니다."
echo "  **그것은 사고가 아직 진행 중일 때만 통합니다.** 신고가 늦게 오거나 이미 끝난"
echo "  뒤에 들여다보면 기준으로 삼을 앞 스냅샷이 없습니다."
echo

echo "=================================================================="
echo "## 6-1. 수집기를 만든다"
echo "=================================================================="
echo
QDX "SET NOCOUNT ON;
DROP TABLE IF EXISTS diag_wait_snap;
CREATE TABLE diag_wait_snap (
    tick        INT           NOT NULL,
    taken_at    DATETIME2(3)  NOT NULL DEFAULT SYSDATETIME(),
    wait_type   NVARCHAR(60)  NOT NULL,
    wait_ms     BIGINT        NOT NULL,
    tasks       BIGINT        NOT NULL,
    CONSTRAINT PK_diag_wait_snap PRIMARY KEY (tick, wait_type)
);" || exit 2

QF "SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
CREATE OR ALTER PROCEDURE usp_CollectWaits @tick INT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO diag_wait_snap (tick, wait_type, wait_ms, tasks)
    SELECT @tick, wait_type, wait_time_ms, waiting_tasks_count
      FROM sys.dm_os_wait_stats
     WHERE wait_type NOT IN ($IGNORE)
       AND wait_time_ms > 0;
END
GO" >/dev/null
echo "  누적값을 회차마다 그대로 적습니다. **차분은 읽을 때 냅니다.**"
echo "  수집할 때 차분을 내면 회차 사이의 재시작을 못 가르고, 구간을 나중에"
echo "  다시 고를 수도 없습니다."
echo

echo "=================================================================="
echo "## 6-2. 사고를 중간에 끼워 넣고 돌린다"
echo "=================================================================="
echo
: > "$OUT/collector.csv"
echo "tick,rows,top_wait,delta_ms" >> "$OUT/collector.csv"
printf "  %-8s %-14s %-30s %s\n" "회차" "수집 행" "직전 회차 대비 상위" "비고"

incident(){
  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
    -Q "SET NOCOUNT ON; BEGIN TRAN; UPDATE account_currency SET balance = balance + 1;
        WAITFOR DELAY '00:00:06'; ROLLBACK;" >/dev/null 2>&1 &
  local bg=$!
  sleep 2
  QD "SET NOCOUNT ON; SELECT COUNT(*) FROM account_currency WHERE account_id <= 100;" >/dev/null
  wait "$bg" 2>/dev/null
}

for T in $(seq 1 "$TICKS"); do
  QD "EXEC usp_CollectWaits @tick = $T;" >/dev/null
  N=$(num "$(QD "SELECT COUNT(*) FROM diag_wait_snap WHERE tick = $T")")
  TOP="-"
  if [ "$T" -gt 1 ]; then
    TOP=$(numsp "$(QD "SET NOCOUNT ON;
      SELECT TOP 1 b.wait_type + ' ' + CAST(b.wait_ms - a.wait_ms AS varchar(20)) + 'ms'
        FROM diag_wait_snap b
        JOIN diag_wait_snap a ON a.wait_type = b.wait_type AND a.tick = $(( T - 1 ))
       WHERE b.tick = $T AND b.wait_ms - a.wait_ms > 0
       ORDER BY b.wait_ms - a.wait_ms DESC;")")
  fi
  NOTE=""
  printf "  %-8s %-14s %-30s %s\n" "$T" "$N" "${TOP:-없음}" "$NOTE"
  echo "$T,$N,\"${TOP:-없음}\",0" >> "$OUT/collector.csv"
  if [ "$T" = "$INCIDENT_AT" ]; then
    echo "    (여기서 사고가 납니다. 20만 행 갱신이 조회를 막습니다)"
    incident
  else
    sleep 1
  fi
done

echo
echo "=================================================================="
echo "## 6-3. 지난 구간을 골라 차분한다"
echo "=================================================================="
echo
echo "  사고가 끝난 뒤에 들여다봅니다. 수집기가 있으면 **어느 두 회차든 골라**"
echo "  그 사이만 볼 수 있습니다."
echo
FROM=$(( INCIDENT_AT ))
TO=$(( INCIDENT_AT + 1 ))
echo "  ${FROM}회차와 ${TO}회차 사이(사고 구간):"
QD "SET NOCOUNT ON;
    SELECT TOP 3 '    ' + b.wait_type + ' ' + CAST(b.wait_ms - a.wait_ms AS varchar(20)) + 'ms'
      FROM diag_wait_snap b
      JOIN diag_wait_snap a ON a.wait_type = b.wait_type AND a.tick = $FROM
     WHERE b.tick = $TO AND b.wait_ms - a.wait_ms > 0
     ORDER BY b.wait_ms - a.wait_ms DESC;" | grep -E '^\s+[A-Z_]'
echo
Q1=$(( TICKS - 1 )); Q2=$TICKS
echo "  ${Q1}회차와 ${Q2}회차 사이(사고가 아닌 구간):"
QD "SET NOCOUNT ON;
    SELECT TOP 3 '    ' + b.wait_type + ' ' + CAST(b.wait_ms - a.wait_ms AS varchar(20)) + 'ms'
      FROM diag_wait_snap b
      JOIN diag_wait_snap a ON a.wait_type = b.wait_type AND a.tick = $Q1
     WHERE b.tick = $Q2 AND b.wait_ms - a.wait_ms > 0
     ORDER BY b.wait_ms - a.wait_ms DESC;" | grep -E '^\s+[A-Z_]' || echo "    (늘어난 대기 없음)"
echo
echo "  전체 누적으로 보면(실험 1이 지적한 그 문제):"
QD "SET NOCOUNT ON;
    SELECT TOP 3 '    ' + wait_type + ' ' + CAST(wait_ms AS varchar(20)) + 'ms'
      FROM diag_wait_snap WHERE tick = $TICKS ORDER BY wait_ms DESC;" | grep -E '^\s+[A-Z_]'
echo
echo "  **누적으로 보면 사고 구간이 안 보입니다.** 인스턴스가 뜬 뒤 전부가 섞여"
echo "  있어서 이번 사고의 크기를 실제보다 크게 봅니다. 수집기가 있으면 그 구간만"
echo "  떼어 볼 수 있고, **사고가 끝난 뒤에도 됩니다.**"
echo

echo "=================================================================="
echo "## 6-4. 수집기 자체가 얼마나 무거운가"
echo "=================================================================="
echo
ROWS_PER=$(num "$(QD "SELECT CAST(AVG(c) AS varchar(12)) FROM (SELECT COUNT(*) AS c FROM diag_wait_snap GROUP BY tick) q")")
TOTAL=$(num "$(QD "SELECT COUNT(*) FROM diag_wait_snap")")
SIZE_KB=$(num "$(QD "SET NOCOUNT ON;
  SELECT CAST(SUM(a.total_pages) * 8 AS varchar(20))
    FROM sys.partitions p JOIN sys.allocation_units a ON a.container_id = p.partition_id
   WHERE p.object_id = OBJECT_ID('diag_wait_snap');")")
READS=$(num "$(QD "SET NOCOUNT ON;
  SET STATISTICS IO ON;
  EXEC usp_CollectWaits @tick = 999;
  SET STATISTICS IO OFF;" | grep -oE '(logical reads|논리적 읽기 수) [0-9]+' | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')")
QD "DELETE FROM diag_wait_snap WHERE tick = 999;" >/dev/null

printf "  %-30s %s\n" "회차당 수집 행" "$ROWS_PER"
printf "  %-30s %s\n" "${TICKS}회차 누적" "${TOTAL}행 / ${SIZE_KB}KB"
printf "  %-30s %s\n" "한 번 수집의 논리 읽기" "${READS:-0}"
echo
DAY=$(python3 -c "print(int(${ROWS_PER:-0}) * 24 * 60)")
YEAR_MB=$(python3 -c "print(f'{int(${SIZE_KB:-0})/max(1,${TOTAL:-1})*${DAY}*365/1024:.0f}')")
printf "  %-30s %s\n" "1분마다 뜨면 하루" "약 ${DAY}행"
printf "  %-30s %s\n" "그대로 1년 쌓으면" "약 ${YEAR_MB}MB"
echo
KEEP30=$(python3 -c "print(f'{int(${SIZE_KB:-0})/max(1,${TOTAL:-1})*${DAY}*30/1024:.0f}')")
printf "  %-30s %s\\n" "30일만 보존하면" "약 ${KEEP30}MB"
echo
echo "  **한 번 수집이 논리 읽기 ${READS:-0} 입니다.** 읽는 것이 DMV 한 개뿐이라"
echo "  1분 주기로 켜 둬도 부담이 안 됩니다."
echo
echo "  대신 **보존 기간을 안 정하면 쌓입니다.** 1분 주기로 1년이면 ${YEAR_MB}MB 이고,"
echo "  30일만 남기면 ${KEEP30}MB 입니다. 수집기를 만들 때 지우는 작업을 같이 만듭니다."
echo "  들여다보는 값이 비싸면 못 켜는데 이것은 그 걱정이 없고, **관리 안 하면 쌓이는"
echo "  쪽**이 문제입니다."

QD "DROP PROCEDURE IF EXISTS usp_CollectWaits; DROP TABLE IF EXISTS diag_wait_snap;" >/dev/null

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  실험 1의 \"두 번 떠서 차분\"에는 **사고가 진행 중이어야 한다**는 전제가"
echo "  있었습니다. 신고가 늦으면 기준으로 삼을 앞 스냅샷이 없습니다."
echo
echo "  수집기를 주기적으로 돌려 두면 그 전제가 없어집니다. 누적값을 회차마다"
echo "  그대로 적어 두고 **읽을 때 구간을 골라 차분**하면, 사고가 끝난 뒤에도"
echo "  그 구간만 떼어 볼 수 있습니다."
echo
echo "  설계에서 정한 것 둘입니다."
echo
echo "    누적값을 그대로 적는다. 수집할 때 차분을 내면 구간을 다시 못 고르고"
echo "    회차 사이의 재시작(누적값이 0 으로 돌아가는 것)도 못 가른다"
echo
echo "    유휴 대기는 **읽을 때가 아니라 담을 때** 뺀다. 담아 두면 표가 커지고"
echo "    매번 같은 것을 걸러야 한다"
echo
echo "  운영에서는 SQL Server 에이전트 작업으로 1분마다 돌리고, 보존 기간이 지난"
echo "  회차를 지우는 정리를 함께 겁니다. Query Store(실험 4)가 쿼리 쪽을 맡는다면"
echo "  이것은 **대기 쪽을 맡습니다.** 둘 다 \"지난 일을 보는\" 자리입니다."
} 2>&1 | tee "$OUT/exp6-collector.txt"
