#!/usr/bin/env bash
# A26 공용 헬퍼.
PW='Lab_Passw0rd!'
DB=lostark_ops
CT=a26-mssql
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
ROWS=${ROWS:-300000}

Q(){  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -Q "$1" 2>&1; }
QD(){ docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" -Q "$1" 2>&1; }
QF(){
  docker exec -i "$CT" sh -c "cat > /tmp/a26q.sql" <<<"$1"
  local n; n=$(docker exec "$CT" sh -c 'wc -l < /tmp/a26q.sql' | tr -d ' \r')
  [ "${n:-0}" -gt 0 ] || { echo "중단: SQL 파일이 비었습니다" >&2; return 2; }
  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" -i /tmp/a26q.sql 2>&1
}
num(){ echo "$1" | head -1 | tr -d ' \r'; }

# 값 안의 공백을 살려야 하는 자리에 쓴다. num 은 내부 공백까지 지우므로
# '2026-08-09 08:10:00.787' 이 '2026-08-0908:10:00.787' 이 된다.
# A25 에서 이것 때문에 STOPAT 이 Msg 3217 로 죽었고 "시각 복원이 안 된다"고
# 결론 낼 뻔했다. 여기서는 화면에만 나오지만 같은 함수를 쓰면 같은 자국이 남는다.
numsp(){ echo "$1" | head -1 | sed 's/[[:space:]]*$//; s/\r//g'; }
QDX(){
  local out; out=$(QD "$1")
  if echo "$out" | grep -qE '^(Msg|메시지) [0-9]+'; then
    echo "중단: SQL 오류" >&2; echo "$out" | grep -E '^(Msg|메시지)' | head -3 >&2; return 2
  fi
  return 0
}
wait_ready(){
  local i
  for i in $(seq 1 150); do
    [ "$(num "$(Q "SELECT 'RE'+'ADY'")")" = "READY" ] && return 0
    sleep 2
  done
  echo "중단: $CT 가 쿼리를 못 받습니다" >&2; return 2
}
setup_db(){
  Q "IF DB_ID('$DB') IS NULL CREATE DATABASE [$DB]" >/dev/null
  QDX "SET NOCOUNT ON;
  DROP TABLE IF EXISTS account_currency;
  CREATE TABLE account_currency (
      account_id INT NOT NULL PRIMARY KEY,
      balance    BIGINT NOT NULL
  );
  WITH n AS (SELECT TOP ($ROWS) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
               FROM sys.all_objects a CROSS JOIN sys.all_objects b)
  INSERT INTO account_currency WITH (TABLOCK) (account_id, balance)
  SELECT i, 100000 FROM n;
  UPDATE STATISTICS account_currency WITH FULLSCAN;" || return 2
  local got; got=$(num "$(QD "SELECT COUNT(*) FROM account_currency")")
  [ "$got" = "$ROWS" ] || { echo "중단: 적재가 ${got}행입니다(기대 ${ROWS})" >&2; return 2; }
}

# 유휴 대기 무시 목록.
#
# 실험 1에서 이 목록이 부실해 SOS_WORK_DISPATCHER 가 상위를 덮고 사고가 만든
# LCK_M_IS 가 3위 밖으로 밀렸다. 그러고도 실험 6에서 **짧은 목록을 따로 만들어**
# 같은 실수를 반복했다. HADR_FILESTREAM_IOMGR_IOCOMPLETION 과
# SQLTRACE_INCREMENTAL_FLUSH_SLEEP 이 상위를 덮었다.
# 목록을 한 곳에 두고 전부 여기서 가져다 쓴다.
IDLE_WAITS="'SLEEP_TASK','BROKER_TASK_STOP','SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
 'LAZYWRITER_SLEEP','XE_TIMER_EVENT','XE_DISPATCHER_WAIT','FT_IFTS_SCHEDULER_IDLE_WAIT',
 'BROKER_TO_FLUSH','CLR_AUTO_EVENT','CLR_MANUAL_EVENT','REQUEST_FOR_DEADLOCK_SEARCH',
 'LOGMGR_QUEUE','CHECKPOINT_QUEUE','BROKER_EVENTHANDLER','SLEEP_BPOOL_FLUSH',
 'DIRTY_PAGE_POLL','HADR_FILESTREAM_IOMGR_IOCOMPLETION','SP_SERVER_DIAGNOSTICS_SLEEP',
 'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP','QDS_ASYNC_QUEUE','QDS_SHUTDOWN_QUEUE',
 'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP','WAIT_XTP_HOST_WAIT',
 'WAIT_XTP_OFFLINE_CKPT_NEW_LOG','WAIT_XTP_CKPT_CLOSE','PREEMPTIVE_XE_GETTARGETSTATE',
 'SOS_WORK_DISPATCHER','DISPATCHER_QUEUE_SEMAPHORE','ONDEMAND_TASK_QUEUE',
 'PWAIT_EXTENSIBILITY_CLEANUP_TASK','AZURE_IMDS_VERSIONS','PARALLEL_REDO_DRAIN_WORKER',
 'PARALLEL_REDO_LOG_CACHE','PARALLEL_REDO_TRAN_LIST','PARALLEL_REDO_WORKER_SYNC',
 'PARALLEL_REDO_WORKER_WAIT_WORK','PREEMPTIVE_OS_FLUSHFILEBUFFERS','WAITFOR',
 'BROKER_RECEIVE_WAITFOR','HADR_WORK_QUEUE','HADR_TIMER_TASK','HADR_CLUSAPI_CALL',
 'PREEMPTIVE_HADR_LEASE_MECHANISM','SLEEP_SYSTEMTASK','SLEEP_DBSTARTUP'"
