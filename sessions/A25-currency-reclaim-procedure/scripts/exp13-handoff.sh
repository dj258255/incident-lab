#!/usr/bin/env bash
# 실험 13. 이관의 두 구멍.
#
# 실험 5는 조사 DB 에서 운영 DB 로 회수 대상을 bcp 로 넘기고 세 조건을 봤다.
# 못 한 것에 둘을 남겼다.
#   "이관 방법을 bcp 하나만 재봤습니다. 링크드 서버나 복제로 넘기는 경우는
#    안 쟀습니다. bcp 는 파일이 남아 검증이 쉬운 대신 파일 자체가 새는 자리가 됩니다."
#   "이관 중 조사 DB 가 바뀌는 경우를 안 봤습니다. 뽑는 동안 조사 쿼리가 계속 돌아
#    대상이 늘어나면 사본이 원본과 달라집니다."
#
# 둘째가 더 위험하다. 첫째는 방법의 차이지만 둘째는 **어느 방법을 써도 생기는 구멍**
# 이고, 조용히 틀린다. 옮기는 동안 원본이 움직이면 사본은 어느 시점의 것도 아니게 된다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

SRC_CT=a24-mssql
SRC_DB=lostark_log
LS=INVESTIGATE            # 링크드 서버 이름
SRC_NET=a24-currency-anomaly-detection_default

wait_ready || exit 2
docker ps --format '{{.Names}}' | grep -q "^${SRC_CT}$" \
  || { echo "중단: $SRC_CT 이 안 떠 있습니다. A24 세션을 먼저 올립니다" >&2; exit 2; }

# 두 컨테이너는 각자의 compose 네트워크에 있어 서로 이름을 못 찾는다.
# 링크드 서버를 걸려면 붙여 줘야 한다. 이것 자체가 실무의 자리다.
# 조사 DB 와 운영 DB 사이에 **경로를 뚫는 일**이고, 그 경로는 뚫은 뒤에 남는다.
docker network connect "$SRC_NET" "$CT" >/dev/null 2>&1 || true
REACH=$(docker exec "$CT" bash -c "getent hosts $SRC_CT >/dev/null 2>&1 && echo YES || echo NO" 2>/dev/null)
[ "$REACH" = "YES" ] || { echo "중단: $CT 에서 $SRC_CT 을 못 찾습니다" >&2; exit 2; }

SRCQ(){ docker exec "$SRC_CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$SRC_DB" -Q "$1" 2>&1; }

