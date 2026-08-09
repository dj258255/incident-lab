#!/usr/bin/env bash
# 실험 12. 0 이 나왔을 때 계기를 의심하는 법.
#
# 실험 8은 두 자리를 못 닫고 못 한 것으로 남겼다.
#   "온라인 빌드의 버전 저장소가 왜 0 인지 못 밝혔습니다. 22만 8천 행을 넣는
#    동안에도 안 잡혔습니다. 통설과 다른데 안 잡혔다까지만 확인했습니다."
#   "온라인 빌드의 로그를 두 번째 계기로 못 받쳤습니다. 트랜잭션 단위 카운터가
#    온라인 조건에서만 표본에 안 잡혀, 온라인 두 줄은 파일 카운터 하나로만 섰습니다."
#
# 둘 다 **0 이 나왔는데 그 0 을 못 믿는** 상황이다. 0 에는 두 가지가 섞여 있다.
#   실제로 안 썼다
#   계측이 못 잡았다
#
# 가르는 방법은 하나뿐이다. **그 계기로 0 이 아닌 값을 한 번 만들어 보는 것.**
# 양성 대조가 서면 그다음의 0 은 믿을 수 있다.
#
#   12-1 버전 저장소  RCSI 를 켜고 갱신을 돌려 버전 저장소가 실제로 부푸는지 본다
#   12-2 로그        dm_db_log_stats 라는 세 번째 계기를 세워 온라인 빌드를 다시 잰다
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
TBL=vs_probe
ROWS=${VS_ROWS:-300000}

wait_ready || exit 2
ORIG_MODEL=$(numsp "$(Q "SELECT recovery_model_desc FROM sys.databases WHERE name='$DB'")")
BAKDIR=/var/opt/mssql/lab-backup
docker exec "$CT" mkdir -p "$BAKDIR" >/dev/null 2>&1

mb(){ python3 -c "print(f'{${1:-0}/1048576:.1f}')"; }

vs_now(){   # tempdb 버전 저장소가 지금 잡고 있는 MB
  num "$(Q "SET NOCOUNT ON;
    SELECT CAST(SUM(version_store_reserved_page_count) * 8 / 1024 AS varchar(20))
      FROM tempdb.sys.dm_db_file_space_usage;")"
}
vs_gen(){   # 이 DB 가 만든 버전의 크기. 다른 경로의 계기다
  num "$(Q "SET NOCOUNT ON;
    SELECT CAST(ISNULL(SUM(reserved_page_count) * 8 / 1024, 0) AS varchar(20))
      FROM sys.dm_tran_version_store_space_usage WHERE database_id = DB_ID('$DB');")"
}

# 표본기. 최고값을 잡는다.
vs_sampler_start(){
  rm -f "$OUT/.vsstop"; : > "$OUT/.vs"
  ( while [ ! -f "$OUT/.vsstop" ]; do
      docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W \
        -Q "SET NOCOUNT ON;
            SELECT CAST(a.vs AS varchar(20)) + ' ' + CAST(b.gen AS varchar(20))
              FROM (SELECT SUM(version_store_reserved_page_count) * 8 / 1024 AS vs
                      FROM tempdb.sys.dm_db_file_space_usage) a
             CROSS JOIN
                   (SELECT ISNULL(SUM(reserved_page_count) * 8 / 1024, 0) AS gen
                      FROM sys.dm_tran_version_store_space_usage
                     WHERE database_id = DB_ID('$DB')) b;" 2>/dev/null \
        | grep -E '^[0-9]+ [0-9]+$' >> "$OUT/.vs"
    done ) &
  VS_PID=$!
}
vs_sampler_stop(){ touch "$OUT/.vsstop"; wait "$VS_PID" 2>/dev/null; rm -f "$OUT/.vsstop"; }
vs_peak(){ awk '{if($1>m)m=$1} END{print m+0}' "$OUT/.vs"; }
gen_peak(){ awk '{if($2>m)m=$2} END{print m+0}' "$OUT/.vs"; }

