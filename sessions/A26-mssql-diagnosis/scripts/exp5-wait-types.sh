#!/usr/bin/env bash
# 실험 5. 대기 유형마다 가리키는 곳이 다르다.
#
# 못 한 것에 이렇게 적었다.
#   "대기 유형이 하나뿐입니다. 락 대기만 만들었습니다. PAGEIOLATCH, WRITELOG,
#    RESOURCE_SEMAPHORE 처럼 다른 원인을 가리키는 대기는 재현하지 않았습니다."
#
# 실험 1·2는 LCK_M_* 하나로 갔고, 그 뒤 처방(블로킹 사슬 -> 뿌리)도 락 전용이다.
# **대기가 락이 아니면 그 처방이 통째로 안 맞는데** 그 경우를 안 만들었다.
#
# 유형을 넷 만들고 각각 무엇을 가리키는지, 그리고 **같은 처방이 왜 안 통하는지**를 본다.
#   A LCK_M_*            누가 막고 있다        -> 사슬을 따라 뿌리를 찾는다
#   B 버퍼 풀 압박       메모리가 모자라다    -> 막는 세션이 없다. 읽는 양이나 메모리를 본다
#   C WRITELOG           로그를 쓰고 기다린다  -> 커밋 횟수와 로그 디스크를 본다
#   D CXPACKET/CXCONSUMER 병렬 처리 중이다      -> 대기 자체는 문제가 아닐 수 있다
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
BIG=${WT_ROWS:-3000000}
POOL_MB=${POOL_MB:-1024}   # 버퍼 풀 상한. 표보다 작아야 디스크를 오간다

# 설정을 건드리므로 어떻게 끝나든 되돌린다. 처음에 256MB 로 조였다가 컨테이너가
# 죽었고, 그때 설정이 그대로 남아 다시 띄운 뒤에도 256 이었다.
MEM_SAVED=""
restore_mem(){
  [ -n "$MEM_SAVED" ] || return 0
  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W \
    -Q "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
        EXEC sp_configure 'max server memory (MB)', $MEM_SAVED; RECONFIGURE;" >/dev/null 2>&1
}
trap restore_mem EXIT INT TERM

wait_ready || exit 2

# 무시 목록은 lib.sh 한 곳에 둔다. 따로 만들면 빠뜨린다(실험 6에서 그랬다).
IGNORE="$IDLE_WAITS"

snap_waits(){
  QD "SET NOCOUNT ON;
      DROP TABLE IF EXISTS $1;
      SELECT wait_type, wait_time_ms, waiting_tasks_count
        INTO $1
        FROM sys.dm_os_wait_stats
       WHERE wait_type NOT IN ($IGNORE);" >/dev/null
}
top_delta(){ # 차분 상위 n 개를 '유형 시간ms' 로
  QD "SET NOCOUNT ON;
      SELECT TOP ($2) b.wait_type + ' ' + CAST(b.wait_time_ms - ISNULL(a.wait_time_ms, 0) AS varchar(20))
        FROM #w_after b LEFT JOIN #w_before a ON a.wait_type = b.wait_type
       WHERE b.wait_time_ms - ISNULL(a.wait_time_ms, 0) > 0
       ORDER BY b.wait_time_ms - ISNULL(a.wait_time_ms, 0) DESC;" 2>/dev/null | grep -E '^[A-Z_]+ [0-9]+'
}

# 임시 표를 세션 간에 못 쓰므로 실제 표로 둔다.
snap_before(){ snap_waits w_before; }
snap_after(){  snap_waits w_after;  }
delta_top(){ # $1=개수
  QD "SET NOCOUNT ON;
      SELECT TOP ($1) b.wait_type + ' ' + CAST(b.wait_time_ms - ISNULL(a.wait_time_ms, 0) AS varchar(20))
        FROM w_after b LEFT JOIN w_before a ON a.wait_type = b.wait_type
       WHERE b.wait_time_ms - ISNULL(a.wait_time_ms, 0) > 0
       ORDER BY b.wait_time_ms - ISNULL(a.wait_time_ms, 0) DESC;" | grep -E '^[A-Z_]+ [0-9]+'
}

