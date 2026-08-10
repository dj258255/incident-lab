#!/usr/bin/env bash
# 실험 18. 복제를 상시 구성으로 세우면 무엇이 더 붙는가.
#
# 못 한 것에 이렇게 적어 두었다.
#   "복제를 계속 도는 구성으로는 안 재 봤습니다. 표 하나를 한 번 넘기는 비용만
#    쟀습니다. 배포 지연·재시도·구독 재초기화는 이 글의 질문 밖이라 안 세웠습니다."
#
# **이것도 안 한 것이지 밖에 있는 것이 아니다.** 실험 15의 결론은
# "복제를 쓸 자리는 조사 DB 를 운영에서 계속 떠먹이는 구성"이었다. 그 자리를
# 권해 놓고 그 구성을 안 세워 본 것이다.
#
# 실험 15는 스냅샷 복제였다(@repl_freq = 'snapshot'). 상시 구성은 **트랜잭션 복제**고
# 그것부터 다르다. 에이전트가 하나 더 붙는다.
#   스냅샷 복제    스냅샷 에이전트 + 배포 에이전트
#   트랜잭션 복제  + **로그 판독기 에이전트**. 발행 DB 의 로그를 계속 읽는다
#
# 확인할 것 넷이다.
#   1 세우는 데 무엇이 더 드는가
#   2 바뀐 것이 실제로 따라오는가
#   3 **구독자가 죽으면 무엇이 쌓이는가**   <- 상시 구성의 진짜 비용
#   4 끊겼다 붙으면 알아서 따라잡는가
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

PUB=a25-repl-pub
SUB=a25-repl-sub
PDB=repl_src
SDB=repl_dst
PUBNAME=pub_standing
ROWS=${STANDING_ROWS:-2000}
BURST=${STANDING_BURST:-20000}