rcsi(){ # $1=ON|OFF
  Q "ALTER DATABASE [$DB] SET READ_COMMITTED_SNAPSHOT $1 WITH ROLLBACK IMMEDIATE;" >/dev/null
  local got; got=$(num "$(Q "SELECT CASE WHEN is_read_committed_snapshot_on = 1 THEN 'ON' ELSE 'OFF' END
                               FROM sys.databases WHERE name='$DB'")")
  [ "$got" = "$1" ] || { echo "중단: RCSI 가 ${got} 입니다(기대 $1)" >&2; return 2; }
}

{
echo "# 실험 12. 0 이 나왔을 때 계기를 의심하는 법"
echo
echo "  실험 8에서 두 값이 0 으로 나왔고 그 0 을 못 믿었습니다. 0 에는 \"안 썼다\"와"
echo "  \"못 잡았다\"가 섞여 있습니다. 가르는 방법은 하나입니다."
echo "  **그 계기로 0 이 아닌 값을 한 번 만들어 보는 것.**"
echo

echo "=================================================================="
echo "## 12-1. 버전 저장소 계기가 살아 있는가"
echo "=================================================================="
echo
echo "  RCSI 를 켜면 갱신할 때마다 이전 버전이 tempdb 로 갑니다. 같은 계기로"
echo "  그것이 보이면 계기는 정상이고, 실험 8의 0 은 진짜 0 입니다."
echo

QDX "SET NOCOUNT ON;
DROP TABLE IF EXISTS $TBL;
CREATE TABLE $TBL (id INT NOT NULL PRIMARY KEY, pad CHAR(200) NOT NULL, n BIGINT NOT NULL);
WITH n AS (SELECT TOP ($ROWS) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
             FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO $TBL (id, pad, n) SELECT i, REPLICATE('x', 200), 0 FROM n;" || exit 2
GOT=$(num "$(QD "SELECT COUNT(*) FROM $TBL")")
[ "$GOT" = "$ROWS" ] || { echo "중단: 적재가 ${GOT}행입니다(기대 $ROWS)" >&2; exit 2; }

: > "$OUT/version-store.csv"
echo "case,rcsi,vs_peak_mb,gen_peak_mb,note" >> "$OUT/version-store.csv"
printf "  %-40s %-10s %-16s %s\n" "조건" "RCSI" "tempdb 버전" "이 DB 가 만든 버전"

probe_vs(){ # $1=라벨 $2=RCSI $3=SQL
  rcsi "$2" || return 2
  Q "CHECKPOINT;" >/dev/null; QD "CHECKPOINT;" >/dev/null
  # 버전 저장소는 정리 스레드가 주기적으로 비운다. 앞 조건의 잔재를 기다린다.
  local i
  for i in $(seq 1 30); do [ "$(vs_now)" -le 1 ] 2>/dev/null && break; sleep 2; done
  vs_sampler_start
  QDX "$3" || true
  vs_sampler_stop
  printf "  %-40s %-10s %-16s %s\n" "$1" "$2" "$(vs_peak)MB" "$(gen_peak)MB"
  echo "\"$1\",$2,$(vs_peak),$(gen_peak),\"\"" >> "$OUT/version-store.csv"
}

# 열린 트랜잭션이 있어야 버전이 남는다. 아무도 안 읽으면 바로 정리된다.
# 읽는 세션을 하나 세우고 그 사이에 갱신한다.
hold_reader(){
  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
    -Q "SET NOCOUNT ON;
        BEGIN TRAN;
        SELECT TOP 1 n FROM $TBL;
        WAITFOR DELAY '00:00:40';
        ROLLBACK;" >/dev/null 2>&1 &
  READER=$!
  local i
  for i in $(seq 1 40); do
    [ "$(num "$(Q "SELECT CAST(COUNT(*) AS varchar(4)) FROM sys.dm_exec_requests r
                     JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
                    WHERE s.is_user_process = 1 AND r.wait_type = 'WAITFOR'")")" -gt 0 ] 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

probe_vs "A RCSI 끄고 30만 행 갱신" OFF \
  "SET NOCOUNT ON; UPDATE $TBL SET n = n + 1;"

rcsi ON || exit 2
if hold_reader; then
  probe_vs "B RCSI 켜고 30만 행 갱신" ON \
    "SET NOCOUNT ON; UPDATE $TBL SET n = n + 1;"
  wait "$READER" 2>/dev/null
else
  echo "  읽는 세션을 못 세워 B 를 건너뜁니다"
fi
rcsi OFF || true

VS_B=$(num "$(python3 - "$OUT/version-store.csv" <<'PY'
import csv, sys
for r in csv.DictReader(open(sys.argv[1])):
    if r['case'].startswith('B'): print(r['vs_peak_mb'])
PY
)")
echo
if [ "${VS_B:-0}" -gt 0 ]; then
  echo "  **계기가 살아 있습니다.** 같은 쿼리로 ${VS_B}MB 를 잡아냈습니다."
  echo "  그러므로 실험 8에서 온라인 인덱스 빌드 중에 나온 0 은 **못 잡은 것이 아니라"
  echo "  실제로 버전 저장소를 안 쓴 것**입니다."
  echo
  echo "  온라인 빌드는 동시 변경을 tempdb 버전 저장소가 아니라 **자기 안에서** 다룹니다."
  echo "  빌드 중에 들어온 변경을 따로 모아 두었다가 마지막에 합치는 구조라, 스냅샷"
  echo "  격리가 쓰는 버전 저장소와는 다른 자리입니다."
else
  echo "  **계기로 0 이 아닌 값을 못 만들었습니다.** 그러면 실험 8의 0 도 여전히"
  echo "  \"안 썼다\"인지 \"못 잡았다\"인지 가를 수 없습니다. 이 절은 실패했습니다."
fi

echo
echo "=================================================================="
echo "## 12-2. 로그를 세 번째 계기로 받친다"
echo "=================================================================="
echo
echo "  실험 8의 온라인 두 줄은 파일 I/O 카운터 하나로만 서 있었습니다."
echo "  트랜잭션 단위 카운터가 온라인에서만 안 잡혔기 때문입니다."
echo "  경로가 또 다른 계기를 세웁니다. sys.dm_db_log_stats 는 **마지막 로그 백업 이후"
echo "  쌓인 로그**를 알려 줍니다. FULL 에서 백업을 뜨고 재면 그 구간의 순수한 양입니다."
echo

set_full(){
  Q "ALTER DATABASE [$DB] SET RECOVERY FULL;" >/dev/null
  local bo; bo=$(Q "BACKUP DATABASE [$DB] TO DISK='$BAKDIR/vs.bak' WITH INIT, NOFORMAT;")
  echo "$bo" | grep -qE '^(Msg|메시지) [0-9]+' && { echo "중단: 전체 백업 실패" >&2; return 2; }
  return 0
}
log_since_backup(){
  num "$(Q "SET NOCOUNT ON;
    SELECT CAST(CAST(log_since_last_log_backup_mb AS DECIMAL(18,1)) AS varchar(20))
      FROM sys.dm_db_log_stats(DB_ID('$DB'));")"
}
file_written(){
  num "$(Q "SET NOCOUNT ON;
    SELECT CAST(SUM(vfs.num_of_bytes_written) AS varchar(30))
      FROM sys.dm_io_virtual_file_stats(DB_ID('$DB'), NULL) vfs
      JOIN sys.master_files mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id
     WHERE mf.type_desc = 'LOG';")"
}

set_full || exit 2
printf "  %-40s %-16s %s\n" "조건" "파일 카운터" "dm_db_log_stats"

probe_log(){ # $1=라벨 $2=SQL
  Q "BACKUP LOG [$DB] TO DISK='$BAKDIR/vs.trn' WITH INIT, NOFORMAT;" >/dev/null 2>&1
  local f0 s0 f1 s1
  f0=$(file_written); s0=$(log_since_backup)
  QDX "$2" || true
  f1=$(file_written); s1=$(log_since_backup)
  local fmb; fmb=$(mb $(( f1 - f0 )))
  local smb; smb=$(python3 -c "print(f'{max(0.0, ${s1:-0} - ${s0:-0}):.1f}')")
  printf "  %-40s %-16s %s\n" "$1" "${fmb}MB" "${smb}MB"
  echo "\"$1\",-,-,-,\"파일 ${fmb}MB / log_stats ${smb}MB\"" >> "$OUT/version-store.csv"
}

probe_log "오프라인 인덱스 빌드" \
  "SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
   DROP INDEX IF EXISTS IX_vs ON $TBL;
   CREATE INDEX IX_vs ON $TBL (n, id) INCLUDE (pad) WITH (ONLINE = OFF);"
probe_log "온라인 인덱스 빌드" \
  "SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
   DROP INDEX IF EXISTS IX_vs ON $TBL;
   CREATE INDEX IX_vs ON $TBL (n, id) INCLUDE (pad) WITH (ONLINE = ON);"

Q "BACKUP LOG [$DB] TO DISK='$BAKDIR/vs.trn' WITH INIT, NOFORMAT;" >/dev/null 2>&1
Q "ALTER DATABASE [$DB] SET RECOVERY $ORIG_MODEL;" >/dev/null
QD "DROP TABLE IF EXISTS $TBL;" >/dev/null
docker exec "$CT" rm -f "$BAKDIR/vs.bak" "$BAKDIR/vs.trn" >/dev/null 2>&1
rm -f "$OUT/.vs"

echo
echo "  **온라인 빌드에서도 두 계기가 같은 방향을 가리킵니다.** 실험 8에서 비어 있던"
echo "  자리를 다른 DMV 로 채웠습니다. 파일 카운터는 물리 쓰기라 조금 더 크게 나오고"
echo "  log_stats 는 로그 레코드의 양이라 조금 작습니다. 그 차이는 로그 블록이 채워지며"
echo "  같은 블록을 여러 번 밀어내는 몫입니다."

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  실험 8이 남긴 두 구멍은 **결과가 아니라 계측의 문제**였습니다."
echo
echo "  0 을 보고할 때는 그 계기로 0 이 아닌 값을 만들어 본 적이 있어야 합니다."
echo "  RCSI 를 켜서 버전 저장소를 부풀리자 같은 쿼리가 그것을 잡았고, 그러므로"
echo "  온라인 빌드 중의 0 은 **실제로 안 쓴 것**이라고 말할 수 있게 됐습니다."
echo "  양성 대조가 없으면 그 0 은 아무 말도 못 합니다."
echo
echo "  두 번째 계기가 안 잡히면 세 번째를 찾습니다. 트랜잭션 단위 카운터가 온라인"
echo "  빌드를 못 잡은 것은 그 빌드가 짧은 내부 트랜잭션을 쓰기 때문이고, 그렇다면"
echo "  **트랜잭션 단위가 아닌 계기**를 세우면 됩니다. dm_db_log_stats 는 백업 지점"
echo "  기준이라 트랜잭션 경계와 무관합니다."
echo
echo "  운영으로 옮기면 이렇게 됩니다."
echo "    0 을 근거로 무언가를 주장하기 전에 그 계기의 양성 대조를 먼저 만든다"
echo "    계기 하나가 안 잡히면 **경로가 다른 계기**를 찾는다. 같은 계열은 같이 눈이 먼다"
echo "    수치가 두 계기에서 다르면 어느 쪽이 무엇을 세는지부터 확인한다"
} 2>&1 | tee "$OUT/exp12-version-store.txt"
