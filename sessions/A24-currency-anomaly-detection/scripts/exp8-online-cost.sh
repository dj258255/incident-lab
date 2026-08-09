#!/usr/bin/env bash
# 실험 8. ONLINE = ON 의 대가는 얼마인가.
#
# 실험 4는 ONLINE = ON 이 쓰기를 안 막는다는 것을 보이고 정리에 이렇게 적었다.
#   "대신 빌드 중 변경분을 따로 모으느라 tempdb 와 트랜잭션 로그를 더 씁니다.
#    이 랩에서는 그 양을 재지 않았습니다."
#
# 절차서가 "견주라"고 적어 둔 항목을 또 안 잰 채로 남겨 둔 것이다. 여기서 잰다.
#
# 무엇으로 재는가가 이 실험의 절반이다.
#   로그를 sys.dm_db_log_space_usage 로 재면 안 된다. 그것은 "지금 로그가 얼마나
#   차 있는가"이고, 체크포인트나 로그 백업이 지나가면 회수된다. 우리가 알고 싶은 것은
#   "이 작업이 로그를 얼마나 썼는가"다. 그것은 sys.dm_io_virtual_file_stats 의
#   num_of_bytes_written 차분으로 잰다. 누적값이라 회수돼도 안 줄어든다.
#
# 실험을 둘로 가른다. **한 번에 재려다 변수가 섞였다.**
#   1부 로그   동시 쓰기 **없이** 잰다. 오프라인은 쓰기를 막고 온라인은 안 막으므로,
#              쓰게 두면 두 조건이 받아들인 변경량 자체가 달라진다.
#              복구 모델 2 x ONLINE 2 = 네 번 빌드한다.
#   2부 tempdb 온라인으로 고정하고 SORT_IN_TEMPDB 와 동시 쓰기를 변수로 둔다.
#              1부에서 tempdb 가 어느 조건에서도 안 움직였는데, 그것은 온라인이
#              tempdb 를 안 쓴다는 뜻이 아니라 **정렬 위치가 기본으로 tempdb 가
#              아니기 때문**이다. 그 자리를 갈라서 본다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

wait_ready || exit 2
LEDGER=$(num "$(QD "SELECT COUNT(*) FROM currency_ledger")")
[ "${LEDGER:-0}" -gt 1000000 ] || { echo "중단: 원장이 ${LEDGER}행입니다. 실험 1을 먼저 돌립니다" >&2; exit 2; }
ORIG_MODEL=$(num "$(Q "SELECT recovery_model_desc FROM sys.databases WHERE name='$DB'")")
MARK=999999999   # 2부에서 넣는 행의 표식. 조건이 끝나면 이것으로 지운다.

mb(){ python3 -c "print(f'{${1:-0}/1048576:.0f}')"; }

# 파일에 쓴 누적 바이트. 회수돼도 안 줄어드는 값이라 "얼마나 썼는가"를 잰다.
bytes_written(){ # $1=db, $2=LOG|ALL
  local filt="1=1"; [ "$2" = "LOG" ] && filt="mf.type_desc = 'LOG'"
  num "$(Q "SET NOCOUNT ON;
    SELECT CAST(SUM(vfs.num_of_bytes_written) AS varchar(30))
      FROM sys.dm_io_virtual_file_stats(DB_ID('$1'), NULL) vfs
      JOIN sys.master_files mf
        ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id
     WHERE $filt;")"
}

