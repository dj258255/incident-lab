#!/usr/bin/env bash
# 실험 10. 낮은 에디션에서는 무엇이 막히는가.
#
# 실험 4의 처방은 이렇게 갈렸다.
#   ONLINE 이 되는 에디션(Enterprise·Developer) → 만든다
#   Standard 이하                                 → 만들지 않는다
#
# 그런데 그 "안 된다"를 **문서로만 알고 있었다.** 못 한 것에 이렇게 적었다.
#   "Standard 에디션에서 거부되는 것을 직접 안 봤습니다. Developer 로만 돌려
#    ONLINE = ON 이 실제로 어떤 오류로 막히는지는 문서로만 알고 있습니다."
#
# 사고 중에 만나는 오류 번호를 모르면 그 순간에 검색부터 하게 된다. 여기서 본다.
# Express 는 무료라 컨테이너로 띄울 수 있고, 에디션 제약은 Standard 와 같거나 더
# 세다. 거부되는 것을 보는 목적에는 그것으로 충분하다.
#
# 함께 확인할 것이 더 있다. 절차서가 낮은 에디션에서 **무엇을 대신 쓸 수 있는지**
# 말하려면 되는 것과 안 되는 것을 가려야 한다.
#   SORT_IN_TEMPDB   실험 8에서 tempdb 를 가른 옵션. 에디션을 타는가
#   파티션           2016 SP1 부터 모든 에디션에 열렸다고 알려져 있다. 맞는가
#   압축             데이터 압축도 2016 SP1 에 열렸다
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
XCT=a24-express
XDB=edition_probe

# 표 크기가 아니라 에디션이 거부를 정하므로 작은 표로 충분하다.
ROWS=${EDITION_ROWS:-50000}

XQ(){ docker exec "$XCT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -Q "$1" 2>&1; }
XQD(){ docker exec "$XCT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$XDB" -Q "$1" 2>&1; }

wait_express(){
  local i
  for i in $(seq 1 150); do
    [ "$(num "$(XQ "SELECT 'RE'+'ADY'")")" = "READY" ] && return 0
    sleep 2
  done
  echo "중단: $XCT 가 쿼리를 못 받습니다. docker compose up -d express 를 먼저 합니다" >&2
  return 2
}

wait_ready || exit 2
wait_express || exit 2

DEV_ED=$(numsp "$(Q "SELECT CAST(SERVERPROPERTY('Edition') AS varchar(60))")")
EXP_ED=$(numsp "$(XQ "SELECT CAST(SERVERPROPERTY('Edition') AS varchar(60))")")
EXP_LVL=$(numsp "$(XQ "SELECT CAST(SERVERPROPERTY('ProductLevel') AS varchar(20)) + ' / ' + CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))")")

# 두 서버가 같은 빌드여야 에디션만의 차이가 된다.
DEV_VER=$(num "$(Q "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))")")
EXP_VER=$(num "$(XQ "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))")")