# 큰 표를 하나 만든다. 스캔과 로그 쓰기에 둘 다 쓴다.
QDX "SET NOCOUNT ON;
DROP TABLE IF EXISTS wt_big;
CREATE TABLE wt_big (id INT NOT NULL PRIMARY KEY, pad CHAR(400) NOT NULL, n BIGINT NOT NULL);
WITH n AS (SELECT TOP ($BIG) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
             FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO wt_big (id, pad, n) SELECT i, REPLICATE('x', 400), i FROM n;" || exit 2
GOT=$(num "$(QD "SELECT COUNT(*) FROM wt_big")")
[ "$GOT" = "$BIG" ] || { echo "중단: 적재가 ${GOT}행입니다(기대 $BIG)" >&2; exit 2; }
MB=$(num "$(QD "SET NOCOUNT ON;
  SELECT CAST(SUM(a.total_pages) * 8 / 1024 AS varchar(20))
    FROM sys.partitions p JOIN sys.allocation_units a ON a.container_id = p.partition_id
   WHERE p.object_id = OBJECT_ID('wt_big');")")

{
echo "# 실험 5. 대기 유형마다 가리키는 곳이 다르다"
echo
echo "  실험 1·2는 락 대기 하나로 갔고 그 뒤 처방도 락 전용입니다."
echo "  **대기가 락이 아니면 그 처방이 통째로 안 맞는데** 그 경우를 안 만들었습니다."
echo
echo "  ${BIG}행 ${MB}MB 짜리 표로 유형 넷을 만듭니다."
echo

: > "$OUT/wait-types.csv"
echo "case,top_wait,delta_ms,points_to" >> "$OUT/wait-types.csv"
printf "  %-24s %-30s %-14s %s\n" "만든 상황" "차분 상위 대기" "계열" "무엇을 가리키나"

# 준비 단계를 측정 밖으로 뺀다. DBCC DROPCLEANBUFFERS 자체가 LATCH_EX 를 크게
# 만들어서, 안에 두면 그것이 상위를 차지하고 정작 재려던 대기가 안 보인다.
# 처음에 그렇게 쟀다가 디스크 읽기 조건의 1위가 LATCH_EX 로 나왔다.
run_case(){ # $1=라벨 $2=준비 $3=부하 $4=가리키는 것
  [ -n "$2" ] && eval "$2"
  snap_before
  eval "$3"
  snap_after
  # 1위만 보면 우연히 섞인 것에 속는다. 상위 셋을 함께 적는다.
  local tops; tops=$(delta_top 3)
  local first; first=$(echo "$tops" | head -1)
  local wt=$(echo "$first" | awk '{print $1}')
  local ms=$(echo "$first" | awk '{print $2}')
  # 1위 유형은 회차마다 바뀐다. 버퍼 풀 압박은 SLEEP_BPOOL_STEAL 로도
  # MEMORY_ALLOCATION_EXT 로도 PAGEIOLATCH_SH 로도 나온다. **계열로 판정한다.**
  local fam="기타"
  case "$wt" in
    LCK_*) fam="락" ;;
    PAGEIOLATCH_*|SLEEP_BPOOL_STEAL|MEMORY_ALLOCATION_EXT|RESOURCE_SEMAPHORE*|IO_COMPLETION|ASYNC_IO_COMPLETION) fam="메모리·디스크" ;;
    WRITELOG|LOGBUFFER) fam="로그" ;;
    CX*) fam="병렬" ;;
  esac
  # PREEMPTIVE_OS_* 만 남거나 아무것도 안 늘었으면 그 회차는 신호를 못 만든 것이다.
  # 그것을 그대로 "이 상황의 대기"로 적으면 안 된다.
  case "${wt:-}" in
    ""|PREEMPTIVE_OS_*) fam="**신호 못 만듦**" ;;
  esac
  printf "  %-24s %-30s %-14s %s\n" "$1" "${wt:-없음} ${ms:-}ms" "$fam" "$4"
  echo "$tops" | tail -n +2 | while read -r l; do
    [ -n "$l" ] && printf "  %-24s %s\n" "" "  $(echo "$l" | awk '{print $1" "$2"ms"}')"
  done
  echo "\"$1\",\"${wt:-없음}\",${ms:-0},\"$fam / $4\"" >> "$OUT/wait-types.csv"
}