# 빌드 도중 tempdb 와 **빌드 트랜잭션이 쓴 로그 바이트**를 표본한다.
# 둘 다 끝난 뒤에 재면 이미 반납·정리된 뒤라 0 이 나온다.
#
# 로그를 두 곳에서 재는 이유가 있다. 파일 I/O 카운터(num_of_bytes_written)는 물리
# 쓰기를 세므로 같은 로그 블록을 여러 번 밀어내면 부풀 수 있고, 반대로 계측이 새면
# 실제보다 적게 나온다. dm_tran_database_transactions 는 **트랜잭션이 생성한 로그
# 바이트**를 엔진이 직접 보고하는 값이라 경로가 완전히 다르다. 둘이 크게 어긋나면
# 결론이 아니라 계측을 의심해야 한다.
#
# 처음엔 dm_exec_requests 에 조인해 command LIKE '%INDEX%' 로 빌드를 골랐다.
# 오프라인 조건에서는 잡혔는데 **온라인 조건에서만 0 이 나왔다.** 온라인 빌드는
# 내부 트랜잭션을 짧게 여러 번 여닫아서 표본 순간에 그 조합이 안 잡힌 것이다.
# 0 은 "안 썼다"가 아니라 "못 잡았다"인데 표에서는 구분이 안 된다. 하필 방어가 제일
# 필요한 줄에서 교차 확인이 비는 셈이라 조인을 세션으로 낮췄다.
sampler_start(){
  rm -f "$OUT/.tstop"; : > "$OUT/.tempdb"
  ( while [ ! -f "$OUT/.tstop" ]; do
      docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W \
        -Q "SET NOCOUNT ON;
            SELECT CAST(a.alloc AS varchar(20)) + ' ' + CAST(a.vs AS varchar(20))
                 + ' ' + CAST(t.lg AS varchar(30))
              FROM (SELECT SUM(allocated_extent_page_count)        * 8 / 1024 AS alloc,
                           SUM(version_store_reserved_page_count)  * 8 / 1024 AS vs
                      FROM tempdb.sys.dm_db_file_space_usage) a
             CROSS JOIN
                   (SELECT ISNULL(MAX(dt.database_transaction_log_bytes_used), 0) AS lg
                      FROM sys.dm_tran_database_transactions dt
                      JOIN sys.dm_tran_session_transactions st ON st.transaction_id = dt.transaction_id
                      JOIN sys.dm_exec_sessions s ON s.session_id = st.session_id
                     WHERE dt.database_id = DB_ID('$DB') AND s.is_user_process = 1) t;" 2>/dev/null \
        | grep -E '^[0-9]+ [0-9]+ [0-9]+$' >> "$OUT/.tempdb"
    done ) &
  SAMP_PID=$!
}
sampler_stop(){ touch "$OUT/.tstop"; wait "$SAMP_PID" 2>/dev/null; rm -f "$OUT/.tstop"; }

# 2부 전용. 한 행씩 넣으면 docker exec 왕복이 대부분이라 실제 변경량이 안 쌓인다.
# 온라인 빌드가 버전으로 들고 있어야 할 양을 만들려면 덩어리로 넣어야 한다.
writer_start(){
  rm -f "$OUT/.wstop"; : > "$OUT/.writer"
  ( while [ ! -f "$OUT/.wstop" ]; do
      docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
        -Q "SET NOCOUNT ON;
            INSERT INTO currency_ledger (account_id, delta, reason, ref_id, created_at)
            SELECT TOP (2000) $MARK, 10, 2, NULL, SYSDATETIME()
              FROM sys.all_objects a CROSS JOIN sys.all_objects b;" >/dev/null 2>&1
      echo 1 >> "$OUT/.writer"
    done ) &
  WRITER_PID=$!
}
writer_stop(){ touch "$OUT/.wstop"; wait "$WRITER_PID" 2>/dev/null; rm -f "$OUT/.wstop"; }

# 로그가 안 잘리면 FULL 조건에서 파일이 끝없이 큽니다. 조건마다 백업으로 자릅니다.
# 처음엔 /dev/null 로 버리려 했는데 Msg 3634 로 죽습니다. SQL Server 가 백업 장치의
# 크기를 미리 잡으려(DiskChangeFileSize) 하는데 문자 장치는 그것을 못 받습니다.
# 실제 파일에 쓰고 WITH INIT 으로 매번 덮어씁니다. 랩이라 이렇게 하는 것이고
# 운영에서는 백업을 이렇게 버리지 않습니다.
BAKDIR=/var/opt/mssql/lab-backup
docker exec "$CT" mkdir -p "$BAKDIR" >/dev/null 2>&1