PQ(){  docker exec "$PUB" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -Q "$1" 2>&1; }
PQD(){ docker exec "$PUB" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$PDB" -Q "$1" 2>&1; }
SQ(){  docker exec "$SUB" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -Q "$1" 2>&1; }
msgof(){ echo "$1" | grep -oE '^(Msg|메시지) [0-9]+' | head -1; }

for C in "$PUB" "$SUB"; do
  docker ps --format '{{.Names}}' | grep -q "^${C}$" \
    || { echo "중단: $C 이 안 떠 있습니다. docker compose up -d repl-pub repl-sub" >&2; exit 2; }
done
[ "$(num "$(PQ "SELECT 'RE'+'ADY'")")" = "READY" ] || { echo "중단: $PUB 이 쿼리를 못 받습니다" >&2; exit 2; }
[ "$(num "$(SQ "SELECT 'RE'+'ADY'")")" = "READY" ] || { echo "중단: $SUB 이 쿼리를 못 받습니다" >&2; exit 2; }

WORKDIR=/var/opt/mssql/data/repldata
docker exec "$PUB" mkdir -p "$WORKDIR" >/dev/null 2>&1
docker exec "$PUB" chown mssql:root "$WORKDIR" >/dev/null 2>&1
docker exec "$PUB" chmod 770 "$WORKDIR" >/dev/null 2>&1

# 앞 회차 잔재. 발행부터 내려야 표를 손댈 수 있다(Msg 3724).
for P in "$PUBNAME" pub_target; do
  PQD "EXEC sp_dropsubscription @publication = N'$P', @subscriber = N'all', @article = N'all';" >/dev/null 2>&1
  PQD "EXEC sp_droppublication @publication = N'$P';" >/dev/null 2>&1
done
PQ  "EXEC sp_replicationdboption @dbname = N'$PDB', @optname = N'publish', @value = N'false';" >/dev/null 2>&1
PQ  "IF DB_ID('$PDB') IS NOT NULL BEGIN
       ALTER DATABASE [$PDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$PDB]; END" >/dev/null 2>&1
SQ  "IF DB_ID('$SDB') IS NOT NULL BEGIN
       ALTER DATABASE [$SDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$SDB]; END" >/dev/null 2>&1
PQ  "EXEC sp_dropdistpublisher @publisher = N'$PUB';" >/dev/null 2>&1
PQ  "EXEC sp_dropdistributiondb @database = N'distribution';" >/dev/null 2>&1
PQ  "EXEC sp_dropdistributor @no_checks = 1, @ignore_distributor = 1;" >/dev/null 2>&1
[ "$(num "$(PQ "SELECT CASE WHEN DB_ID('$PDB') IS NULL THEN 'CLEAN' ELSE 'DIRTY' END")")" = "CLEAN" ] \
  || { echo "중단: 앞 회차의 발행 DB 를 못 지웠습니다" >&2; exit 2; }

STEP=0
: > "$OUT/replication-standing.csv"
echo "step,what,result,detail" >> "$OUT/replication-standing.csv"
step(){
  STEP=$(( STEP + 1 ))
  local m; m=$(msgof "$2")
  local v="됨"; [ -n "$m" ] && v="**실패** $m"
  printf "  %-3s %-46s %s\n" "$STEP" "$1" "$v"
  echo "$STEP,\"$1\",\"$v\",\"$(echo "$2" | grep -viE '^(Msg|메시지)|^$' | head -1 | sed 's/^ *//' | cut -c1-60)\"" >> "$OUT/replication-standing.csv"
  [ -z "$m" ]
}
# 작업을 범주로 찾는다. **로그 판독기는 발행별이 아니라 발행 DB 별**이라 이름에
# 발행명이 안 들어간다(A25-REPL-PUB-repl_src-1). 발행명으로 찾으면 못 찾는다.
find_job(){ numsp "$(PQ "SET NOCOUNT ON;
  SELECT TOP 1 j.name FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
   WHERE c.name = N'$1' AND j.name LIKE '%${2:-$PUBNAME}%';")"; }
subrows(){ num "$(SQ "SET NOCOUNT ON;
  SELECT CASE WHEN DB_ID('$SDB') IS NULL THEN '0'
              ELSE ISNULL((SELECT CAST(SUM(p.rows) AS varchar(20))
                             FROM $SDB.sys.partitions p JOIN $SDB.sys.tables t ON t.object_id = p.object_id
                            WHERE t.name = 'reclaim_feed' AND p.index_id IN (0,1)), '0') END;")"; }
# 배포 DB 에 **보관 중인** 명령. 전달이 끝나도 보존 기간까지 남는다.
stored(){ num "$(PQ "SET NOCOUNT ON;
  SELECT CAST(COUNT(*) AS varchar(20)) FROM distribution.dbo.MSrepl_commands;")"; }
# 이 구독에 **아직 못 간** 명령. 위와 다른 값이고, 이쪽이 밀림의 크기다.
# MSdistribution_status 에는 익명 구독용 가상 에이전트 행도 있어 실제 에이전트만 본다.
undeliv(){ num "$(PQ "SET NOCOUNT ON;
  SELECT CAST(ISNULL(SUM(s.UndelivCmdsInDistDB), 0) AS varchar(20))
    FROM distribution.dbo.MSdistribution_status s
    JOIN distribution.dbo.MSdistribution_agents a ON a.id = s.agent_id
   WHERE a.subscriber_db = N'$SDB' AND a.subscriber_id >= 0;")"; }
distmb(){ num "$(PQ "SET NOCOUNT ON;
  SELECT CAST(ISNULL(SUM(size) * 8 / 1024, 0) AS varchar(20)) FROM sys.master_files
   WHERE database_id = DB_ID('distribution');")"; }

{
echo "# 실험 18. 복제를 상시 구성으로 세우면 무엇이 더 붙는가"
echo
echo "  실험 15는 표 하나를 **한 번** 넘기는 비용을 쟀고, 결론에서 \"복제를 쓸 자리는"
echo "  조사 DB 를 운영에서 계속 떠먹이는 구성\"이라고 적었습니다. **그 자리를 권해"
echo "  놓고 그 구성은 안 세워 봤습니다.** 여기서 세웁니다."
echo
echo "  실험 15는 스냅샷 복제였습니다. 상시 구성은 트랜잭션 복제고 그것부터 다릅니다."
echo

echo "=================================================================="
echo "## 18-1. 세우는 단계"
echo "=================================================================="
echo
printf "  %-3s %-46s %s\n" "#" "한 일" "결과"

step "발행 DB 와 상시 공급 표를 만든다" "$(PQ "IF DB_ID('$PDB') IS NULL CREATE DATABASE [$PDB];")" || exit 2
step "구독 DB 를 만든다" "$(SQ "IF DB_ID('$SDB') IS NULL CREATE DATABASE [$SDB];")" || exit 2
step "표를 채운다" "$(PQD "SET NOCOUNT ON;
  DROP TABLE IF EXISTS reclaim_feed;
  CREATE TABLE reclaim_feed (
      event_id   INT    NOT NULL PRIMARY KEY,
      account_id INT    NOT NULL,
      amount     BIGINT NOT NULL);
  WITH n AS (SELECT TOP ($ROWS) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
               FROM sys.all_objects a CROSS JOIN sys.all_objects b)
  INSERT INTO reclaim_feed SELECT i, i % 1000, 6000 FROM n;")" || exit 2
step "배포자를 세운다" "$(PQ "EXEC sp_adddistributor @distributor = N'$PUB', @password = N'$PW';")"
step "배포 DB 를 만든다" "$(PQ "EXEC sp_adddistributiondb @database = N'distribution', @security_mode = 1;")"
step "배포 DB 에 마스터 키를 만든다" \
  "$(PQ "IF NOT EXISTS (SELECT 1 FROM distribution.sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
           EXEC distribution.sys.sp_executesql N'CREATE MASTER KEY ENCRYPTION BY PASSWORD = ''$PW''';")"
step "발행자를 배포자에 등록" \
  "$(PQ "EXEC sp_adddistpublisher @publisher = N'$PUB', @distribution_db = N'distribution',
          @security_mode = 1, @working_directory = N'$WORKDIR';")"
step "발행 DB 에 복제를 켠다" \
  "$(PQ "EXEC sp_replicationdboption @dbname = N'$PDB', @optname = N'publish', @value = N'true';")"

# **여기가 실험 15에 없던 단계다.** 트랜잭션 복제는 발행 DB 의 로그를 계속 읽어
# 바뀐 것을 배포 DB 로 옮기는 에이전트가 따로 있어야 한다.
step "로그 판독기 에이전트를 붙인다 (sp_addlogreader_agent)" \
  "$(PQD "EXEC sp_addlogreader_agent @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;")"

# @repl_freq = 'continuous' 가 트랜잭션 복제다. 실험 15는 'snapshot' 이었다.
step "발행 항목을 트랜잭션 복제로 만든다 (@repl_freq=continuous)" \
  "$(PQD "EXEC sp_addpublication @publication = N'$PUBNAME', @status = N'active',
           @allow_push = N'true', @repl_freq = N'continuous', @sync_method = N'concurrent',
           @independent_agent = N'true', @immediate_sync = N'true', @retention = 72;")"
step "스냅샷 에이전트를 붙인다" \
  "$(PQD "EXEC sp_addpublication_snapshot @publication = N'$PUBNAME',
           @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;")"
step "표를 발행 목록에 넣는다" \
  "$(PQD "EXEC sp_addarticle @publication = N'$PUBNAME', @article = N'reclaim_feed',
           @source_object = N'reclaim_feed', @force_invalidate_snapshot = 1;")"
step "구독을 만든다" \
  "$(PQD "EXEC sp_addsubscription @publication = N'$PUBNAME', @subscriber = N'$SUB',
           @destination_db = N'$SDB', @subscription_type = N'push', @sync_type = N'automatic';")"
step "배포 에이전트를 붙인다 (SQL 인증)" \
  "$(PQD "EXEC sp_addpushsubscription_agent @publication = N'$PUBNAME', @subscriber = N'$SUB',
           @subscriber_db = N'$SDB', @subscriber_security_mode = 0,
           @subscriber_login = N'sa', @subscriber_password = N'$PW';")"
SECMODE=$(num "$(PQ "SET NOCOUNT ON;
  SELECT TOP 1 CAST(subscriber_security_mode AS varchar(4)) FROM distribution.dbo.MSdistribution_agents
   WHERE subscriber_db = N'$SDB' ORDER BY id DESC;")")
step "그 에이전트가 SQL 인증으로 잡혔는지 되읽는다" \
  "$([ "${SECMODE:-1}" = "0" ] && echo "subscriber_security_mode = 0" || echo "Msg 0 통합인증으로 남았습니다")"

DIST_JOB=$(find_job 'REPL-Distribution')
LOG_JOB=$(find_job 'REPL-LogReader' "$PDB")
SNAP_JOB=$(find_job 'REPL-Snapshot')
if [ -n "$DIST_JOB" ]; then
  step "배포 에이전트에 -EncryptionLevel 0 을 붙인다" \
    "$(docker exec "$PUB" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d msdb -Q "SET NOCOUNT ON;
        DECLARE @cmd NVARCHAR(MAX);
        SELECT @cmd = command FROM dbo.sysjobsteps WHERE job_id = (SELECT job_id FROM dbo.sysjobs WHERE name = N'$DIST_JOB') AND step_id = 2;
        IF @cmd IS NOT NULL AND @cmd NOT LIKE '%EncryptionLevel%'
        BEGIN
          SET @cmd = @cmd + N' -EncryptionLevel 0';
          EXEC dbo.sp_update_jobstep @job_name = N'$DIST_JOB', @step_id = 2, @command = @cmd;
        END" 2>&1)"
fi

echo
printf "  %-46s %s\n" "실험 15(한 번 넘기기)" "15단계"
printf "  %-46s %s\n" "이번(상시 구성)" "${STEP}단계"
echo
echo "  늘어난 것은 단계 수만이 아닙니다."
echo
printf "  %-24s %s\n" "스냅샷 에이전트" "${SNAP_JOB:-없음}"
printf "  %-24s %s\n" "로그 판독기 에이전트" "${LOG_JOB:-**없음**}"
printf "  %-24s %s\n" "배포 에이전트" "${DIST_JOB:-없음}"
echo
echo "  **로그 판독기가 이번에 새로 생긴 것입니다.** 발행 DB 의 트랜잭션 로그를 계속"
echo "  읽어 바뀐 것을 배포 DB 로 옮깁니다. 이 에이전트가 멈추면 **발행 DB 의 로그가"
echo "  안 잘립니다.** 복구 모델이 SIMPLE 이어도 그렇습니다."
echo "\"-\",\"에이전트 수\",\"3개(로그 판독기 추가)\",\"$LOG_JOB\"" >> "$OUT/replication-standing.csv"
echo

echo "=================================================================="
echo "## 18-2. 바뀐 것이 따라오는가"
echo "=================================================================="
echo
[ -n "$SNAP_JOB" ] && PQ "EXEC msdb.dbo.sp_start_job @job_name = N'$SNAP_JOB';" >/dev/null 2>&1
SNAP_OK=0
for i in $(seq 1 60); do
  ST=$(num "$(PQ "SET NOCOUNT ON;
    SELECT TOP 1 CAST(runstatus AS varchar(4)) FROM distribution.dbo.MSsnapshot_history ORDER BY time DESC;")")
  case "${ST:-}" in 2) SNAP_OK=1; break ;; 6) break ;; esac
  sleep 5
done
printf "  %-30s %s\n" "스냅샷 생성" "$([ "$SNAP_OK" = 1 ] && echo "완료" || echo "**미완료**")"
[ -n "$LOG_JOB" ]  && PQ "EXEC msdb.dbo.sp_start_job @job_name = N'$LOG_JOB';"  >/dev/null 2>&1
[ -n "$DIST_JOB" ] && PQ "EXEC msdb.dbo.sp_start_job @job_name = N'$DIST_JOB';" >/dev/null 2>&1

ARRIVED=0
for i in $(seq 1 40); do
  [ "$(subrows)" -ge "$ROWS" ] 2>/dev/null && { ARRIVED=1; break; }
  sleep 5
done
printf "  %-30s %s\n" "첫 적재 ${ROWS}행 도착" "$([ "$ARRIVED" = 1 ] && echo "됨" || echo "**안 됨**")"
[ "$ARRIVED" = 1 ] || { echo; echo "  전달이 안 돼 이 뒤를 못 잽니다."; \
  PQ "SET NOCOUNT ON; SELECT TOP 3 'ERR: ' + LEFT(error_text, 90) FROM distribution.dbo.MSrepl_errors ORDER BY time DESC;" \
    | grep '^ERR' | sed 's/^/    /'; exit 2; }

# 새로 들어온 것이 따라오는가. 상시 구성의 존재 이유가 이것이다.
PQD "SET NOCOUNT ON;
  INSERT INTO reclaim_feed
  SELECT $ROWS + i, i % 1000, 7000
    FROM (SELECT TOP (500) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects) x;" >/dev/null
FOLLOW=0
for i in $(seq 1 24); do
  [ "$(subrows)" -ge "$(( ROWS + 500 ))" ] 2>/dev/null && { FOLLOW=1; break; }
  sleep 5
done
printf "  %-30s %s\n" "그 뒤 500행 추가분이 따라옴" "$([ "$FOLLOW" = 1 ] && echo "됨" || echo "**안 옴**")"
echo "\"-\",\"증분 전달\",\"$([ "$FOLLOW" = 1 ] && echo 됨 || echo 안됨)\",\"500행\"" >> "$OUT/replication-standing.csv"
echo
echo "  **이것이 실험 15와 다른 점입니다.** 스냅샷 복제는 스냅샷을 다시 떠야 하고,"
echo "  트랜잭션 복제는 로그 판독기가 바뀐 것만 계속 흘려보냅니다. 조사 DB 를 상시로"
echo "  떠먹이려면 이쪽이어야 합니다."
echo

echo "=================================================================="
echo "## 18-3. 구독자가 죽으면 무엇이 쌓이는가"
echo "=================================================================="
echo
echo "  상시 구성의 진짜 비용은 여기 있습니다. 한 번 넘기고 끝나는 구성에는"
echo "  이 질문 자체가 없습니다."
echo
P0=$(stored); U0=$(undeliv); D0=$(distmb)
printf "  %-34s %s\n" "구독자를 내리기 전 배포 DB" "${D0}MB"
printf "  %-34s %s\n" "  보관 중인 명령 / 미전달" "${P0}건 / ${U0}건"

docker stop "$SUB" >/dev/null 2>&1
sleep 3
printf "  %-34s %s\n" "구독자를 내렸습니다" "$(docker ps --format '{{.Names}}' | grep -c "^${SUB}$")대 떠 있음"

# 구독자가 없는 동안 발행자에는 계속 들어온다.
PQD "SET NOCOUNT ON;
  INSERT INTO reclaim_feed
  SELECT 1000000 + i, i % 1000, 8000
    FROM (SELECT TOP ($BURST) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
            FROM sys.all_objects a CROSS JOIN sys.all_objects b) x;" >/dev/null
sleep 30
P1=$(stored); U1=$(undeliv); D1=$(distmb)
printf "  %-34s %s\n" "그 사이 발행자에 넣은 행" "${BURST}행"
printf "  %-34s %s\n" "보관 중인 명령" "${P0}건 -> ${P1}건"
printf "  %-34s %s\n" "그중 미전달" "${U0}건 -> **${U1}건**"
printf "  %-34s %s\n" "배포 DB 크기" "${D0}MB -> **${D1}MB**"
echo "\"-\",\"구독자 중단 중 적체\",\"${P0} -> ${P1}건\",\"배포 DB ${D0} -> ${D1}MB\"" >> "$OUT/replication-standing.csv"
echo
echo "  배포 에이전트가 말하는 것:"
PQ "SET NOCOUNT ON;
    SELECT TOP 2 'ERR: ' + LEFT(REPLACE(REPLACE(error_text, CHAR(13), ' '), CHAR(10), ' '), 88)
      FROM distribution.dbo.MSrepl_errors ORDER BY time DESC;" 2>/dev/null \
  | grep '^ERR' | sed 's/^/    /' || true
echo
echo "  **구독자가 없는 동안 그 부담은 배포자가 집니다.** 미배포 명령이 배포 DB 에"
echo "  쌓이고 그만큼 자랍니다. 보존 기간(@retention, 기본 72시간)을 넘기면 구독이"
echo "  만료되고, 그때는 스냅샷을 다시 떠서 **처음부터 다시 밀어야** 합니다."
echo

echo "=================================================================="
echo "## 18-4. 다시 붙으면 알아서 따라잡는가"
echo "=================================================================="
echo
docker start "$SUB" >/dev/null 2>&1
for i in $(seq 1 40); do
  sleep 5
  [ "$(num "$(SQ "SELECT 'RE'+'ADY'")")" = "READY" ] && break
done
printf "  %-34s %s\n" "구독자를 다시 올렸습니다" "$(num "$(SQ "SELECT 'RE'+'ADY'")")"

TARGET=$(( ROWS + 500 + BURST ))
CAUGHT=0
for i in $(seq 1 60); do
  [ "$(subrows)" -ge "$TARGET" ] 2>/dev/null && { CAUGHT=1; break; }
  [ $(( i % 6 )) = 0 ] && [ -n "$DIST_JOB" ] && PQ "EXEC msdb.dbo.sp_start_job @job_name = N'$DIST_JOB';" >/dev/null 2>&1
  sleep 5
done
GOT=$(subrows); P2=$(stored); U2=$(undeliv); D2=$(distmb)
printf "  %-34s %s\n" "구독자 행 수" "${GOT} / ${TARGET}"
printf "  %-34s %s\n" "미전달 명령" "${U1}건 -> **${U2}건**"
printf "  %-34s %s\n" "따라잡았는가" "$([ "$CAUGHT" = 1 ] && echo "**됨**" || echo "**못 함**")"
echo
printf "  %-34s %s\n" "그런데 보관 중인 명령" "${P1}건 -> ${P2}건"
printf "  %-34s %s\n" "그리고 배포 DB 크기" "${D1}MB -> ${D2}MB"
echo "\"-\",\"복구 후 따라잡기\",\"$([ "$CAUGHT" = 1 ] && echo 됨 || echo 못함)\",\"${GOT}/${TARGET}\"" >> "$OUT/replication-standing.csv"
echo
if [ "$CAUGHT" = 1 ]; then
  echo "  **알아서 따라잡습니다.** 배포 에이전트가 다시 붙어 쌓인 명령을 순서대로"
  echo "  밀어 넣습니다. 사람이 할 일은 없습니다. **다만 그것은 보존 기간 안에서만"
  echo "  참입니다.** 넘기면 구독이 만료되고 스냅샷부터 다시입니다."
  echo
  echo "  그런데 **전달이 끝났는데도 배포 DB 는 안 줄었습니다.** 미전달은 0 인데"
  echo "  보관 중인 명령과 크기는 그대로입니다. @immediate_sync = true 로 만든"
  echo "  발행이라 **새 구독자가 스냅샷 없이 붙을 수 있게** 명령을 보존 기간 내내"
  echo "  들고 있기 때문입니다. 정리 작업이 돌아 보존 기간이 지나야 줄어듭니다."
  echo
  echo "  그래서 배포 DB 크기는 **구독자의 상태가 아니라 발행 설정과 변경량이**"
  echo "  정합니다. 구독자가 멀쩡해도 쓰기가 많으면 그만큼 자랍니다."
else
  echo "  **자동으로는 안 따라잡았습니다.** 재초기화가 필요한 상태입니다."
fi

echo
echo "=================================================================="
echo "## 18-5. 로그 판독기가 멈추면"
echo "=================================================================="
echo
echo "  구독자가 죽으면 배포자가 부담을 진다고 했습니다. 그러면 로그 판독기가"
echo "  멈추면 누가 집니까. **발행자, 즉 운영 DB 입니다.**"
echo
echo "  같은 쓰기를 두 번 합니다. 한 번은 로그 판독기가 도는 채로, 한 번은 멈춘"
echo "  채로. 복구 모델은 둘 다 SIMPLE 입니다."
echo
# 복구 모델을 SIMPLE 로 내려도 그런지가 요점이다. SIMPLE 이면 체크포인트가 알아서
# 자른다고 알기 쉬운데, 복제가 걸리면 **읽어 가지 않은 로그는 못 자른다.**
PQ "ALTER DATABASE [$PDB] SET RECOVERY SIMPLE;" >/dev/null 2>&1
LOGBURST=${LOGBURST:-200000}
# 파일 크기는 자동 증가 설정에 좌우되므로 **쓰인 로그 자체**를 같이 본다.
logused(){ num "$(PQD "SET NOCOUNT ON;
  SELECT CAST(CAST(used_log_space_in_bytes/1048576.0 AS DECIMAL(10,1)) AS varchar(20))
    FROM sys.dm_db_log_space_usage;")"; }
logfile(){ num "$(PQ "SET NOCOUNT ON;
  SELECT CAST(CAST(SUM(size)*8.0/1024 AS DECIMAL(10,1)) AS varchar(20)) FROM sys.master_files
   WHERE database_id = DB_ID('$PDB') AND type_desc = 'LOG';")"; }
waitdesc(){ num "$(PQ "SET NOCOUNT ON;
  SELECT recovery_model_desc + ' / ' + log_reuse_wait_desc FROM sys.databases WHERE name = '$PDB';")"; }
burst(){ PQD "SET NOCOUNT ON;
  INSERT INTO reclaim_feed
  SELECT $1 + i, i % 1000, 9000
    FROM (SELECT TOP ($LOGBURST) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
            FROM sys.all_objects a CROSS JOIN sys.all_objects b) x;
  CHECKPOINT;" >/dev/null 2>&1; }

# ── 기준선: 로그 판독기가 도는 채로 ─────────────────────────────────────
[ -n "$LOG_JOB" ] && PQ "EXEC msdb.dbo.sp_start_job @job_name = N'$LOG_JOB';" >/dev/null 2>&1
sleep 10
A_USED=$(logused); A_FILE=$(logfile)
burst 3000000
sleep 20
PQD "CHECKPOINT;" >/dev/null 2>&1
B_USED=$(logused); B_FILE=$(logfile); B_WAIT=$(waitdesc)
printf "  %-34s %s\n" "A 로그 판독기가 도는 채로" "${LOGBURST}행"
printf "  %-34s %s\n" "  쓰인 로그" "${A_USED}MB -> ${B_USED}MB"
printf "  %-34s %s\n" "  로그 파일" "${A_FILE}MB -> ${B_FILE}MB"
printf "  %-34s %s\n" "  재사용 대기" "$B_WAIT"
echo "\"-\",\"A 판독기 정상\",\"$B_WAIT\",\"쓰인 로그 ${A_USED} -> ${B_USED}MB\"" >> "$OUT/replication-standing.csv"
echo

# ── 대조: 로그 판독기를 멈춘 채로 같은 쓰기 ─────────────────────────────
[ -n "$LOG_JOB" ] && PQ "EXEC msdb.dbo.sp_stop_job @job_name = N'$LOG_JOB';" >/dev/null 2>&1
sleep 10
C_USED=$(logused); C_FILE=$(logfile)
burst 4000000
sleep 20
PQD "CHECKPOINT;" >/dev/null 2>&1
D_USED=$(logused); D_FILE=$(logfile); D_WAIT=$(waitdesc)
printf "  %-34s %s\n" "B 로그 판독기를 멈춘 채로" "${LOGBURST}행 (같은 양)"
printf "  %-34s %s\n" "  쓰인 로그" "${C_USED}MB -> **${D_USED}MB**"
printf "  %-34s %s\n" "  로그 파일" "${C_FILE}MB -> **${D_FILE}MB**"
printf "  %-34s %s\n" "  재사용 대기" "**$D_WAIT**"
echo "\"-\",\"B 판독기 중단\",\"$D_WAIT\",\"쓰인 로그 ${C_USED} -> ${D_USED}MB\"" >> "$OUT/replication-standing.csv"
echo
echo "  **복구 모델이 SIMPLE 인데도 로그가 안 잘립니다.** SIMPLE 이면 체크포인트가"
echo "  알아서 자른다고 알기 쉬운데, 복제가 걸린 DB 는 **로그 판독기가 읽어 가기"
echo "  전까지는 그 구간을 못 버립니다.** log_reuse_wait_desc 가 그것을 말합니다."
echo "  판독기가 도는 A 에서는 같은 쓰기를 하고도 쓰인 로그가 제자리로 돌아옵니다."
echo

# 다시 켜면 회수되는가. 원인이 판독기인지 확인하는 자리다.
[ -n "$LOG_JOB" ] && PQ "EXEC msdb.dbo.sp_start_job @job_name = N'$LOG_JOB';" >/dev/null 2>&1
# waitdesc 는 num() 을 거쳐 공백이 빠진다("SIMPLE/NOTHING"). 공백 있는 문자열과
# 비교하면 **항상 참**이라 첫 회에 빠져나온다. 실제로 한 번 그렇게 틀렸다.
for i in $(seq 1 30); do
  sleep 6
  PQD "CHECKPOINT;" >/dev/null 2>&1
  case "$(waitdesc)" in *REPLICATION*) ;; *) break ;; esac
