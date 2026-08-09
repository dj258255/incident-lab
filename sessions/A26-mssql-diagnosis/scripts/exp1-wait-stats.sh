#!/usr/bin/env bash
# 실험 1. 대기 통계로 원인 유형을 좁힌다. 그리고 그것이 왜 조용히 틀리는가.
#
# 서비스가 느려졌다는 신고가 들어왔다. 어디부터 보는가. 정석은 대기 통계다.
# 세션들이 무엇을 기다리고 있었는지 인스턴스 단위로 누적돼 있다.
#
# 그런데 sys.dm_os_wait_stats 는 **인스턴스가 뜬 뒤로 계속 더해진 값**이다.
# 그대로 읽으면 지금 무슨 일이 나는지가 아니라 어제까지의 평균을 본다.
# 지금 나는 사고는 그 안에 묻힌다.
#
# 그래서 스냅샷을 두 번 떠 차분을 본다. 그 차이를 실측한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
HOLD=${HOLD:-20}

wait_ready || exit 2
setup_db || exit 2

# 무시할 대기 유형. 시스템이 놀 때 쌓는 것들이라 섞으면 진짜 원인이 안 보인다.
IGNORE="'SLEEP_TASK','BROKER_TASK_STOP','SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
        'LAZYWRITER_SLEEP','XE_TIMER_EVENT','XE_DISPATCHER_WAIT','REQUEST_FOR_DEADLOCK_SEARCH',
        'LOGMGR_QUEUE','CHECKPOINT_QUEUE','CLR_AUTO_EVENT','CLR_MANUAL_EVENT','DIRTY_PAGE_POLL',
        'HADR_FILESTREAM_IOMGR_IOCOMPLETION','SP_SERVER_DIAGNOSTICS_SLEEP','QDS_ASYNC_QUEUE',
        'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP','QDS_SHUTDOWN_QUEUE','WAIT_XTP_HOST_WAIT',
        'BROKER_TO_FLUSH','BROKER_EVENTHANDLER','FT_IFTS_SCHEDULER_IDLE_WAIT','SLEEP_SYSTEMTASK',
        'WAITFOR','PREEMPTIVE_OS_FLUSHFILEBUFFERS','PREEMPTIVE_OS_WRITEFILEGATHER',
        -- 아래 셋은 처음 목록에서 빠져 있었다. 그대로 돌렸더니 유휴 대기가 상위를
        -- 전부 차지해 사고가 만든 LCK_M_IS 가 묻혔다. 무시 목록이 부실하면 차분을
        -- 떠도 소용없다는 것을 이 실험이 스스로 밟았다.
        'SOS_WORK_DISPATCHER','DISPATCHER_QUEUE_SEMAPHORE','ONDEMAND_TASK_QUEUE'"

snap(){ # 대기 통계를 임시 표에 뜬다
  QDX "SET NOCOUNT ON;
  DROP TABLE IF EXISTS $1;
  SELECT wait_type, waiting_tasks_count, wait_time_ms
    INTO $1
    FROM sys.dm_os_wait_stats
   WHERE wait_type NOT IN ($IGNORE);"
}

top_waits(){ # $1=기준 스냅샷(없으면 누적 전체)
  local sql
  if [ -z "$1" ]; then
    sql="SELECT TOP 3 wait_type + '  ' + CAST(wait_time_ms AS varchar(20)) + 'ms'
           FROM sys.dm_os_wait_stats
          WHERE wait_type NOT IN ($IGNORE) AND wait_time_ms > 0
          ORDER BY wait_time_ms DESC;"
  else
    sql="SELECT TOP 3 c.wait_type + '  ' + CAST(c.wait_time_ms - ISNULL(b.wait_time_ms,0) AS varchar(20)) + 'ms'
           FROM sys.dm_os_wait_stats c
           LEFT JOIN $1 b ON b.wait_type = c.wait_type
          WHERE c.wait_type NOT IN ($IGNORE)
            AND c.wait_time_ms - ISNULL(b.wait_time_ms,0) > 0
          ORDER BY c.wait_time_ms - ISNULL(b.wait_time_ms,0) DESC;"
  fi
  QD "SET NOCOUNT ON; $sql" | grep -vE '^$|^Msg|^메시지'
}