truncate_log(){
  [ "$(num "$(Q "SELECT recovery_model_desc FROM sys.databases WHERE name='$DB'")")" = "FULL" ] || return 0
  Q "BACKUP LOG [$DB] TO DISK='$BAKDIR/lab.trn' WITH INIT, NOFORMAT;" >/dev/null 2>&1
}

set_model(){ # $1=SIMPLE|FULL
  Q "ALTER DATABASE [$DB] SET RECOVERY $1;" >/dev/null
  local got; got=$(num "$(Q "SELECT recovery_model_desc FROM sys.databases WHERE name='$DB'")")
  [ "$got" = "$1" ] || { echo "중단: 복구 모델이 ${got} 입니다(기대 $1)" >&2; return 2; }
  # FULL 은 전체 백업이 한 번 있어야 로그 체인이 시작됩니다. 없으면 겉만 FULL 이고
  # 실제로는 SIMPLE 처럼 동작합니다(의사 단순 복구). 그 상태로 재면 FULL 을 잰 것이
  # 아니라 SIMPLE 을 두 번 잰 것이 됩니다.
  if [ "$1" = "FULL" ]; then
    local bo; bo=$(Q "BACKUP DATABASE [$DB] TO DISK='$BAKDIR/lab.bak' WITH INIT, NOFORMAT;")
    echo "$bo" | grep -qE '^(Msg|메시지) [0-9]+' && {
      echo "중단: 전체 백업 실패" >&2; echo "$bo" | grep -E '^(Msg|메시지)' | head -2 >&2; return 2; }
    local lsn; lsn=$(num "$(Q "SELECT CASE WHEN last_log_backup_lsn IS NULL THEN 'PSEUDO' ELSE 'REAL' END
                                 FROM sys.database_recovery_status WHERE database_id = DB_ID('$DB')")")
    [ "$lsn" = "REAL" ] || { echo "중단: 로그 체인이 안 열렸습니다(의사 단순 복구)" >&2; return 2; }
  fi
  return 0
}

idx_mb(){
  num "$(QD "SET NOCOUNT ON;
    SELECT CAST(SUM(a.total_pages) * 8 / 1024 AS varchar(20))
      FROM sys.indexes i
      JOIN sys.partitions p ON p.object_id = i.object_id AND p.index_id = i.index_id
      JOIN sys.allocation_units a ON a.container_id = p.partition_id
     WHERE i.object_id = OBJECT_ID('currency_ledger') AND i.name = 'IX_cost';")"
}