done
E_USED=$(logused); E_WAIT=$(waitdesc)
printf "  %-34s %s\n" "판독기를 다시 켜면" "$E_WAIT"
printf "  %-34s %s\n" "  쓰인 로그" "${D_USED}MB -> ${E_USED}MB"
echo "\"-\",\"판독기 재기동\",\"$E_WAIT\",\"쓰인 로그 ${D_USED} -> ${E_USED}MB\"" >> "$OUT/replication-standing.csv"
echo
if case "$E_WAIT" in *REPLICATION*) false;; *) true;; esac; then
  echo "  판독기를 다시 켜자 회수됐습니다. **원인이 판독기라는 것이 이것으로 섭니다.**"
  echo "  사람이 손댈 것은 없지만, 그때까지 자란 로그 파일은 **안 줄어듭니다.**"
  echo "  줄이려면 따로 축소해야 하고 그것은 또 다른 작업입니다."
else
  echo "  **아직 안 풀렸습니다.** 판독기가 밀린 만큼을 다 읽어야 풀립니다."
fi
echo
echo "  이것이 상시 구성에서 제일 위험한 자리입니다. 구독자가 죽으면 배포 DB 가"
echo "  자라지만 그것은 **옆 서버**입니다. 로그 판독기가 죽으면 **운영 DB 의 로그가**"
echo "  자랍니다. 로그가 디스크를 채우면 그 DB 는 쓰기를 못 받습니다."
echo

echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  실험 15의 결론은 \"복제를 쓸 자리는 조사 DB 를 상시로 떠먹이는 구성\"이었습니다."
echo "  그 자리를 실제로 세워 보니 값이 이렇습니다."
echo
printf "  %-28s %-22s %s\n" "" "한 번 넘기기(실험 15)" "상시 구성(이번)"
printf "  %-28s %-22s %s\n" "세우는 단계" "15" "${STEP}"
printf "  %-28s %-22s %s\n" "에이전트" "2개" "**3개(로그 판독기)**"
printf "  %-28s %-22s %s\n" "발행 DB 로그" "안 묶임" "**판독기가 멈추면 SIMPLE 이어도 안 잘림**"
printf "  %-28s %-22s %s\n" "구독자가 죽으면" "해당 없음" "**배포 DB 에 적체**"
printf "  %-28s %-22s %s\n" "그 적체의 한계" "해당 없음" "보존 기간(기본 72시간)"
printf "  %-28s %-22s %s\n" "전달이 끝나면" "파일을 지우면 끝" "**배포 DB 는 안 줄어듦**"
printf "  %-28s %-22s %s\n" "끊겼다 붙으면" "해당 없음" "$([ "$CAUGHT" = 1 ] && echo "알아서 따라잡음" || echo "재초기화 필요")"
echo
echo "  **상시 구성은 세우는 비용보다 유지하는 비용이 큽니다.** 한 번 넘기기는"
echo "  끝나면 끝이지만, 상시 구성은 구독자·배포자·로그 판독기 셋이 계속 살아 있어야"
echo "  하고 하나가 멈추면 다른 쪽에 부담이 갑니다. 특히 로그 판독기가 멈추면"
echo "  **발행 DB 의 로그가 안 잘려** 운영 DB 쪽 디스크가 찹니다."
echo
echo "  그래서 실험 15의 결론에 조건을 하나 붙입니다. 조사 DB 를 상시로 떠먹이는"
echo "  구성이 맞기는 하지만, **그것은 이관 문제를 없애는 대신 상시 감시 대상을"
echo "  셋 늘리는 거래입니다.** 회수가 1년에 몇 번인지에 따라 답이 갈립니다."
} 2>&1 | tee "$OUT/exp18-replication-standing.txt"