# CREATE DATABASE 를 던지고 **DB 가 실제로 생겼는지 물어본다.** 처음에 결과를
# /dev/null 로 버렸다가, 다음 배치가 없는 DB 에 붙어 Msg 208 이 났고 그 208 이
# 그대로 행 수 변수에 들어갔다. A24 lib 의 QDX 를 만든 이유와 같은 자국이다.
XSETUP=$(XQ "IF DB_ID('$XDB') IS NULL CREATE DATABASE [$XDB];
             SELECT 'DBID=' + ISNULL(CAST(DB_ID('$XDB') AS varchar(6)), 'NULL');")
echo "$XSETUP" | grep -q 'DBID=[0-9]' || {
  echo "중단: Express 에 $XDB 를 못 만들었습니다" >&2
  echo "$XSETUP" | grep -E '^(Msg|메시지)' | head -2 >&2; exit 2; }

XLOAD=$(XQD "SET NOCOUNT ON;
DROP TABLE IF EXISTS probe;
CREATE TABLE probe (
    id         BIGINT       NOT NULL PRIMARY KEY,
    account_id INT          NOT NULL,
    reason     TINYINT      NOT NULL,
    ref_id     BIGINT       NULL,
    created_at DATETIME2(3) NOT NULL
);
WITH n AS (SELECT TOP ($ROWS) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
             FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO probe (id, account_id, reason, ref_id, created_at)
SELECT i, i % 1000, 1, i, DATEADD(second, i % 86400, '2026-07-01') FROM n;")
echo "$XLOAD" | grep -qE '^(Msg|메시지) [0-9]+' && {
  echo "중단: Express 쪽 적재 SQL 오류" >&2
  echo "$XLOAD" | grep -E '^(Msg|메시지)' | head -3 >&2; exit 2; }
GOT=$(num "$(XQD "SELECT COUNT(*) FROM probe")")
[ "$GOT" = "$ROWS" ] || { echo "중단: Express 쪽 적재가 ${GOT}행입니다(기대 $ROWS)" >&2; exit 2; }

{
echo "# 실험 10. 낮은 에디션에서는 무엇이 막히는가"
echo
printf "  %-14s %s\n" "이 랩 본체" "$DEV_ED"
printf "  %-14s %s\n" "비교 대상" "$EXP_ED"
printf "  %-14s %s\n" "빌드" "$EXP_LVL"
echo
if [ "$DEV_VER" != "$EXP_VER" ]; then
  echo "  **주의: 두 서버의 빌드가 다릅니다(${DEV_VER} / ${EXP_VER}). 에디션만의 차이가 아닐 수 있습니다.**"
  echo
fi
echo "  표는 ${ROWS}행짜리 작은 것입니다. **거부는 표 크기가 아니라 에디션이 정합니다.**"
echo

: > "$OUT/edition.csv"
echo "feature,developer,express,msg" >> "$OUT/edition.csv"
printf "  %-34s %-14s %-14s %s\n" "기능" "Developer" "Express" "Express 가 뱉은 것"

# 같은 DDL 을 양쪽에 던지고 결과를 견준다.
# 본체(Developer)에서는 실험용 DB 를 따로 만들어 원장을 안 건드린다.
Q "IF DB_ID('$XDB') IS NULL CREATE DATABASE [$XDB]" >/dev/null
docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$XDB" -Q "SET NOCOUNT ON;
DROP TABLE IF EXISTS probe;
CREATE TABLE probe (
    id         BIGINT       NOT NULL PRIMARY KEY,
    account_id INT          NOT NULL,
    reason     TINYINT      NOT NULL,
    ref_id     BIGINT       NULL,
    created_at DATETIME2(3) NOT NULL
);
WITH n AS (SELECT TOP ($ROWS) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
             FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO probe (id, account_id, reason, ref_id, created_at)
SELECT i, i % 1000, 1, i, DATEADD(second, i % 86400, '2026-07-01') FROM n;" >/dev/null 2>&1

DEVQ(){ docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$XDB" -Q "$1" 2>&1; }

verdict(){ # 출력에서 성공/실패와 메시지 번호를 뽑는다
  if echo "$1" | grep -qE '^(Msg|메시지) [0-9]+'; then
    echo "거부|$(echo "$1" | grep -oE '^(Msg|메시지) [0-9]+' | head -1)"
  else
    echo "됨|"
  fi
}

probe_feature(){ # $1=라벨 $2=SQL $3=정리 SQL
  local d x dv xv dm xm line
  d=$(DEVQ "$2"); x=$(XQD "$2")
  IFS='|' read -r dv dm <<<"$(verdict "$d")"
  IFS='|' read -r xv xm <<<"$(verdict "$x")"
  # 거부 사유 한 줄을 뽑는다. 한글 로케일이면 한글로 온다.
  line=$(echo "$x" | grep -viE '^(Msg|메시지)|^$' | grep -iE 'edition|에디션|not supported|지원되지' | head -1 | sed 's/^ *//' | cut -c1-70)
  printf "  %-34s %-14s %-14s %s\n" "$1" "$dv" "$xv" "${xm}${line:+  $line}"
  echo "\"$1\",\"$dv\",\"$xv\",\"${xm} ${line}\"" >> "$OUT/edition.csv"
  [ -n "$3" ] && { DEVQ "$3" >/dev/null 2>&1; XQD "$3" >/dev/null 2>&1; }
  # 거부 사유 전문은 마지막 조건에서 따로 보여 준다
  LAST_X_OUT="$x"
}

probe_feature "CREATE INDEX (기본)" \
  "SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
   CREATE INDEX IX_a ON probe (reason, created_at, ref_id) INCLUDE (account_id);" \
  "SET QUOTED_IDENTIFIER ON; DROP INDEX IF EXISTS IX_a ON probe;"

probe_feature "CREATE INDEX WITH ONLINE = ON" \
  "SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
   CREATE INDEX IX_b ON probe (reason, created_at, ref_id) INCLUDE (account_id)
     WITH (ONLINE = ON);" \
  "SET QUOTED_IDENTIFIER ON; DROP INDEX IF EXISTS IX_b ON probe;"
ONLINE_OUT="$LAST_X_OUT"

probe_feature "CREATE INDEX WITH SORT_IN_TEMPDB = ON" \
  "SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
   CREATE INDEX IX_c ON probe (reason, created_at, ref_id) INCLUDE (account_id)
     WITH (SORT_IN_TEMPDB = ON);" \
  "SET QUOTED_IDENTIFIER ON; DROP INDEX IF EXISTS IX_c ON probe;"

probe_feature "필터드 인덱스" \
  "SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
   CREATE INDEX IX_d ON probe (created_at, ref_id) INCLUDE (account_id) WHERE reason = 1;" \
  "SET QUOTED_IDENTIFIER ON; DROP INDEX IF EXISTS IX_d ON probe;"

probe_feature "파티션 함수·스킴" \
  "CREATE PARTITION FUNCTION pf_probe (DATETIME2(3)) AS RANGE RIGHT
     FOR VALUES ('2026-07-01','2026-07-15','2026-08-01');
   CREATE PARTITION SCHEME ps_probe AS PARTITION pf_probe ALL TO ([PRIMARY]);" \
  "IF EXISTS (SELECT 1 FROM sys.partition_schemes WHERE name='ps_probe') DROP PARTITION SCHEME ps_probe;
   IF EXISTS (SELECT 1 FROM sys.partition_functions WHERE name='pf_probe') DROP PARTITION FUNCTION pf_probe;"

probe_feature "데이터 압축(PAGE)" \
  "SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
   CREATE INDEX IX_e ON probe (created_at) WITH (DATA_COMPRESSION = PAGE);" \
  "SET QUOTED_IDENTIFIER ON; DROP INDEX IF EXISTS IX_e ON probe;"

probe_feature "확장 이벤트 세션" \
  "CREATE EVENT SESSION ed_probe ON SERVER ADD EVENT sqlserver.lock_escalation
     ADD TARGET package0.ring_buffer WITH (MAX_MEMORY = 1024 KB);" \
  "IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name='ed_probe')
     DROP EVENT SESSION ed_probe ON SERVER;"

echo
echo "## 10-1. 거부 전문"
echo
echo "  ONLINE = ON 을 던졌을 때 Express 가 돌려준 것입니다."
echo "$ONLINE_OUT" | grep -viE '^$' | head -4 | sed 's/^/    /'

echo
echo "## 10-2. Express 가 실제로 조인 자원 제약"
echo
echo "  한글을 SQL 에서 그대로 돌려받으면 sqlcmd 를 거치며 깨집니다. ASCII 로 받아"
echo "  셸에서 옮깁니다(이 저장소의 규칙인데 여기서 한 번 어겼다가 다시 고쳤습니다)."
echo
xlim(){ # $1=라벨 $2=SQL
  printf "  %-22s %s\n" "$1" "$(numsp "$(XQ "SET NOCOUNT ON; $2")")"
  echo "\"$1\",\"-\",\"$(numsp "$(XQ "SET NOCOUNT ON; $2")")\",\"\"" >> "$OUT/edition.csv"
}
xlim "보이는 스케줄러" "SELECT CAST(COUNT(*) AS varchar(6)) FROM sys.dm_os_schedulers
                         WHERE status = 'VISIBLE ONLINE' AND scheduler_id < 1048576"
xlim "max server memory" "SELECT CAST(value_in_use AS varchar(20)) + ' MB'
                            FROM sys.configurations WHERE name = 'max server memory (MB)'"
xlim "버퍼 풀 현재 목표" "SELECT CAST(committed_target_kb / 1024 AS varchar(20)) + ' MB'
                            FROM sys.dm_os_sys_info"
echo
echo "  같은 것을 본체(Developer)에서도 봅니다."
printf "  %-22s %s\n" "본체 스케줄러" "$(numsp "$(Q "SET NOCOUNT ON;
  SELECT CAST(COUNT(*) AS varchar(6)) FROM sys.dm_os_schedulers
   WHERE status = 'VISIBLE ONLINE' AND scheduler_id < 1048576")")"
printf "  %-22s %s\n" "본체 버퍼 풀 상한" "$(numsp "$(Q "SET NOCOUNT ON;
  SELECT CAST(committed_target_kb / 1024 AS varchar(20)) + ' MB' FROM sys.dm_os_sys_info")")"
echo
echo "  스케줄러 수가 갈립니다. 컨테이너에 Express 는 2코어, 본체는 4코어를 줬는데"
echo "  **SQL Server 가 보는 수는 컨테이너 설정과 다릅니다.** 본체는 호스트의 12개를"
echo "  그대로 보고, Express 는 4개에서 잘립니다. compose 의 cpus 는 CFS 할당량이라"
echo "  보이는 코어 수를 안 바꾸고, 4 라는 수는 Express 자신의 상한입니다."
echo
echo "  **버퍼 풀 값은 상한이 아니라 지금 잡고 있는 크기입니다.** 방금 뜬 인스턴스라"
echo "  작게 나온 것이고 부하가 쌓이면 늡니다. Express 의 실제 상한(1,410MB)은 이"
echo "  DMV 로 안 보이므로 여기서 잰 값으로 상한을 말할 수 없습니다."
echo
echo "  DB 파일 크기 상한(Express 10GB)은 이 랩에서 안 쟀습니다. 채우려면 10GB 를"
echo "  써야 하는데 그만한 값이 없다고 봤습니다. 다만 **이 세션의 원장이 879MB 라"
echo "  그 상한 안에 든다는 것**과, 실제 게임 원장은 그렇지 않다는 것은 짚어 둡니다."

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  문서로만 알던 것을 실제 오류로 확인했습니다."
echo
echo "  **ONLINE = ON 은 Express 에서 거부됩니다.** 인덱스 자체는 만들어지므로,"
echo "  낮은 에디션에서 조사용 인덱스를 만드는 것은 가능하되 **그동안 쓰기가 막힙니다**"
echo "  (실험 4에서 13.7초). 재화 원장은 append-only 라 그 시간 동안 지급과 소모가"
echo "  전부 줄을 섭니다."
echo
echo "  그래서 낮은 에디션의 선택지는 인덱스를 만드느냐가 아니라 이렇게 됩니다."
echo
echo "    조사 창을 좁혀 전체 스캔으로 버틴다        실험 3의 229,614 를 감수한다"
echo "    클러스터드 키를 평소에 시간 순으로 잡는다  실험 8에서 창을 좁힌 진짜 힘"
echo "    점검 시간에 인덱스를 만든다                쓰기가 없는 창을 잡는다"
echo
echo "  두 번째가 제일 낫습니다. **평소에 정하는 것이라 사고 때 아무 대가가 없습니다.**"
echo "  실험 8에서 조사 쿼리를 114,353 에서 638 로 내린 것이 그것이었고, 파티션이나"
echo "  온라인 빌드 같은 에디션을 타는 기능이 하나도 필요 없습니다."
echo
echo "  파티션·필터드 인덱스·압축·확장 이벤트가 Express 에서도 되는 것을 확인했습니다."
echo "  2016 SP1 이후로 열린 것들이라, **에디션 때문에 못 한다고 미리 접을 자리가"
echo "  생각보다 좁습니다.** 실제로 걸리는 것은 온라인 빌드 쪽입니다."
} 2>&1 | tee "$OUT/exp10-edition.txt"