{
echo "# 실험 13. 이관의 두 구멍"
echo
echo "  조사 DB(${SRC_CT}/${SRC_DB})에서 운영 DB(${CT}/${DB})로 회수 대상을 넘깁니다."
echo "  실험 5는 bcp 만 봤습니다. 여기서는 링크드 서버를 견주고,"
echo "  **옮기는 동안 원본이 바뀌는 경우**를 봅니다."
echo

# ── 조사 쪽에 대상 표를 만든다 ──────────────────────────────────────────
SRCQ "SET NOCOUNT ON;
DROP TABLE IF EXISTS handoff_src;
CREATE TABLE handoff_src (
    account_id   INT    NOT NULL PRIMARY KEY,
    extra_rows   INT    NOT NULL,
    extra_amount BIGINT NOT NULL
);
WITH n AS (SELECT TOP (5000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
             FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO handoff_src (account_id, extra_rows, extra_amount)
SELECT i, 3, 6000 FROM n;" >/dev/null
SRC_N=$(num "$(SRCQ "SELECT COUNT(*) FROM handoff_src")")
SRC_SUM=$(num "$(SRCQ "SELECT CAST(SUM(extra_amount) AS varchar(30)) FROM handoff_src")")
[ "${SRC_N:-0}" = "5000" ] || { echo "중단: 조사 쪽 적재가 ${SRC_N}행입니다" >&2; exit 2; }
printf "  %-26s %s\n" "조사 쪽 대상" "${SRC_N}계정 / 합계 ${SRC_SUM}"
echo

# ── 링크드 서버 ─────────────────────────────────────────────────────────
QD "IF EXISTS (SELECT 1 FROM sys.servers WHERE name = '$LS')
      EXEC sp_dropserver @server = '$LS', @droplogins = 'droplogins';" >/dev/null 2>&1
LSOUT=$(QD "EXEC sp_addlinkedserver @server = '$LS', @srvproduct = '',
              @provider = 'MSOLEDBSQL', @datasrc = '$SRC_CT';
            EXEC sp_addlinkedsrvlogin @rmtsrvname = '$LS', @useself = 'false',
              @rmtuser = 'sa', @rmtpassword = '$PW';
            EXEC sp_serveroption '$LS', 'rpc out', 'true';")
LSMSG=$(echo "$LSOUT" | grep -oE '^(Msg|메시지) [0-9]+' | head -1)

: > "$OUT/handoff.csv"
echo "method,rows,sum,verified,note" >> "$OUT/handoff.csv"
printf "  %-28s %-10s %-14s %-10s %s\n" "방법" "행 수" "합계" "지문 일치" "비고"

prep_dst(){ QDX "SET NOCOUNT ON; DROP TABLE IF EXISTS handoff_dst;
  CREATE TABLE handoff_dst (account_id INT NOT NULL PRIMARY KEY,
    extra_rows INT NOT NULL, extra_amount BIGINT NOT NULL);"; }

# 지문. 실험 5에서 쓴 것과 같은 방법이다. 행 수와 합계만으로는 값이 뒤바뀐 것을 못 잡는다.
fp_src(){ num "$(SRCQ "SET NOCOUNT ON;
  SELECT CAST(COUNT(*) AS varchar(12)) + ',' + CAST(SUM(extra_amount) AS varchar(30)) + ',' +
         CAST(CHECKSUM_AGG(BINARY_CHECKSUM(account_id, extra_rows, extra_amount)) AS varchar(20))
    FROM handoff_src;")"; }
fp_dst(){ num "$(QD "SET NOCOUNT ON;
  SELECT CAST(COUNT(*) AS varchar(12)) + ',' + CAST(ISNULL(SUM(extra_amount),0) AS varchar(30)) + ',' +
         CAST(ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(account_id, extra_rows, extra_amount)),0) AS varchar(20))
    FROM handoff_dst;")"; }

report(){ # $1=라벨 $2=비고
  local a b; a=$(fp_src); b=$(fp_dst)
  local ar as ac br bs bc
  IFS=, read -r ar as ac <<<"$a"; IFS=, read -r br bs bc <<<"$b"
  local v="일치"; [ "$a" = "$b" ] || v="**어긋남**"
  printf "  %-28s %-10s %-14s %-10s %s\n" "$1" "$br" "$bs" "$v" "$2"
  echo "\"$1\",$br,$bs,\"$v\",\"$2\"" >> "$OUT/handoff.csv"
}

echo "### 13-1. 링크드 서버로 넘기기"
echo
if [ -n "$LSMSG" ]; then
  echo "  링크드 서버를 못 만들었습니다: $LSMSG"
  echo "$LSOUT" | grep -viE '^(Msg|메시지)|^$' | head -1 | sed 's/^/    /'
else
  prep_dst || exit 2
  PULL=$(QD "SET NOCOUNT ON;
    INSERT INTO handoff_dst (account_id, extra_rows, extra_amount)
    SELECT account_id, extra_rows, extra_amount
      FROM [$LS].[$SRC_DB].[dbo].[handoff_src];")
  PMSG=$(echo "$PULL" | grep -oE '^(Msg|메시지) [0-9]+' | head -1)
  if [ -n "$PMSG" ]; then
    echo "  당겨오기 실패: $PMSG"
    echo "$PULL" | grep -viE '^(Msg|메시지)|^$' | head -2 | sed 's/^/    /'
  else
    report "링크드 서버(당겨오기)" "파일이 안 남는다"
  fi
fi
echo

echo "### 13-2. bcp 로 넘기기"
echo
prep_dst || exit 2
docker exec "$SRC_CT" /opt/mssql-tools18/bin/bcp \
  "SELECT account_id, extra_rows, extra_amount FROM handoff_src ORDER BY account_id" \
  queryout /tmp/handoff.dat -S localhost -U sa -P "$PW" -d "$SRC_DB" -c -t'|' -u >/dev/null 2>&1
docker cp "$SRC_CT":/tmp/handoff.dat /tmp/handoff.dat >/dev/null 2>&1
docker cp /tmp/handoff.dat "$CT":/tmp/handoff.dat >/dev/null 2>&1
docker exec "$CT" /opt/mssql-tools18/bin/bcp handoff_dst in /tmp/handoff.dat \
  -S localhost -U sa -P "$PW" -d "$DB" -c -t'|' -u >/dev/null 2>&1
report "bcp(파일 경유)" "파일이 남는다"
FILE_LEFT=$(docker exec "$CT" sh -c 'ls -1 /tmp/handoff.dat 2>/dev/null | wc -l' | tr -d ' \r')
echo
printf "  %-28s %s\n" "이관이 끝난 뒤 남은 파일" "${FILE_LEFT}개"
echo "  **회수 대상 목록은 이용자 식별자와 금액이 담긴 파일입니다.** 이관이 끝나면"
echo "  지워야 하는데, 지우는 절차를 안 만들면 그대로 남습니다."
echo

echo "### 13-3. 옮기는 동안 원본이 바뀌면"
echo
echo "  조사 쿼리는 사고 중에도 계속 돕니다. 대상 표가 자라는 동안 옮기면"
echo "  사본은 **어느 시점의 것도 아니게** 됩니다. 두 방법을 견줍니다."
echo
grow_start(){ # 원본에 계속 대상을 추가한다
  docker exec "$SRC_CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$SRC_DB" \
    -Q "SET NOCOUNT ON;
        DECLARE @i INT = 0;
        WHILE @i < 40
        BEGIN
            INSERT INTO handoff_src (account_id, extra_rows, extra_amount)
            SELECT TOP (50) 900000 + @i * 100 + ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 3, 6000
              FROM sys.all_objects;
            WAITFOR DELAY '00:00:00.200';
            SET @i = @i + 1;
        END" >/dev/null 2>&1 &
  GROW=$!
}

# A 그냥 옮긴다. 옮기는 동안 원본이 자란다.
prep_dst || exit 2
grow_start
sleep 1
QD "SET NOCOUNT ON;
  INSERT INTO handoff_dst (account_id, extra_rows, extra_amount)
  SELECT account_id, extra_rows, extra_amount FROM [$LS].[$SRC_DB].[dbo].[handoff_src];" >/dev/null 2>&1
wait "$GROW" 2>/dev/null
report "A 그냥 옮긴다" "원본이 자라는 중"

# B 스냅샷을 뜨고 그것을 옮긴다. 원본이 자라도 스냅샷은 안 변한다.
SRCQ "SET NOCOUNT ON;
DELETE FROM handoff_src WHERE account_id >= 900000;" >/dev/null
prep_dst || exit 2
SRCQ "SET NOCOUNT ON;
DROP TABLE IF EXISTS handoff_snap;
SELECT account_id, extra_rows, extra_amount INTO handoff_snap FROM handoff_src;
ALTER TABLE handoff_snap ADD PRIMARY KEY (account_id);" >/dev/null
SNAP_FP=$(num "$(SRCQ "SET NOCOUNT ON;
  SELECT CAST(COUNT(*) AS varchar(12)) + ',' + CAST(SUM(extra_amount) AS varchar(30)) + ',' +
         CAST(CHECKSUM_AGG(BINARY_CHECKSUM(account_id, extra_rows, extra_amount)) AS varchar(20))
    FROM handoff_snap;")")
grow_start
sleep 1
QD "SET NOCOUNT ON;
  INSERT INTO handoff_dst (account_id, extra_rows, extra_amount)
  SELECT account_id, extra_rows, extra_amount FROM [$LS].[$SRC_DB].[dbo].[handoff_snap];" >/dev/null 2>&1
wait "$GROW" 2>/dev/null
DST_FP=$(fp_dst)
SNAP_V="일치"; [ "$SNAP_FP" = "$DST_FP" ] || SNAP_V="**어긋남**"
IFS=, read -r BR BS BC <<<"$DST_FP"
printf "  %-28s %-10s %-14s %-10s %s\n" "B 스냅샷을 뜨고 옮긴다" "$BR" "$BS" "$SNAP_V" "스냅샷 기준"
echo "\"B 스냅샷을 뜨고 옮긴다\",$BR,$BS,\"$SNAP_V\",\"스냅샷 기준\"" >> "$OUT/handoff.csv"

# 정리
SRCQ "DROP TABLE IF EXISTS handoff_src; DROP TABLE IF EXISTS handoff_snap;" >/dev/null
QD "DROP TABLE IF EXISTS handoff_dst;" >/dev/null
QD "IF EXISTS (SELECT 1 FROM sys.servers WHERE name = '$LS')
      EXEC sp_dropserver @server = '$LS', @droplogins = 'droplogins';" >/dev/null 2>&1
docker exec "$CT" rm -f /tmp/handoff.dat >/dev/null 2>&1
docker exec "$SRC_CT" rm -f /tmp/handoff.dat >/dev/null 2>&1
rm -f /tmp/handoff.dat

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  **A 는 어긋납니다.** 옮기는 동안 원본이 자랐고, 사본은 옮기기 시작한 시점의"
echo "  것도 끝난 시점의 것도 아닙니다. 그 사이 어딘가입니다."
echo "  더 나쁜 것은 **행 수와 합계만 보면 그럴듯해 보인다**는 것입니다."
echo "  둘 다 원본보다 작을 뿐 이상한 값이 아닙니다. 지문을 대조해야 드러납니다."
echo
echo "  **B 는 맞습니다.** 스냅샷을 뜨는 순간 대상이 확정되고, 그 뒤에 원본이 자라도"
echo "  옮기는 것은 스냅샷입니다. 실험 5의 지문 대조가 여기서 의미를 갖습니다."
echo "  대조할 기준이 **움직이지 않아야** 대조가 성립합니다."
echo
echo "  이관 방법 자체는 둘 다 됩니다. 갈리는 것은 남는 것입니다."
echo "    링크드 서버  파일이 안 남는다. 대신 두 서버 사이에 **경로가 남는다**"
echo "    bcp          경로가 안 남는다. 대신 **파일이 남는다**"
echo
echo "  회수 대상 목록은 이용자 식별자와 금액이 담긴 파일입니다. 어느 쪽을 쓰든"
echo "  **이관이 끝난 뒤에 치우는 절차**가 있어야 하고, 그것을 안 만들면 둘 중"
echo "  하나가 그대로 남습니다. 이 실험도 링크드 서버를 걸려고 네트워크를 붙였고,"
echo "  그 연결은 스크립트가 안 끊으면 남습니다."
echo
echo "  운영으로 옮기면 이렇게 됩니다."
echo "    **스냅샷을 뜨고 그것을 옮긴다.** 원본이 자라는 것과 무관해진다"
echo "    지문은 스냅샷 기준으로 만든다. 원본 기준으로 만들면 대조가 매번 어긋난다"
echo "    이관이 끝나면 파일이든 경로든 치운다. 치우는 것도 절차에 넣는다"
} 2>&1 | tee "$OUT/exp13-handoff.txt"
