#!/usr/bin/env bash
# A04 공용 헬퍼. 각 실험 스크립트가 source 한다.
PW='Lab_Passw0rd!'
DB=lostark_lab
TBL=expedition_currency
CT=a04-mssql
SQLCMD=/opt/mssql-tools18/bin/sqlcmd

# -h -1 헤더 없음, -W 좌우 공백 제거. 오류도 stdout 으로 받아 호출부가 볼 수 있게 한다.
Q(){  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -Q "$1" 2>&1; }
QD(){ docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" -Q "$1" 2>&1; }
# 파일로 심어 실행한다. XML 메서드는 QUOTED_IDENTIFIER ON 이 필요한데 -Q 는 그 설정을
# 켜 주지 않아서, 파일 안에서 SET 을 먼저 하고 -i 로 돌린다.
QF(){ # $1=로컬 SQL 내용, $2=옵션
  docker exec -i "$CT" sh -c "cat > /tmp/a04q.sql" <<<"$1"
  local n; n=$(docker exec "$CT" sh -c 'wc -l < /tmp/a04q.sql' | tr -d ' \r')
  # docker exec 에 -i 를 빠뜨리면 표준입력이 안 들어가고 빈 파일이 남는다(CONVENTIONS §8).
  [ "${n:-0}" -gt 0 ] || { echo "중단: SQL 파일이 비었습니다" >&2; return 2; }
  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 ${2:--W} -i /tmp/a04q.sql 2>&1
}

num(){ echo "$1" | head -1 | tr -d ' \r'; }

wait_ready(){
  local i
  for i in $(seq 1 150); do
    # 준비 확인의 패턴이 질의문에 있으면 실패 출력이 그것을 그대로 돌려준다(CONVENTIONS §11).
    [ "$(num "$(Q "SELECT 'RE'+'ADY'")")" = "READY" ] && return 0
    sleep 2
  done
  echo "중단: $CT 가 쿼리를 못 받습니다" >&2; return 2
}

# 이 랩의 전제를 서버에 되물어 확인한다. 바꿨다고 믿는 값을 확인한다는 규칙.
assert_env(){
  local oc
  # optimized locking 은 2025 에서 들어왔다. 2022 에는 컬럼 자체가 없다.
  # 있는데 켜져 있으면 이 실험은 성립하지 않으므로 멈춘다.
  # 없는 컬럼을 직접 참조하면 도달하지 않는 분기라도 컴파일에서 죽는다(Msg 207).
  # 그래서 존재 확인은 카탈로그 뷰로 하고, 읽기는 동적 SQL 로 미룬다.
  oc=$(num "$(Q "IF NOT EXISTS (SELECT 1 FROM sys.all_columns c
                                  JOIN sys.all_objects o ON o.object_id = c.object_id
                                 WHERE o.name = 'databases' AND c.name = 'is_optimized_locking_on')
                   SELECT 'ABSENT'
                 ELSE
                   EXEC sp_executesql N'SELECT CASE WHEN is_optimized_locking_on = 1 THEN ''ON'' ELSE ''OFF'' END
                                          FROM sys.databases WHERE name = ''$DB'''")")
  case "$oc" in
    ABSENT|OFF) ;;
    *) echo "중단: optimized locking 이 $oc 입니다. 켜져 있으면 에스컬레이션이 안 일어납니다" >&2; return 2 ;;
  esac
  echo "$oc"
}

# 테이블을 처음부터 다시 만든다. 조건 간 상태 누수를 막는다(CONVENTIONS §11).
reset_table(){
  local rows=${1:-200000} got
  Q "IF DB_ID('$DB') IS NULL CREATE DATABASE [$DB]" >/dev/null
  QD "SET NOCOUNT ON;
      DROP TABLE IF EXISTS $TBL;
      CREATE TABLE $TBL (
        account_id    INT      NOT NULL PRIMARY KEY,
        currency_type TINYINT  NOT NULL,
        balance       BIGINT   NOT NULL
      );
      WITH n AS (SELECT TOP ($rows) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
                 FROM sys.all_objects a CROSS JOIN sys.all_objects b)
      INSERT INTO $TBL (account_id, currency_type, balance)
      SELECT i, i % 3, 100000 FROM n;" >/dev/null
  got=$(num "$(QD "SELECT COUNT(*) FROM $TBL")")
  # 적재 없는 표가 그대로 분모가 되는 사고를 막는다. 기대값이 정해지므로 -ne 로 본다.
  [ "$got" = "$rows" ] || { echo "중단: 적재가 ${got}행입니다(기대 ${rows})" >&2; return 2; }
  # 통계를 만들어 두고 시작한다. 이것이 없으면 옵티마이저가 갱신량을 크게 추정해
  # 행 락 대신 처음부터 테이블 락을 잡는다. 그러면 같은 행 수에서 어떤 회차는
  # 승격하고 어떤 회차는 "승격 없이 테이블 락"이 되어 경계가 흔들린다(실험 5).
  QD "UPDATE STATISTICS $TBL WITH FULLSCAN" >/dev/null
}

# 한 트랜잭션에서 N행을 갱신했을 때의 락 구조를 돌려준다.
# "승격여부,KEY락,PAGE락,테이블락합계"
#
# 마지막 값에서 DATABASE 락은 뺀다. 승격 여부를 가르는 것은 **한 테이블 참조에
# 걸린 락**이고 DATABASE 락은 그 대상이 아니다. 처음엔 전부 세다가 엔진이 보고한
# escalated_lock_count 와 정확히 1 이 어긋났고, 그 1 이 DATABASE S 락이었다.
lock_shape(){
  local n=$1
  num "$(QD "SET NOCOUNT ON;
    BEGIN TRAN;
    UPDATE TOP ($n) $TBL SET balance = balance - 1;
    SELECT CAST(SUM(CASE WHEN resource_type='OBJECT' AND request_mode='X' THEN 1 ELSE 0 END) AS varchar(4))
         + ',' + CAST(SUM(CASE WHEN resource_type='KEY'  THEN 1 ELSE 0 END) AS varchar(10))
         + ',' + CAST(SUM(CASE WHEN resource_type='PAGE' THEN 1 ELSE 0 END) AS varchar(10))
         + ',' + CAST(SUM(CASE WHEN resource_type <> 'DATABASE' THEN 1 ELSE 0 END) AS varchar(10))
      FROM sys.dm_tran_locks WHERE request_session_id = @@SPID;
    ROLLBACK;")"
}

xe_reset(){
  Q "IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name='a04_esc')
       DROP EVENT SESSION a04_esc ON SERVER;
     CREATE EVENT SESSION a04_esc ON SERVER
       ADD EVENT sqlserver.lock_escalation
       ADD TARGET package0.ring_buffer WITH (MAX_MEMORY=4096 KB);
     ALTER EVENT SESSION a04_esc ON SERVER STATE = START;" >/dev/null
}

# 링버퍼에 쌓인 승격 이벤트를 한 줄씩 돌려준다. "escalated_lock_count|cause|mode"
xe_events(){
  QF "SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SELECT CAST(n.value('(data[@name=\"escalated_lock_count\"]/value)[1]','int') AS varchar(12))
     + '|' + n.value('(data[@name=\"escalation_cause\"]/text)[1]','varchar(40)')
     + '|' + n.value('(data[@name=\"mode\"]/text)[1]','varchar(10)')
FROM (SELECT CAST(t.target_data AS xml) x
        FROM sys.dm_xe_sessions s
        JOIN sys.dm_xe_session_targets t ON t.event_session_address = s.address
       WHERE s.name='a04_esc' AND t.target_name='ring_buffer') q
CROSS APPLY x.nodes('RingBufferTarget/event') e(n);" | grep -E '^[0-9]+\|' || true
}

xe_count(){ xe_events | grep -c . || true; }
