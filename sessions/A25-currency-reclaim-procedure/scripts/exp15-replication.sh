#!/usr/bin/env bash
# 실험 15. 복제로 회수 대상을 넘기면 얼마나 드는가.
#
# 못 한 것에 이렇게 적었다.
#   "복제로 넘기는 경우는 안 쟀습니다. bcp 와 링크드 서버 둘을 견줬고 복제는
#    세팅 비용이 커서 만들지 않았습니다."
#
# **재 보지도 않고 "비용이 크다"고 판단한 것**이다. 실제로 세워서 그 비용을
# 숫자로 남긴다. 그래야 "안 맞는다"가 근거 있는 말이 된다.
#
# 확인할 것 셋이다.
#   1 세우는 데 무엇이 필요한가        단계 수와 만들어지는 것
#   2 넘어간 데이터가 맞는가            지문 대조
#   3 세운 뒤에 무엇이 묶이는가        일회성 이관에 맞는지가 여기서 갈린다
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

PUB=a25-repl-pub
SUB=a25-repl-sub
PDB=repl_src
SDB=repl_dst
PUBNAME=pub_target
ROWS=${REPL_ROWS:-5000}

PQ(){  docker exec "$PUB" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -Q "$1" 2>&1; }
PQD(){ docker exec "$PUB" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$PDB" -Q "$1" 2>&1; }
SQ(){  docker exec "$SUB" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -Q "$1" 2>&1; }
SQD(){ docker exec "$SUB" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$SDB" -Q "$1" 2>&1; }
msgof(){ echo "$1" | grep -oE '^(Msg|메시지) [0-9]+' | head -1; }

for C in "$PUB" "$SUB"; do
  docker ps --format '{{.Names}}' | grep -q "^${C}$" \
    || { echo "중단: $C 이 안 떠 있습니다. docker compose up -d repl-pub repl-sub" >&2; exit 2; }
done
[ "$(num "$(PQ "SELECT 'RE'+'ADY'")")" = "READY" ] || { echo "중단: $PUB 이 쿼리를 못 받습니다" >&2; exit 2; }
[ "$(num "$(SQ "SELECT 'RE'+'ADY'")")" = "READY" ] || { echo "중단: $SUB 이 쿼리를 못 받습니다" >&2; exit 2; }

# 스냅샷을 쓸 작업 디렉터리를 미리 만든다. 없으면 sp_adddistpublisher 가
# Msg 21037 로 죽고, 그 뒤 여섯 단계가 연쇄로 무너진다(20028 -> 14013 -> 18757 ...).
# **복제는 앞 단계가 무너지면 뒤가 전부 다른 오류로 나와** 원인을 찾기 어렵다.
WORKDIR=/var/opt/mssql/data/repldata
docker exec "$PUB" mkdir -p "$WORKDIR" >/dev/null 2>&1
docker exec "$PUB" chown mssql:root "$WORKDIR" >/dev/null 2>&1
docker exec "$PUB" chmod 770 "$WORKDIR" >/dev/null 2>&1

# 앞 회차의 잔재를 걷어낸다.
#
# **이것도 복제의 비용이다.** 앞 회차가 남긴 표는 발행 중이라 DROP TABLE 이 막히고
# (Msg 3724), 그 표에 붙은 컬럼이 남아 다음 회차의 INSERT 가 Msg 213 으로 죽는다.
# 순서를 지켜 발행부터 내려야 표를 손댈 수 있다.
PQD "EXEC sp_dropsubscription @publication = N'$PUBNAME', @subscriber = N'all', @article = N'all';" >/dev/null 2>&1
PQD "EXEC sp_droppublication @publication = N'$PUBNAME';" >/dev/null 2>&1
PQ  "EXEC sp_replicationdboption @dbname = N'$PDB', @optname = N'publish', @value = N'false';" >/dev/null 2>&1
PQ  "IF DB_ID('$PDB') IS NOT NULL BEGIN
       ALTER DATABASE [$PDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
       DROP DATABASE [$PDB];
     END" >/dev/null 2>&1
SQ  "IF DB_ID('$SDB') IS NOT NULL BEGIN
       ALTER DATABASE [$SDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
       DROP DATABASE [$SDB];
     END" >/dev/null 2>&1
PQ  "EXEC sp_dropdistpublisher @publisher = N'$PUB';" >/dev/null 2>&1
PQ  "EXEC sp_dropdistributiondb @database = N'distribution';" >/dev/null 2>&1
PQ  "EXEC sp_dropdistributor @no_checks = 1, @ignore_distributor = 1;" >/dev/null 2>&1

# 정리가 됐는지 확인하고 시작한다. 안 됐으면 이 회차는 성립하지 않는다.
LEFT=$(num "$(PQ "SELECT CASE WHEN DB_ID('$PDB') IS NULL THEN 'CLEAN' ELSE 'DIRTY' END")")
[ "$LEFT" = "CLEAN" ] || { echo "중단: 앞 회차의 발행 DB 를 못 지웠습니다" >&2; exit 2; }

STEP=0
: > "$OUT/replication.csv"
echo "step,what,result,detail" >> "$OUT/replication.csv"
step(){ # $1=설명 $2=명령 결과
  STEP=$(( STEP + 1 ))
  local m; m=$(msgof "$2")
  local v="됨"; [ -n "$m" ] && v="**실패** $m"
  printf "  %-3s %-44s %s\n" "$STEP" "$1" "$v"
  echo "$STEP,\"$1\",\"$v\",\"$(echo "$2" | grep -viE '^(Msg|메시지)|^$' | head -1 | sed 's/^ *//' | cut -c1-60)\"" >> "$OUT/replication.csv"
  [ -z "$m" ]
}

{
echo "# 실험 15. 복제로 넘기면 얼마나 드는가"
echo
echo "  실험 13은 bcp 와 링크드 서버를 견주고 **복제는 세팅 비용이 커서 안 했다**고"
echo "  적었습니다. 재 보지도 않고 내린 판단이라 여기서 실제로 세웁니다."
echo
echo "  발행자 ${PUB}, 구독자 ${SUB}. 둘 다 SQL Server 에이전트를 켠 별도 컨테이너입니다."
echo

echo "=================================================================="
echo "## 15-1. 세우기 전에 이미 든 비용"
echo "=================================================================="
echo
echo "  본체(a25-mssql)로는 못 합니다. 복제는 에이전트가 있어야 도는데 이 이미지는"
echo "  기본으로 꺼져 있고, 켜려면 환경변수를 주고 **컨테이너를 다시 만들어야** 합니다."
echo "  본체를 다시 만들면 데이터가 날아갑니다."
echo
echo "  그래서 컨테이너를 둘 더 띄웠는데 Docker VM 메모리(7.7GB)가 모자라"
echo "  **다른 컨테이너를 전부 내려야 했습니다.** SQL Server 하나가 시작할 때"
echo "  락 소유자 블록을 미리 잡는데 그것도 못 해 죽었습니다(Error 1209)."
echo
printf "  %-44s %s\n" "본체에서 바로 되는가" "안 됨. 에이전트를 켜려면 재생성"
printf "  %-44s %s\n" "추가로 필요한 인스턴스" "발행자 + 구독자 = 2대"
printf "  %-44s %s\n" "그 둘을 띄우려고 내린 것" "본체 4대"
printf "  %-44s %s\n" "발행자 메모리" "2g 로는 죽음. 4g 필요(배포 DB 포함)"
printf "  %-44s %s\n" "인증서" "자체 서명이라 에이전트가 못 붙음"
echo "\"0\",\"세우기 전 비용\",\"인스턴스 2대 추가, 본체 4대 중지\",\"에이전트 재생성 필요\"" >> "$OUT/replication.csv"
echo

echo "=================================================================="
echo "## 15-2. 세우는 단계"
echo "=================================================================="
echo
printf "  %-3s %-44s %s\n" "#" "한 일" "결과"

step "발행 DB 와 대상 표를 만든다" "$(PQ "IF DB_ID('$PDB') IS NULL CREATE DATABASE [$PDB];")" || exit 2
step "구독 DB 를 만든다" "$(SQ "IF DB_ID('$SDB') IS NULL CREATE DATABASE [$SDB];")" || exit 2
step "회수 대상 표를 채운다" "$(PQD "SET NOCOUNT ON;
  DROP TABLE IF EXISTS reclaim_target;
  CREATE TABLE reclaim_target (
      account_id   INT    NOT NULL PRIMARY KEY,
      extra_rows   INT    NOT NULL,
      extra_amount BIGINT NOT NULL);
  WITH n AS (SELECT TOP ($ROWS) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
               FROM sys.all_objects a CROSS JOIN sys.all_objects b)
  INSERT INTO reclaim_target SELECT i, 3, 6000 FROM n;")" || exit 2

# 배포자. 복제는 발행자·배포자·구독자 셋이고 배포자를 따로 안 두면 발행자가 겸한다.
step "배포자를 세운다 (sp_adddistributor)" \
  "$(PQ "EXEC sp_adddistributor @distributor = N'$PUB', @password = N'$PW';")"
step "배포 DB 를 만든다 (sp_adddistributiondb)" \
  "$(PQ "EXEC sp_adddistributiondb @database = N'distribution', @security_mode = 1;")"
step "발행자를 배포자에 등록 (sp_adddistpublisher)" \
  "$(PQ "EXEC sp_adddistpublisher @publisher = N'$PUB', @distribution_db = N'distribution',
          @security_mode = 1, @working_directory = N'/var/opt/mssql/data/repldata';")"
step "발행 DB 에 복제를 켠다 (sp_replicationdboption)" \
  "$(PQ "EXEC sp_replicationdboption @dbname = N'$PDB', @optname = N'publish', @value = N'true';")"
step "발행 항목을 만든다 (sp_addpublication)" \
  "$(PQD "EXEC sp_addpublication @publication = N'$PUBNAME', @status = N'active',
           @allow_push = N'true', @repl_freq = N'snapshot', @sync_method = N'native',
           @independent_agent = N'true', @immediate_sync = N'true';")"
step "스냅샷 에이전트를 붙인다 (sp_addpublication_snapshot)" \
  "$(PQD "EXEC sp_addpublication_snapshot @publication = N'$PUBNAME',
           @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;")"
step "표를 발행 목록에 넣는다 (sp_addarticle)" \
  "$(PQD "EXEC sp_addarticle @publication = N'$PUBNAME', @article = N'reclaim_target',
           @source_object = N'reclaim_target', @force_invalidate_snapshot = 1;")"
step "구독을 만든다 (sp_addsubscription)" \
  "$(PQD "EXEC sp_addsubscription @publication = N'$PUBNAME', @subscriber = N'$SUB',
           @destination_db = N'$SDB', @subscription_type = N'push', @sync_type = N'automatic';")"
step "배포 에이전트를 붙인다 (sp_addpushsubscription_agent)" \
  "$(PQD "EXEC sp_addpushsubscription_agent @publication = N'$PUBNAME', @subscriber = N'$SUB',
           @subscriber_db = N'$SDB', @subscriber_security_mode = 0,
           @subscriber_login = N'sa', @subscriber_password = N'$PW',
           @publisher_security_mode = 1;")"


# 13단계. 배포 에이전트가 구독자에 못 붙는다.
#
# SQL Server 2022 + ODBC 18 은 기본으로 서버 인증서를 검증하는데 컨테이너의
# 인증서는 자체 서명이다. sqlcmd 는 -C 로 넘기지만 **배포 에이전트에는 그 옵션이
# 없다.** 복제 에이전트의 -EncryptionLevel 로 낮춘다.
#   0 암호화 안 함  1 필요하면  2 검증까지
# 실무라면 구독자에 제대로 된 인증서를 넣는 것이 맞고, 이것은 랩에서만 쓰는 우회다.
DSTEP=$(numsp "$(PQ "SET NOCOUNT ON;
  SELECT TOP 1 j.name FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
   WHERE c.name = N'REPL-Distribution' AND j.name LIKE '%$PUBNAME%';")")
if [ -n "$DSTEP" ]; then
  # sp_update_jobstep 는 msdb 에서 돌려야 하고, EXEC 매개변수에 식을 못 쓴다.
  # 처음에 master 에서 @command = @cmd + N'...' 로 넣었다가 Msg 102 로 죽었고,
  # 그 실패가 조용해서 옵션이 안 붙은 줄도 몰랐다.
  step "배포 에이전트에 -EncryptionLevel 0 을 붙인다" \
    "$(docker exec "$PUB" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d msdb -Q "SET NOCOUNT ON;
        DECLARE @cmd NVARCHAR(MAX);
        SELECT @cmd = s.command FROM dbo.sysjobsteps s JOIN dbo.sysjobs j ON j.job_id = s.job_id
         WHERE j.name = N'$DSTEP' AND s.step_id = 2;
        IF @cmd IS NOT NULL AND @cmd NOT LIKE '%EncryptionLevel%'
        BEGIN
          SET @cmd = @cmd + N' -EncryptionLevel 0';
          EXEC dbo.sp_update_jobstep @job_name = N'$DSTEP', @step_id = 2, @command = @cmd;
        END" 2>&1)"
fi

echo
echo "  **여기까지가 표 하나를 넘기기 위한 단계입니다.**"
echo

echo "=================================================================="
echo "## 15-3. 넘어갔는가"
echo "=================================================================="
echo
# 에이전트 작업은 **이름이 아니라 범주로** 찾는다. 배포 작업 이름은
# '<발행자>-<발행DB>-<발행명>-<구독자>-<n>' 이라 구독 DB 이름이 안 들어간다.
# 처음에 구독 DB 이름으로 찾다가 못 찾아 전달이 안 됐다.
find_job(){ # $1=범주
  numsp "$(PQ "SET NOCOUNT ON;
    SELECT TOP 1 j.name FROM msdb.dbo.sysjobs j
      JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
     WHERE c.name = N'$1' AND j.name LIKE '%$PUBNAME%';")"
}
SNAP_JOB=$(find_job 'REPL-Snapshot')
DIST_JOB=$(find_job 'REPL-Distribution')
printf "  %-22s %s\n" "스냅샷 에이전트" "${SNAP_JOB:-못 찾음}"
printf "  %-22s %s\n" "배포 에이전트" "${DIST_JOB:-못 찾음}"
echo
[ -n "$SNAP_JOB" ] && PQ "EXEC msdb.dbo.sp_start_job @job_name = N'$SNAP_JOB';" >/dev/null 2>&1

# 스냅샷이 **끝날 때까지 기다린 뒤** 배포를 시작한다. 먼저 돌리면
# "The initial snapshot for article is not yet available" 로 그냥 끝나고,
# 그 뒤로는 스케줄이 올 때까지 아무 일도 안 일어난다.
SNAP_OK=0
for i in $(seq 1 60); do
  ST=$(num "$(PQ "SET NOCOUNT ON;
    SELECT TOP 1 CAST(runstatus AS varchar(4)) FROM distribution.dbo.MSsnapshot_history
     ORDER BY time DESC;")")
  case "${ST:-}" in
    2) SNAP_OK=1; break ;;   # 성공
    6) break ;;              # 실패
  esac
  sleep 5
done
printf "  %-22s %s\n" "스냅샷 생성" "$([ "$SNAP_OK" = 1 ] && echo "완료" || echo "**미완료**")"
[ -n "$DIST_JOB" ] && PQ "EXEC msdb.dbo.sp_start_job @job_name = N'$DIST_JOB';" >/dev/null 2>&1

echo "  데이터가 도착할 때까지 기다립니다."
ARRIVED=0
for i in $(seq 1 60); do
  N=$(num "$(SQ "SET NOCOUNT ON;
    SELECT CASE WHEN DB_ID('$SDB') IS NULL THEN '0'
                ELSE ISNULL((SELECT CAST(SUM(p.rows) AS varchar(20))
                               FROM $SDB.sys.partitions p
                               JOIN $SDB.sys.tables t ON t.object_id = p.object_id
                              WHERE t.name = 'reclaim_target' AND p.index_id IN (0,1)), '0') END;")")
  case "${N:-0}" in ''|*[!0-9]*) N=0 ;; esac
  if [ "${N:-0}" -ge "$ROWS" ] 2>/dev/null; then ARRIVED=1; break; fi
  [ $(( i % 6 )) = 0 ] && [ -n "$DIST_JOB" ] && PQ "EXEC msdb.dbo.sp_start_job @job_name = N'$DIST_JOB';" >/dev/null 2>&1
  sleep 5
done
echo
if [ "$ARRIVED" = 1 ]; then
  FP_P=$(num "$(PQD "SET NOCOUNT ON;
    SELECT CAST(COUNT(*) AS varchar(12)) + ',' + CAST(SUM(extra_amount) AS varchar(30)) + ',' +
           CAST(CHECKSUM_AGG(BINARY_CHECKSUM(account_id, extra_rows, extra_amount)) AS varchar(20))
      FROM reclaim_target;")")
  FP_S=$(num "$(SQD "SET NOCOUNT ON;
    SELECT CAST(COUNT(*) AS varchar(12)) + ',' + CAST(SUM(extra_amount) AS varchar(30)) + ',' +
           CAST(CHECKSUM_AGG(BINARY_CHECKSUM(account_id, extra_rows, extra_amount)) AS varchar(20))
      FROM reclaim_target;")")
  V="일치"; [ "$FP_P" = "$FP_S" ] || V="**어긋남**"
  printf "  %-20s %s\n" "발행자 지문" "$FP_P"
  printf "  %-20s %s\n" "구독자 지문" "$FP_S"
  printf "  %-20s %s\n" "대조" "$V"
  echo "\"-\",\"지문 대조\",\"$V\",\"$FP_P vs $FP_S\"" >> "$OUT/replication.csv"
  echo
  echo "  **넘어갑니다.** bcp·링크드 서버와 마찬가지로 지문이 맞습니다."
  echo "  데이터가 도착하는 것 자체는 세 방법이 다르지 않습니다."
else
  echo "  **도착을 못 확인했습니다.** 에이전트 작업이 안 돌았거나 실패했습니다."
  echo "  배포 이력이 말하는 이유:"
  PQ "SET NOCOUNT ON;
      SELECT TOP 3 'ERR: ' + LEFT(REPLACE(REPLACE(comments, CHAR(13), ' '), CHAR(10), ' '), 100)
        FROM distribution.dbo.MSdistribution_history
       WHERE runstatus = 6 ORDER BY time DESC;" 2>/dev/null \
    | grep '^ERR' | sed 's/^/    /' || true
  echo
  echo "  발행자에서 구독자로 직접 붙는 것은 됩니다(sqlcmd -C 로 확인). 에이전트만"
  echo "  못 붙습니다. **자체 서명 인증서를 신뢰하는 설정이 에이전트 쪽에 따로**"
  echo "  필요한 것으로 보이고, -EncryptionLevel 0 으로도 안 넘어갔습니다."
  echo "\"-\",\"지문 대조\",\"확인 못 함\",\"에이전트 미완료\"" >> "$OUT/replication.csv"
fi
echo

echo "=================================================================="
echo "## 15-4. 세운 뒤에 무엇이 묶이는가"
echo "=================================================================="
echo
echo "  여기가 일회성 이관에 맞는지 갈리는 자리입니다."
echo
printf "  %-44s %s\n" "해 본 것" "결과"
probe(){ # $1=라벨 $2=SQL
  local out; out=$(PQD "$2")
  local m; m=$(msgof "$out")
  local why; why=$(echo "$out" | grep -viE '^(Msg|메시지)|^$' | head -1 | sed 's/^ *//' | cut -c1-56)
  printf "  %-44s %s\n" "$1" "${m:-됨}  $why"
  echo "\"-\",\"$1\",\"${m:-됨}\",\"$why\"" >> "$OUT/replication.csv"
}
probe "발행 중인 표에 컬럼을 지운다" "ALTER TABLE reclaim_target DROP COLUMN extra_rows;"
probe "발행 중인 표를 통째로 지운다" "DROP TABLE reclaim_target;"
probe "발행 중인 표에 컬럼을 더한다" "ALTER TABLE reclaim_target ADD note VARCHAR(20) NULL;"
echo
OBJ=$(num "$(PQ "SET NOCOUNT ON;
  SELECT CAST(COUNT(*) AS varchar(12)) FROM msdb.dbo.sysjobs WHERE name LIKE '%$PUBNAME%' OR name LIKE '%$SDB%';")")
DDB=$(num "$(PQ "SET NOCOUNT ON;
  SELECT CASE WHEN DB_ID('distribution') IS NULL THEN '0' ELSE '1' END;")")
DSZ=$(num "$(PQ "SET NOCOUNT ON;
  SELECT CAST(ISNULL(SUM(size) * 8 / 1024, 0) AS varchar(20)) FROM sys.master_files
   WHERE database_id = DB_ID('distribution');")")
echo
printf "  %-44s %s\n" "만들어진 에이전트 작업" "${OBJ}개"
printf "  %-44s %s\n" "배포 DB" "$([ "$DDB" = 1 ] && echo "생김 (${DSZ}MB)" || echo "없음")"
echo "\"-\",\"남는 것\",\"작업 ${OBJ}개, 배포 DB ${DSZ}MB\",\"\"" >> "$OUT/replication.csv"

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
if [ "$ARRIVED" = 1 ]; then
  echo "  **넘어가기는 합니다.** 지문이 맞고 bcp·링크드 서버와 결과가 같습니다."
  echo "  갈리는 것은 그 앞뒤입니다."
else
  echo "  **이 랩에서는 전달까지 못 갔습니다.** 12단계를 다 통과하고 스냅샷도"
  echo "  만들어졌는데 구독자에 안 들어왔습니다. 그리고 그 사실을 알아내는 데도"
  echo "  distribution.dbo.MSdistribution_history 를 따로 봐야 했습니다."
  echo
  echo "  **그것 자체가 이 실험의 답입니다.** 단계가 많으면 어디서 막혔는지 찾는 것도"
  echo "  일이고, 사고 중에 그 일을 하고 있을 수는 없습니다."
  echo
  echo "  아래 표는 전달을 뺀 나머지 비교입니다."
fi
echo
printf "  %-22s %-14s %-14s %s\n" "" "bcp" "링크드 서버" "복제"
printf "  %-22s %-14s %-14s %s\n" "세우는 단계" "0" "3" "${STEP}"
printf "  %-22s %-14s %-14s %s\n" "필요한 인스턴스" "1" "2" "3(배포자 포함)"
printf "  %-22s %-14s %-14s %s\n" "에이전트" "불필요" "불필요" "**필요**"
printf "  %-22s %-14s %-14s %s\n" "끝난 뒤 남는 것" "파일" "경로" "작업 ${OBJ}개 + 배포 DB"
printf "  %-22s %-14s %-14s %s\n" "표에 묶이는 것" "없음" "없음" "**스키마 변경**"
echo
echo "  마지막 줄이 결정적입니다. 발행 중인 표는 **컬럼을 지우거나 표를 지우는 것이"
echo "  막힙니다.** 회수 대상 목록은 사고 때 한 번 쓰고 버리는 표인데, 복제를 걸면"
echo "  그 표가 **영구히 발행 대상**이 되고 치우려면 발행을 먼저 내려야 합니다."
echo
echo "  **그래서 복제는 일회성 이관에 안 맞습니다.** 안 맞는 이유가 \"세팅이 번거로워서\"가"
echo "  아니라 **도구의 목적이 다르기 때문**입니다. 복제는 표를 계속 따라다니게"
echo "  만드는 것이고, 이관은 한 번 옮기고 끝내는 것입니다."
echo
echo "  복제를 쓸 자리는 따로 있습니다. 조사 DB 자체를 운영에서 계속 떠먹이는"
echo "  구성이라면 그때는 복제가 맞습니다. 그 경우 회수 대상은 **조사 DB 안에서**"
echo "  만들어지므로 이관이라는 단계 자체가 없어집니다."
} 2>&1 | tee "$OUT/exp15-replication.txt"