{
echo "# 실험 1. 대기 통계는 누적이라 지금을 못 본다"
echo
echo "  계정 ${ROWS}개. 보정 배치가 도는 동안 대기가 어떻게 쌓이는지 봅니다."
echo

echo "## 1-1. 사고 전에 누적된 대기"
echo
echo "  인스턴스를 띄우고 데이터를 적재한 직후입니다. 아직 사고는 없습니다."
echo
top_waits "" | sed 's/^/    /'
echo
echo "  적재 자체가 만든 대기가 쌓여 있습니다. 이 위에 사고가 얹힙니다."
echo

echo "## 1-2. 사고를 만든다"
snap "#base" >/dev/null 2>&1
QD "SET NOCOUNT ON; DROP TABLE IF EXISTS wait_base;
    SELECT wait_type, waiting_tasks_count, wait_time_ms INTO wait_base
      FROM sys.dm_os_wait_stats WHERE wait_type NOT IN ($IGNORE);" >/dev/null
# 보정 배치가 테이블을 잡고 버틴다. 그 사이 조회들이 줄을 선다.
docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
  -Q "SET NOCOUNT ON; BEGIN TRAN;
      UPDATE account_currency WITH (TABLOCKX) SET balance = balance - 1;
      WAITFOR DELAY '00:00:${HOLD}';
      ROLLBACK;" >/dev/null 2>&1 &
HOLDER=$!
sleep 3
for i in $(seq 1 6); do
  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
    -Q "SELECT balance FROM account_currency WHERE account_id = 1" >/dev/null 2>&1 &
done
wait "$HOLDER" 2>/dev/null
sleep 1
echo "  보정 배치가 테이블을 ${HOLD}초 잡고, 그 사이 조회 6건이 줄을 섰습니다."
echo

echo "## 1-3. 누적으로 보면 vs 차분으로 보면"
echo
echo "  누적 전체 상위 3개:"
top_waits "" | sed 's/^/    /'
echo
echo "  사고 구간 차분 상위 3개:"
top_waits "wait_base" | sed 's/^/    /'
echo

CUM=$(top_waits "" | head -1 | awk '{print $1}')
CUMV=$(top_waits "" | head -1 | awk '{print $2}' | tr -d 'ms')
DIF=$(top_waits "wait_base" | head -1 | awk '{print $1}')
DIFV=$(top_waits "wait_base" | head -1 | awk '{print $2}' | tr -d 'ms')
{ echo "view,top_wait,wait_time_ms"
  echo "cumulative,$CUM,$CUMV"
  echo "delta,$DIF,$DIFV"; } > "$OUT/wait-stats.csv"

echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
if [ "$CUM" != "$DIF" ]; then
  echo "  **누적 1위(${CUM})와 사고 구간 1위(${DIF})가 다릅니다.** 누적을 그대로 읽으면"
  echo "  지금 나는 사고가 아니라 인스턴스가 뜬 뒤로 쌓인 평균을 봅니다."
else
  echo "  누적 1위와 차분 1위가 ${CUM} 로 같습니다. 유형은 같은데 **크기가 다릅니다.**"
  echo
  printf "    %-22s %s ms\n" "누적" "$CUMV"
  printf "    %-22s %s ms\n" "이번 사고가 만든 것" "$DIFV"
  echo
  echo "  나머지는 앞선 실행들이 남긴 것입니다. 이 랩은 같은 스크립트를 여러 번 돌려"
  echo "  그렇지만, 운영에서는 어제 사고와 지난주 배치가 거기 섞여 있습니다."
  echo "  **누적만 보면 이번 사고의 크기를 실제보다 크게 봅니다.** 원인 유형이 우연히"
  echo "  같아도 크기를 잘못 읽으면 대응 규모를 잘못 잡습니다."
fi
echo
echo "  그래서 대기 통계는 **두 번 떠서 차분**으로 봅니다. 사고가 의심되면 먼저"
echo "  스냅샷을 뜨고, 몇 분 뒤 다시 떠서 그 사이에 늘어난 것만 봅니다."
echo
echo "  DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR) 로 초기화하는 방법도 있지만"
echo "  운영에서는 쓰지 않습니다. 다른 사람이 보고 있던 기준이 사라집니다."
echo
echo "  **무시 목록이 부실하면 차분을 떠도 소용없습니다.** 이 실험을 처음 돌렸을 때"
echo "  SOS_WORK_DISPATCHER 와 DISPATCHER_QUEUE_SEMAPHORE 가 상위를 전부 차지해"
echo "  사고가 만든 LCK_M_IS 가 3위 밖으로 밀려 있었습니다. 둘 다 시스템이 놀 때"
echo "  쌓는 대기라 사고와 무관합니다. 목록에 넣고서야 신호가 보였습니다."
echo
echo "  운영에서는 잘 알려진 무시 목록을 쓰되, 처음 보는 대기 유형이 상위에 오면"
echo "  그것이 진짜인지 유휴인지부터 확인합니다. 유휴를 안 빼면 매번 같은 것이"
echo "  1위로 나와 대기 통계가 쓸모없어집니다."
} 2>&1 | tee "$OUT/exp1-wait-stats.txt"