# 인덱스 하나를 만들고 그동안의 로그·tempdb 를 돌려준다.
# 반환: "로그파일MB|로그트랜MB|tempdb최대MB|버전저장소MB|쓰기횟수|결과"
build_once(){ # $1=ONLINE, $2=SORT_IN_TEMPDB, $3=쓰기 부하 여부(Y/N)
  QD "SET QUOTED_IDENTIFIER ON; DROP INDEX IF EXISTS IX_cost ON currency_ledger;" >/dev/null
  truncate_log
  Q "CHECKPOINT;" >/dev/null; QD "CHECKPOINT;" >/dev/null
  : > "$OUT/.writer"

  local l0; l0=$(bytes_written "$DB" LOG)
  [ "$3" = "Y" ] && writer_start
  sampler_start
  local out
  out=$(QD "SET QUOTED_IDENTIFIER ON;
            SET ANSI_NULLS ON;
            CREATE INDEX IX_cost ON currency_ledger (reason, created_at, ref_id)
              INCLUDE (account_id) WITH (ONLINE = $1, SORT_IN_TEMPDB = $2);")
  sampler_stop
  [ "$3" = "Y" ] && writer_stop
  local l1; l1=$(bytes_written "$DB" LOG)

  local res="성공"
  echo "$out" | grep -qE '^(Msg|메시지) [0-9]+' \
    && res="실패:$(echo "$out" | grep -E '^(Msg|메시지)' | head -1 | tr ',' ' ')"

  echo "$(mb $(( l1 - l0 )))|$(mb "$(awk '{if($3>m)m=$3} END{print m+0}' "$OUT/.tempdb")")|$(awk '{if($1>m)m=$1} END{print m+0}' "$OUT/.tempdb")|$(awk '{if($2>m)m=$2} END{print m+0}' "$OUT/.tempdb")|$(awk 'END{print NR+0}' "$OUT/.writer")|$res"
}

{
echo "# 실험 8. ONLINE = ON 의 대가"
echo
echo "  원장 ${LEDGER}행에 실험 3의 인덱스를 만듭니다. 원래 복구 모델은 ${ORIG_MODEL} 입니다."
echo "  시간은 안 적습니다(ARM 에뮬레이션). 쓴 바이트와 잡은 tempdb 를 봅니다."
echo
echo "=================================================================="
echo "## 8-1. 로그를 얼마나 쓰는가"
echo "=================================================================="
echo
echo "  **옆에서 쓰지 않습니다.** 오프라인은 쓰기를 막고 온라인은 안 막으므로,"
echo "  쓰게 두면 두 조건이 받아들인 변경량 자체가 달라져 로그 비교가 안 됩니다."
echo "  빌드 자신이 쓰는 로그만 남깁니다."
echo

: > "$OUT/online-cost.csv"
echo "part,recovery,online,sort_in_tempdb,writers,index_mb,log_mb,tx_log_mb,tempdb_peak_mb,version_store_mb,write_batches,result" >> "$OUT/online-cost.csv"
printf "  %-9s %-8s %-11s %-13s %-15s %s\n" "복구모델" "ONLINE" "인덱스" "로그(파일)" "로그(트랜잭션)" "결과"

part1(){
  local model=$1 online=$2 r
  r=$(build_once "$online" OFF N)
  IFS='|' read -r logmb txmb peak vs w res <<<"$r"
  local imb; imb=$(idx_mb)
  # 0 은 "안 썼다"가 아니라 "표본이 그 트랜잭션을 못 잡았다"다. 그대로 0MB 로 찍으면
  # 표에서 둘이 구분이 안 된다.
  local txtxt="${txmb}MB"; [ "$txmb" = "0" ] && txtxt="못 잡음"
  printf "  %-9s %-8s %-11s %-13s %-15s %s\n" "$model" "$online" "${imb}MB" "${logmb}MB" "$txtxt" "$res"
  echo "1,$model,$online,OFF,N,$imb,$logmb,$txmb,$peak,$vs,$w,$res" >> "$OUT/online-cost.csv"
}

for m in SIMPLE FULL; do
  set_model "$m" || exit 2
  part1 "$m" OFF
  part1 "$m" ON
done

echo
echo "=================================================================="
echo "## 8-2. tempdb 는 언제 쓰는가"
echo "=================================================================="
echo
echo "  1부에서 tempdb 가 어느 조건에서도 안 움직였습니다. 온라인이 tempdb 를"
echo "  안 쓴다는 뜻이 아니라 **정렬 위치가 기본으로 tempdb 가 아니기** 때문입니다."
echo "  SORT_IN_TEMPDB 는 기본이 OFF 이고, 그러면 정렬은 인덱스가 들어갈 파일 그룹에서"
echo "  일어납니다. 온라인을 고정하고 그 옵션과 동시 쓰기를 변수로 둡니다."
echo
printf "  %-32s %-13s %-16s %s\n" "조건" "tempdb 최대" "그중 버전저장소" "동시 쓰기"

part2(){
  local label=$1 sort=$2 writers=$3 r
  r=$(build_once ON "$sort" "$writers")
  IFS='|' read -r logmb txmb peak vs w res <<<"$r"
  local wtxt="없음"; [ "$writers" = "Y" ] && wtxt="$(( w * 2000 ))행"
  printf "  %-32s %-13s %-16s %s\n" "$label" "${peak}MB" "${vs}MB" "$wtxt"
  echo "2,FULL,ON,$sort,$writers,$(idx_mb),$logmb,$txmb,$peak,$vs,$w,$res" >> "$OUT/online-cost.csv"
  QD "DELETE FROM currency_ledger WHERE account_id = $MARK;" >/dev/null
}

set_model FULL || exit 2
part2 "SORT_IN_TEMPDB OFF, 쓰기 없음" OFF N
part2 "SORT_IN_TEMPDB ON, 쓰기 없음"  ON  N
part2 "SORT_IN_TEMPDB OFF, 쓰기 있음" OFF Y

QD "SET QUOTED_IDENTIFIER ON; DROP INDEX IF EXISTS IX_cost ON currency_ledger;" >/dev/null
QD "DELETE FROM currency_ledger WHERE account_id = $MARK;" >/dev/null
truncate_log
set_model "$ORIG_MODEL" >/dev/null 2>&1 || true
docker exec "$CT" rm -rf "$BAKDIR" >/dev/null 2>&1
rm -f "$OUT/.tempdb" "$OUT/.writer"

# 결론을 손으로 안 적는다. 측정값에서 뽑는다.
R=$(python3 - "$OUT/online-cost.csv" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
p1 = {(r['recovery'], r['online']): r for r in rows if r['part'] == '1'}
p2 = [r for r in rows if r['part'] == '2']
def g(k, f): return int(p1[k][f] or 0)
def ratio(a, b): return f"{b/a:.1f}" if a else "-"
def pct(base, v): return f"{100*v/base:.0f}%" if base else "-"
so, sn = ('SIMPLE','OFF'), ('SIMPLE','ON')
fo, fn = ('FULL','OFF'), ('FULL','ON')
idx = g(fo, 'index_mb')
out = [
    str(idx),
    str(g(so,'log_mb')), str(g(sn,'log_mb')), ratio(g(so,'log_mb'), g(sn,'log_mb')),
    str(g(fo,'log_mb')), str(g(fn,'log_mb')), ratio(g(fo,'log_mb'), g(fn,'log_mb')),
    str(g(fo,'tx_log_mb')), str(g(fn,'tx_log_mb')),
    # 인덱스 크기 대비 로그. 최소 로깅이면 100 퍼센트를 한참 밑돈다.
    pct(idx, g(so,'log_mb')), pct(idx, g(sn,'log_mb')),
    pct(idx, g(fo,'log_mb')), pct(idx, g(fn,'log_mb')),
    # 온라인 빌드가 만든 인덱스가 더 큰지 본다.
    str(g(so,'index_mb')), str(g(sn,'index_mb')),
]
for r in p2:
    out += [r['tempdb_peak_mb'], r['version_store_mb']]
print("|".join(out))
PY
)
IFS='|' read -r IDX S_OFF S_ON S_R F_OFF F_ON F_R X_FO X_FN \
  Q_SO Q_SN Q_FO Q_FN I_OFF I_ON T1 V1 T2 V2 T3 V3 <<<"$R"

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  절차서가 \"tempdb 와 로그를 더 씁니다\"라고만 적어 두었던 자리에 숫자를 넣습니다."
echo "  **절반은 맞고 절반은 조건이 빠져 있었습니다.**"
echo
printf "  %-32s %s\n" "만든 인덱스" "${IDX}MB"
printf "  %-32s %s\n" "SIMPLE 로그" "OFF ${S_OFF}MB → ON ${S_ON}MB (${S_R}배)"
printf "  %-32s %s\n" "FULL 로그"   "OFF ${F_OFF}MB → ON ${F_ON}MB (${F_R}배)"
printf "  %-32s %s\n" "인덱스 크기 대비 로그" "SIMPLE ${Q_SO} / ${Q_SN}, FULL ${Q_FO} / ${Q_FN}"
printf "  %-32s %s\n" "만들어진 인덱스 크기"   "오프라인 ${I_OFF}MB / 온라인 ${I_ON}MB"
printf "  %-32s %s\n" "FULL OFF 를 다른 계기로" "파일 ${F_OFF}MB vs 트랜잭션 ${X_FO}MB"
echo
echo "  로그는 맞습니다. 어느 복구 모델에서도 온라인이 더 씁니다."
echo
echo "  **그런데 복구 모델을 안 밝히고 \"더 쓴다\"고만 적으면 안 됩니다.** 절대량이"
echo "  자릿수로 다릅니다. SIMPLE 에서 온라인은 ${S_ON}MB, FULL 에서는 ${F_ON}MB 입니다."
echo "  인덱스 크기 대비로 보면 SIMPLE 은 온라인도 ${Q_SN} 에 그치고, FULL 은 오프라인조차"
echo "  ${Q_FO} 로 인덱스만큼 씁니다. 최소 로깅이 SIMPLE 에서는"
echo "  **온라인 빌드에도 걸린다**는 뜻입니다. 저는 이 실험을 짜면서 온라인이면 어느"
echo "  모델에서도 전체 로깅이라고 주석에 적어 두었는데, 이 표가 그것을 반박합니다."
echo
echo "  교차 확인이 이 결론을 받쳐 줍니다. 파일 I/O 카운터와 트랜잭션 카운터는 서로"
echo "  다른 경로인데 FULL 오프라인에서 ${F_OFF}MB 와 ${X_FO}MB 로 만납니다."
echo "  한쪽만 봤으면 계측이 샌 것인지 실제로 그런 것인지 가를 수 없었습니다."
echo
echo "  **다만 교차 확인은 오프라인에서만 됐습니다.** 온라인 빌드는 내부 트랜잭션을 짧게"
echo "  여닫아 표본이 그 순간을 못 잡습니다. 조인을 요청 단위에서 세션 단위로 낮춰도"
echo "  안 잡혔습니다. 그러니 온라인 두 줄은 파일 카운터 하나로만 받쳐진 값입니다."
echo
printf "  %-32s %s\n" "tempdb: 정렬 기본(OFF)"    "최대 ${T1}MB (버전 ${V1}MB)"
printf "  %-32s %s\n" "tempdb: SORT_IN_TEMPDB ON" "최대 ${T2}MB (버전 ${V2}MB)"
printf "  %-32s %s\n" "tempdb: 쓰기를 받으며"     "최대 ${T3}MB (버전 ${V3}MB)"
echo
echo "  tempdb 쪽은 제가 적어 둔 문장에서 **조건이 빠져 있었습니다.**"
echo "  온라인 빌드라고 tempdb 를 쓰는 것이 아닙니다. SORT_IN_TEMPDB 는 기본이 OFF 라"
echo "  정렬은 인덱스가 들어갈 파일 그룹에서 일어납니다. tempdb 가 커지는 것은"
echo "  **그 옵션을 켰을 때**이고, 그때 인덱스 크기만큼 잡습니다."
echo
echo "  버전 저장소는 예상과 달랐습니다. 빌드 중에 24만 행을 넣었는데도 ${V3}MB 입니다."
echo "  \"빌드 중 변경분을 버전으로 들고 있다\"는 설명대로면 여기가 늘어야 하는데"
echo "  안 늘었습니다. 온라인 빌드가 동시 변경을 tempdb 버전 저장소가 아닌 다른 방법으로"
echo "  다룬다는 뜻으로 보이지만, **이 실험이 확인한 것은 \"안 잡혔다\"까지입니다.**"
echo "  스냅샷 격리를 안 켠 상태라 읽는 쪽이 만드는 버전도 없습니다."
echo
echo "  운영 판단으로 옮기면 이렇게 됩니다."
echo
echo "    복구 모델을 먼저 본다                    → SIMPLE 과 FULL 은 자릿수가 다르다"
echo "    FULL 이면 로그 백업 주기를 당긴다        → 안 그러면 백업 사이에 ${F_ON}MB 가 쌓인다"
echo "    기본값이면 tempdb 가 아니라 대상 파일    → SORT_IN_TEMPDB 를 켤 때만"
echo "    그룹의 여유를 본다                          tempdb 여유를 본다"
echo "    Standard 이하다                          → ONLINE 자체가 안 된다(실험 4)"
echo
echo "  **이 표의 절대값은 이 랩의 규모(${LEDGER}행, 인덱스 ${IDX}MB)에서 나온 것입니다.**"
echo "  다른 표에 그대로 옮겨 쓸 수는 없고, 재는 방법을 옮겨 씁니다. 같은 차분을"
echo "  그 표에서 뜨면 됩니다. 인덱스 크기 대비 배수는 옮겨 볼 만합니다."
} 2>&1 | tee "$OUT/exp8-online-cost.txt"