# A 락 대기. 실험 1과 같은 모양이다.
lock_load(){
  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
    -Q "SET NOCOUNT ON; BEGIN TRAN; UPDATE wt_big SET n = n + 1 WHERE id <= 200000;
        WAITFOR DELAY '00:00:08'; ROLLBACK;" >/dev/null 2>&1 &
  local bg=$!
  sleep 3
  QD "SET NOCOUNT ON; SELECT COUNT(*) FROM wt_big WHERE id <= 100;" >/dev/null
  wait "$bg" 2>/dev/null
}

# B 디스크 읽기 대기.
#
# 버퍼를 비우기만 해서는 PAGEIOLATCH 가 상위로 안 옵니다. 표가 버퍼 풀보다 작으면
# 한 번 읽어 올린 뒤로는 디스크를 안 가고, 읽는 동안 나오는 것은 LATCH_EX 쪽입니다.
# **표가 버퍼 풀보다 커야** 실제로 오갑니다.
#
# 풀을 256MB 까지 조였다가 컨테이너가 죽었습니다. SQL Server 가 그 아래에서는
# 못 버팁니다. 풀은 안전한 값으로 두고 **표를 키우는 쪽**으로 바꿨습니다.
io_prep(){
  MEM_SAVED=$(num "$(Q "SET NOCOUNT ON;
    SELECT CAST(value_in_use AS varchar(20)) FROM sys.configurations
     WHERE name = 'max server memory (MB)';")")
  Q "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
     EXEC sp_configure 'max server memory (MB)', $POOL_MB; RECONFIGURE;" >/dev/null
  Q "CHECKPOINT; DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;" >/dev/null
  sleep 3
  # 줄인 풀을 한 번 채워 둔다. 이래야 다음 훑기가 실제로 밀어내며 읽는다.
  QD "SET NOCOUNT ON; SELECT COUNT(*) FROM wt_big OPTION (MAXDOP 1);" >/dev/null
}
io_load(){
  QD "SET NOCOUNT ON;
      SELECT COUNT(*), SUM(n) FROM wt_big OPTION (MAXDOP 1);
      SELECT COUNT(*), SUM(LEN(pad)) FROM wt_big OPTION (MAXDOP 1);" >/dev/null
}
io_restore(){ restore_mem; MEM_SAVED=""; sleep 2; }

# C 로그 쓰기 대기. 작은 트랜잭션을 많이 커밋한다.
log_load(){
  QD "SET NOCOUNT ON;
      DECLARE @i INT = 0;
      WHILE @i < 12000
      BEGIN
        BEGIN TRAN; UPDATE wt_big SET n = n + 1 WHERE id = @i % 1000 + 1; COMMIT;
        SET @i = @i + 1;
      END" >/dev/null
}

# D 병렬 처리 대기. 큰 정렬을 병렬로 돌린다.
par_prep(){ Q "CHECKPOINT; DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;" >/dev/null; sleep 2; }
par_load(){
  QD "SET NOCOUNT ON;
      SELECT TOP 100 n % 997 AS g, COUNT(*) AS c, SUM(LEN(pad)) AS s
        FROM wt_big GROUP BY n % 997 ORDER BY COUNT(*) DESC
      OPTION (MAXDOP 4, RECOMPILE);" >/dev/null
}

run_case "A 옆에서 20만 행 갱신" "" lock_load "누가 막고 있다"
run_case "B 표가 버퍼 풀보다 큼" io_prep io_load "메모리가 모자라 디스크를 오간다"
io_restore
run_case "C 작은 커밋 12,000회" "" log_load "로그를 쓰고 기다린다"
run_case "D 병렬 정렬" par_prep par_load "병렬 처리 중이다"

QD "DROP TABLE IF EXISTS wt_big; DROP TABLE IF EXISTS w_before; DROP TABLE IF EXISTS w_after;" >/dev/null

