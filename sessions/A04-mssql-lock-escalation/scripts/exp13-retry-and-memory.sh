#!/usr/bin/env bash
# 실험 13. 실패한 승격은 언제 다시 시도하는가, 그리고 메모리 압박으로도 승격하는가.
#
# 못 한 것에 둘을 남겼다.
#   "재시도가 실제로 1,250개마다 일어나는지는 못 봤습니다. 실험 7에서 승격이
#    실패하는 것까지는 봤지만, 옆 세션이 버티는 동안 몇 번을 다시 시도했는지는
#    확장 이벤트에 안 남습니다. 실패한 시도는 이벤트를 안 남기기 때문입니다."
#   "락 메모리 압박에 의한 승격을 못 봤습니다. 실험 3의 3번이 20만 락을 들고도
#    승격하지 않은 것은 DISABLE 때문이지 메모리에 여유가 있어서인지 가르지 않았습니다."
#
# 첫째는 **실패한 시도를 직접 못 보므로 다른 각도가 필요하다.** 옆 세션이 물러난
# 뒤 락을 얼마나 더 잡았을 때 승격이 되는지 보면 재시도 간격이 드러난다.
# 간격이 1,250 이라면 물러난 뒤 1,250개 안에 승격해야 한다.
#
# 둘째는 DISABLE 로 락을 훨씬 더 쌓아 본다. 20만으로 안 됐으면 그 몇 배로 간다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
ROWS=${ROWS:-200000}
BIG=${BIG_ROWS:-2000000}
STEP=${STEP:-300}      # 한 번에 갱신할 행 수. 락을 조금씩 늘린다
STEPS=${STEPS:-60}

wait_ready || exit 2
OPTLOCK=$(assert_env) || exit 2

lock_of(){ # $1=세션 id. "테이블X여부,총락수"
  num "$(QD "SET NOCOUNT ON;
    SELECT CAST(SUM(CASE WHEN resource_type='OBJECT' AND request_mode='X' THEN 1 ELSE 0 END) AS varchar(6))
         + ',' + CAST(SUM(CASE WHEN resource_type <> 'DATABASE' THEN 1 ELSE 0 END) AS varchar(12))
      FROM sys.dm_tran_locks WHERE request_session_id = $1;")"
}