echo
echo "## 5-1. 같은 처방이 왜 안 통하는가"
echo
printf "  %-22s %-26s %s\n" "대기가 가리키는 것" "블로킹 사슬을 따라가면" "대신 볼 것"
prow(){ printf "  %-22s %-26s %s\n" "$1" "$2" "$3"; echo "\"$1\",\"$2\",0,\"$3\"" >> "$OUT/wait-types.csv"; }
prow "락" "뿌리 세션이 나온다" "그 세션이 무엇을 하던 중인지"
prow "메모리·디스크" "**막는 세션이 없다**" "읽는 페이지 수. 인덱스와 메모리"
prow "로그 쓰기" "**막는 세션이 없다**" "커밋 횟수. 배치로 묶을 수 있는지"
prow "병렬 처리" "**막는 세션이 없다**" "이 대기는 정상일 수 있다"
echo
echo "  **락이 아닌 셋은 블로킹 사슬을 따라가 봐야 아무도 안 나옵니다.**"
echo "  실험 2의 재귀 쿼리를 돌리면 빈 결과가 나오고, 그것을 \"막는 세션이 없으니"
echo "  DB 문제가 아니다\"로 읽으면 그때부터 헤맵니다."
echo
echo "  넷째가 특히 함정입니다. 병렬 대기는 **일을 나눠 하는 중**이라는 뜻이지"
echo "  문제가 아닐 수 있습니다. 상위에 올랐다고 손대면 멀쩡한 것을 건드립니다."
echo
echo "  B 에서 1위가 PAGEIOLATCH 가 아니라 **SLEEP_BPOOL_STEAL** 로 나왔습니다."
echo "  버퍼 풀이 표보다 작아 페이지를 계속 빼앗기는 상태이고, PAGEIOLATCH_SH 는"
echo "  그 아래에 붙습니다. **더 정확한 진단입니다.** 디스크가 느린 것이 아니라"
echo "  메모리가 모자라 같은 페이지를 반복해 올리고 있다는 뜻이기 때문입니다."
echo "  디스크를 바꿔도 안 낫고 메모리를 늘리거나 읽는 양을 줄여야 합니다."
echo
echo "  이 조건을 만들려고 **버퍼 풀을 ${POOL_MB}MB 로 두고 표를 그보다 크게** 만들었습니다."
echo "  버퍼 풀이 표보다 크면 한 번 읽어 올린 뒤로는 디스크를 안 갑니다."
echo "  조사 쿼리가 실제 운영에서 느린 이유가 이것이고, 랩에서 재려면 같은 비율이"
echo "  필요합니다. 처음에 풀을 256MB 까지 조였다가 컨테이너가 죽었습니다."
echo
echo "  RESOURCE_SEMAPHORE(메모리 부여 대기)는 이 랩에서 못 만들었습니다."
echo "  큰 정렬을 여럿 동시에 돌려야 하는데 이 컨테이너 규모에서는 부여가 다 났습니다."

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  대기 유형은 **어느 처방으로 갈지를 정하는 갈림길**입니다."
echo "  실험 1·2가 만든 순서(대기 -> 사슬 -> 뿌리)는 그 갈림길에서 락 쪽으로 간"
echo "  경우이고, 나머지 셋에서는 사슬을 따라가 봐야 아무도 안 나옵니다."
echo
echo "  그래서 진단 순서의 2단계에 분기를 넣습니다."
echo
echo "    LCK_M_*         블로킹 사슬을 따라 뿌리를 찾는다 (실험 2)"
echo "    PAGEIOLATCH_* / SLEEP_BPOOL_STEAL  많이 읽는 쿼리와 버퍼 풀 여유를 본다 (실험 3)"
echo "    WRITELOG        커밋 횟수를 본다. 한 건씩 커밋하는 루프를 배치로 묶는다"
echo "    CXPACKET 계열   먼저 정상인지 의심한다. 병렬도가 문제면 MAXDOP 을 본다"
echo
echo "  **어느 쪽이든 3단계는 같습니다.** 무엇을 하던 세션인지, 어떤 쿼리인지"
echo "  기록하고 나서 손댑니다. 기록 없이 죽이면 같은 일이 반복됩니다."
} 2>&1 | tee "$OUT/exp5-wait-types.txt"