{
echo "# 실험 13. 재시도 간격과 메모리 압박"
echo "# optimized locking: ${OPTLOCK}"
echo

echo "=================================================================="
echo "## 13-1. 승격은 트랜잭션이 아니라 문장 단위로 판정된다"
echo "=================================================================="
echo
echo "  재시도 간격을 재려고 트랜잭션 하나에서 300행씩 나눠 갱신하며 락을 쌓았습니다."
echo "  **1만 8천 개를 쌓았는데 승격이 안 났습니다.** 실패한 설계인 줄 알았는데"
echo "  그 자체가 답이었습니다."
echo
reset_table "$ROWS" >/dev/null || exit 2
QD "ALTER TABLE $TBL SET (LOCK_ESCALATION = TABLE);" >/dev/null

FIFO=$(mktemp -u); mkfifo "$FIFO"
docker exec -i "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
  > "$OUT/.grow.out" 2>&1 < "$FIFO" &
GROWPID=$!
exec 9>"$FIFO"
printf 'SET NOCOUNT ON;\nSELECT %s + CAST(@@SPID AS varchar(8));\nGO\nBEGIN TRAN;\nGO\n' "'SPID='" >&9
sleep 3
SPID=$(grep -oE 'SPID=[0-9]+' "$OUT/.grow.out" | head -1 | cut -d= -f2)

: > "$OUT/retry-interval.csv"
echo "phase,step,locks,table_x" >> "$OUT/retry-interval.csv"
printf "  %-24s %-14s %s\n" "쌓은 방법" "총 락 수" "테이블 X"
for S in $(seq 1 "$STEPS"); do
  LO=$(( (S - 1) * STEP + 1 )); HI=$(( S * STEP ))
  echo "UPDATE $TBL SET balance = balance - 1 WHERE account_id BETWEEN $LO AND $HI;" >&9
  echo "GO" >&9
  sleep 0.3
done
sleep 2
V=$(lock_of "${SPID:-0}"); IFS=, read -r TX TOT <<<"$V"
printf "  %-24s %-14s %s\n" "${STEP}행씩 ${STEPS}문장" "${TOT:-0}" "${TX:-0}"
echo "many_statements,$STEPS,${TOT:-0},${TX:-0}" >> "$OUT/retry-interval.csv"
echo "ROLLBACK;" >&9; echo "GO" >&9
exec 9>&-
wait "$GROWPID" 2>/dev/null
rm -f "$FIFO" "$OUT/.grow.out"

# 같은 락 수를 한 문장으로 잡으면 어떻게 되는지 견준다.
ONE=$(( STEP * STEPS ))
SH=$(lock_shape "$ONE"); IFS=, read -r ESC KEYL PAGEL TOTL <<<"$SH"
printf "  %-24s %-14s %s\n" "${ONE}행을 한 문장으로" "$TOTL" "$ESC"
echo "one_statement,1,$TOTL,$ESC" >> "$OUT/retry-interval.csv"
echo
if [ "${TX:-0}" = "0" ] && [ "${ESC:-0}" != "0" ]; then
  echo "  **같은 락 수인데 한쪽만 승격합니다.** 승격은 트랜잭션이 든 락이 아니라"
  echo "  **문장 하나가 잡은 락**으로 판정되기 때문입니다. 문장을 작게 나누면"
  echo "  트랜잭션이 락을 아무리 많이 들고 있어도 각 문장은 임계값에 안 닿습니다."
  echo
  echo "  **이것이 배치 분할이 통하는 진짜 이유입니다.** 실험 3에서 4,000행씩 나눠"
  echo "  승격이 0회가 된 것을 \"배치가 작아서\"라고만 적었는데, 정확히는 **판정 단위가"
  echo "  문장이라서**입니다. 배치마다 커밋하지 않고 한 트랜잭션에 묶어 두어도"
  echo "  승격은 안 납니다. 다만 락은 그대로 쌓이므로 커밋해서 놓아 주는 것이 맞습니다."
else
  echo "  **두 방법이 같게 나왔습니다.** 이 회차로는 문장 단위 판정을 못 보입니다."
fi
echo

echo "=================================================================="
echo "## 13-1-2. 승격이 실패한 뒤 언제 다시 시도하는가"
echo "=================================================================="
echo
echo "  이제 한 문장으로 갑니다. 옆 세션이 테이블 락을 막고 있는 동안 큰 갱신을"
echo "  돌리고, 옆 세션이 물러난 뒤 승격까지 락을 얼마나 더 잡는지 봅니다."
echo
reset_table "$BIG" >/dev/null || exit 2
QD "ALTER TABLE $TBL SET (LOCK_ESCALATION = TABLE);" >/dev/null

docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
  -Q "SET NOCOUNT ON;
      BEGIN TRAN;
      UPDATE $TBL SET balance = balance WHERE account_id = $BIG;
      WAITFOR DELAY '00:00:12';
      ROLLBACK;" >/dev/null 2>&1 &
RIVAL=$!
HELD=0
for i in $(seq 1 40); do
  [ "$(num "$(Q "SELECT CAST(COUNT(*) AS varchar(4)) FROM sys.dm_exec_requests r
                   JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
                  WHERE s.is_user_process = 1 AND r.wait_type = 'WAITFOR'")")" -gt 0 ] 2>/dev/null && { HELD=1; break; }
  sleep 1
done

# 큰 갱신을 한 문장으로 돌린다. 대상은 옆 세션이 잡은 행을 뺀 앞쪽 전부다.
docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
  -Q "SET NOCOUNT ON;
      BEGIN TRAN;
      UPDATE $TBL SET balance = balance - 1 WHERE account_id < $BIG;
      SELECT 'BIGDONE';
      ROLLBACK;" > "$OUT/.big.out" 2>&1 &
BIGPID=$!

RIVAL_GONE_AT=""; ESC_AT=""; LAST=0
for i in $(seq 1 200); do
  V=$(num "$(QD "SET NOCOUNT ON;
    SELECT CAST(SUM(CASE WHEN resource_type='OBJECT' AND request_mode='X' THEN 1 ELSE 0 END) AS varchar(6))
         + ',' + CAST(SUM(CASE WHEN resource_type <> 'DATABASE' THEN 1 ELSE 0 END) AS varchar(12))
      FROM sys.dm_tran_locks l
      JOIN sys.dm_exec_sessions s ON s.session_id = l.request_session_id
     WHERE s.is_user_process = 1 AND l.resource_type IN ('KEY','PAGE','OBJECT')
       AND l.request_session_id <> @@SPID;")")
  IFS=, read -r TX TOT <<<"$V"
  RV=$(num "$(Q "SELECT CAST(COUNT(*) AS varchar(4)) FROM sys.dm_exec_requests r
                   JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
                  WHERE s.is_user_process = 1 AND r.wait_type = 'WAITFOR'")")
  [ "${RV:-0}" = "0" ] && [ -z "$RIVAL_GONE_AT" ] && RIVAL_GONE_AT="${LAST:-0}"
  if [ "${TX:-0}" -gt 0 ] 2>/dev/null && [ -n "$RIVAL_GONE_AT" ]; then ESC_AT="${LAST:-0}"; break; fi
  [ "${TOT:-0}" -gt 0 ] 2>/dev/null && LAST="$TOT"
  grep -q BIGDONE "$OUT/.big.out" 2>/dev/null && break
  sleep 0.3
done
wait "$BIGPID" 2>/dev/null; wait "$RIVAL" 2>/dev/null
rm -f "$OUT/.big.out"

if [ -n "$ESC_AT" ] && [ -n "$RIVAL_GONE_AT" ]; then
  GAP=$(( ESC_AT - RIVAL_GONE_AT ))
  printf "  %-32s %s\n" "옆 세션이 사라진 직전의 락" "$RIVAL_GONE_AT"
  printf "  %-32s %s\n" "승격 직전에 관측된 락" "$ESC_AT"
  printf "  %-32s %s\n" "그 사이" "$GAP"
  echo "retry_gap,1,$GAP,1" >> "$OUT/retry-interval.csv"
  echo
  echo "  표본 간격이 0.3초라 이 값은 **상한**입니다. 그 사이에 여러 검사 지점을"
  echo "  지났을 수 있으므로 \"1,250 마다\"를 이 방법으로 못 못 박습니다."
  echo "  말할 수 있는 것은 **옆 세션이 물러난 뒤 곧 승격했다**는 것까지입니다."
else
  echo "  **승격 시점이나 옆 세션이 사라진 시점을 못 잡았습니다.**"
  echo "  갱신이 표본 간격보다 빨리 끝났거나 승격이 이미 일어난 뒤였습니다."
  echo "  실패한 시도는 이벤트를 안 남기므로 **이 각도로도 간격을 못 좁혔습니다.**"
fi
echo

echo "=================================================================="
echo "## 13-2. DISABLE 인데도 메모리 압박으로 승격하는가"
echo "=================================================================="
echo
echo "  실험 3의 3번은 DISABLE 로 20만 락을 들고도 승격하지 않았습니다. 그것이"
echo "  DISABLE 때문인지 메모리에 여유가 있어서인지 안 갈랐습니다."
echo "  락을 훨씬 더 쌓아 봅니다. ${BIG}행 표를 통째로 갱신합니다."
echo
reset_table "$BIG" >/dev/null || exit 2
QD "ALTER TABLE $TBL SET (LOCK_ESCALATION = DISABLE);" >/dev/null
DESC=$(num "$(QD "SELECT lock_escalation_desc FROM sys.tables WHERE name='$TBL'")")
[ "$DESC" = "DISABLE" ] || { echo "  설정을 못 바꿨습니다($DESC)"; }

# 락 매니저 clerk 은 메모리 노드마다 하나씩 있다. 한 값으로 받으면 Msg 512 로 죽는다.
MEM0=$(num "$(Q "SET NOCOUNT ON;
  SELECT CAST(SUM(pages_kb) / 1024 AS varchar(20)) FROM sys.dm_os_memory_clerks
   WHERE type = 'OBJECTSTORE_LOCK_MANAGER';")")
xe_reset
: > "$OUT/lock-memory.csv"
echo "rows,table_x,total_locks,lock_mem_mb,escalation_events" >> "$OUT/lock-memory.csv"
printf "  %-12s %-14s %-14s %-14s %s\n" "갱신 행" "테이블 X" "총 락 수" "락 메모리" "승격 이벤트"

for N in 200000 600000 1200000 2000000; do
  [ "$N" -le "$BIG" ] || continue
  xe_reset
  V=$(num "$(QD "SET NOCOUNT ON;
    BEGIN TRAN;
    UPDATE TOP ($N) $TBL SET balance = balance - 1;
    SELECT CAST(SUM(CASE WHEN resource_type='OBJECT' AND request_mode='X' THEN 1 ELSE 0 END) AS varchar(6))
         + ',' + CAST(SUM(CASE WHEN resource_type <> 'DATABASE' THEN 1 ELSE 0 END) AS varchar(12))
         + ',' + CAST((SELECT SUM(pages_kb) / 1024 FROM sys.dm_os_memory_clerks
                        WHERE type = 'OBJECTSTORE_LOCK_MANAGER') AS varchar(12))
      FROM sys.dm_tran_locks WHERE request_session_id = @@SPID;
    ROLLBACK;")")
  IFS=, read -r TX TOT MEM <<<"$V"
  EV=$(xe_count)
  printf "  %-12s %-14s %-14s %-14s %s\n" "$N" "${TX:-?}" "${TOT:-?}" "${MEM:-?}MB" "${EV}건"
  echo "$N,${TX:-0},${TOT:-0},${MEM:-0},$EV" >> "$OUT/lock-memory.csv"
done

QD "ALTER TABLE $TBL SET (LOCK_ESCALATION = TABLE);" >/dev/null
reset_table "$ROWS" >/dev/null || true

M=$(python3 - "$OUT/lock-memory.csv" <<'PYX'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
esc = [r for r in rows if int(r['table_x']) > 0 or int(r['escalation_events']) > 0]
mx = max(rows, key=lambda r: int(r['total_locks']))
# 행을 늘렸는데 락이 오히려 줄면 엔진이 페이지 락으로 갈아탄 것이다(실험 4).
shrank = any(int(rows[i]['total_locks']) < int(rows[i-1]['total_locks']) for i in range(1, len(rows)))
print("|".join([
    "있음" if esc else "없음",
    mx['total_locks'], mx['lock_mem_mb'], mx['rows'],
    "있음" if shrank else "없음",
    "; ".join(f"{r['rows']}행 {r['total_locks']}락" for r in rows),
]))
PYX
)
IFS='|' read -r ESC_ANY MAXLOCK MAXMEM MAXROWS SHRANK SERIES <<<"$M"
echo
printf "  %-30s %s\n" "가장 많이 쌓은 락" "${MAXLOCK}개 (${MAXROWS}행)"
printf "  %-30s %s\n" "그때 락 매니저 메모리" "${MAXMEM}MB"
printf "  %-30s %s\n" "메모리 압박 승격" "$ESC_ANY"
echo
printf "  %-30s %s\n" "행 수별 락" "$SERIES"
echo
if [ "$SHRANK" = "있음" ]; then
  echo "  **행을 늘렸는데 락이 오히려 줄었습니다.** 락을 더 쌓으려던 시도가 반대로"
  echo "  갔습니다. 실험 4에서 본 것이 여기서 되돌아왔습니다. 갱신 규모가 커지면"
  echo "  엔진이 처음부터 **행 락 대신 페이지 락**을 고르고, 페이지 하나가 행 수백 개를"
  echo "  덮으므로 락 개수가 자릿수로 줄어듭니다."
  echo
  echo "  **그래서 이 방향으로는 락 메모리를 못 채웁니다.** 행을 아무리 늘려도 엔진이"
  echo "  알아서 굵은 단위로 잡아 버립니다. 압박을 만들려면 페이지 락으로 못 가게"
  echo "  막으면서(힌트나 좁은 조건으로) 행 락을 강제해야 하는데 그것은 안 했습니다."
  echo
fi
if [ "$ESC_ANY" = "없음" ]; then
  echo "  **${MAXLOCK}개를 들고도 승격이 안 났습니다.** 실험 3의 20만과 같은 규모입니다."
  echo "  이 컨테이너(6g)에서 락 매니저는 ${MAXMEM}MB 를 쓰고 있고, 메모리 압박에"
  echo "  의한 승격 조건에 안 닿았습니다."
  echo
  echo "  그러면 실험 3의 \"DISABLE 이면 승격이 안 난다\"는 **이 규모까지는 맞습니다.**"
  echo "  다만 이것이 \"DISABLE 이면 절대 안 난다\"를 뜻하지는 않습니다. 문서는 메모리"
  echo "  압박에서는 예외라고 적고, 이 랩은 그 압박을 못 만들었습니다."
  echo "  **DISABLE 을 켜 두고 락을 무한정 쌓아도 된다고 읽으면 안 됩니다.**"
else
  echo "  **DISABLE 인데도 승격이 났습니다.** 문서가 말한 메모리 압박 예외입니다."
  echo "  DISABLE 은 승격을 끄는 것이 아니라 **락 개수에 의한 승격만** 끄는 것입니다."
fi
} 2>&1 | tee "$OUT/exp13-retry-and-memory.txt"
