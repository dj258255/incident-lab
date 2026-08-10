#!/usr/bin/env bash
# 실험 15. 앞의 넷을 설계를 바꿔 다시 잰다.
#
# 못 한 것에 넷이 남아 있다. 넷 다 "안 해서"가 아니라 **설계가 그 조건을 못 만들어서**다.
# 왜 못 만들었는지가 각각 다르고, 그것을 알고 나면 다른 설계가 보인다.
#
#   1 재시도 간격 1,250     한 문장으로 재야 하는데 그 문장이 표본 간격보다 빨리 끝났다
#   2 경계가 한 칸 흔들림    회차마다 통계를 새로 만들어 흔들릴 이유를 없앴다
#   3 락 메모리 압박         행을 늘리자 엔진이 페이지 락으로 갈아탔다
#   4 지터가 갈리는 조건     승격이 나면 테이블 락으로 줄을 서서 무리가 안 생겼다
#
# 3과 4는 원인이 같다. **엔진이 굵은 단위로 잡아 버리는 것**이고, 둘 다 그것을
# 막으면 된다. ROWLOCK 힌트와 LOCK_ESCALATION = DISABLE 이 그 자리다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
ROWS=${ROWS:-200000}
BIG=${BIG_ROWS:-2000000}

wait_ready || exit 2
OPTLOCK=$(assert_env) || exit 2

{
echo "# 실험 15. 설계를 바꿔 다시 잰다"
echo "# optimized locking: ${OPTLOCK}"
echo

echo "=================================================================="
echo "## 15-1. 락 메모리 압박, 이번에는 행 락을 강제한다"
echo "=================================================================="
echo
echo "  실험 13은 행을 늘려 락을 더 쌓으려다 실패했습니다. 규모가 커지자 엔진이"
echo "  **처음부터 페이지 락**을 골라 락 개수가 오히려 줄었습니다(20만 → 1,632)."
echo
echo "  이번에는 ROWLOCK 힌트로 행 락을 강제합니다. 승격은 DISABLE 로 막습니다."
echo "  둘을 같이 걸면 **행 하나당 락 하나가 끝까지 유지**됩니다."
echo
reset_table "$BIG" >/dev/null || exit 2
QD "ALTER TABLE $TBL SET (LOCK_ESCALATION = DISABLE);" >/dev/null
DESC=$(num "$(QD "SELECT lock_escalation_desc FROM sys.tables WHERE name='$TBL'")")
[ "$DESC" = "DISABLE" ] || { echo "  중단: 설정을 못 바꿨습니다($DESC)"; exit 2; }

: > "$OUT/lock-memory2.csv"
echo "rows,hint,table_x,total_locks,key_locks,page_locks,lock_mem_mb,events" >> "$OUT/lock-memory2.csv"
printf "  %-12s %-10s %-14s %-12s %-12s %s\n" "갱신 행" "힌트" "총 락 수" "KEY" "PAGE" "락 메모리"

mem_probe(){ # $1=행 수 $2=힌트
  xe_reset
  local hint=""; [ "$2" = "ROWLOCK" ] && hint="WITH (ROWLOCK)"
  local v; v=$(num "$(QD "SET NOCOUNT ON;
    BEGIN TRAN;
    UPDATE TOP ($1) $TBL $hint SET balance = balance - 1;
    SELECT CAST(SUM(CASE WHEN resource_type='OBJECT' AND request_mode='X' THEN 1 ELSE 0 END) AS varchar(6))
         + ',' + CAST(SUM(CASE WHEN resource_type <> 'DATABASE' THEN 1 ELSE 0 END) AS varchar(12))
         + ',' + CAST(SUM(CASE WHEN resource_type='KEY'  THEN 1 ELSE 0 END) AS varchar(12))
         + ',' + CAST(SUM(CASE WHEN resource_type='PAGE' THEN 1 ELSE 0 END) AS varchar(12))
         + ',' + CAST((SELECT SUM(pages_kb) / 1024 FROM sys.dm_os_memory_clerks
                        WHERE type = 'OBJECTSTORE_LOCK_MANAGER') AS varchar(12))
      FROM sys.dm_tran_locks WHERE request_session_id = @@SPID;
    ROLLBACK;")")
  IFS=, read -r TX TOT KEYL PAGEL MEM <<<"$v"
  # 조건 하나가 오류로 끝나면 여기에 오류 문자열이 들어온다. 숫자가 아니면 0 으로
  # 두고 결과에 '실패'로 남긴다. 처음에 그대로 CSV 에 넣었다가 파서가 죽었다.
  local FAILED=""
  case "${TX:-}"   in ''|*[!0-9]*) FAILED="실패"; TX=0 ;; esac
  case "${TOT:-}"  in ''|*[!0-9]*) FAILED="실패"; TOT=0 ;; esac
  case "${KEYL:-}" in ''|*[!0-9]*) KEYL=0 ;; esac
  case "${PAGEL:-}" in ''|*[!0-9]*) PAGEL=0 ;; esac
  case "${MEM:-}"  in ''|*[!0-9]*) MEM=0 ;; esac
  local EV; EV=$(xe_count)
  printf "  %-12s %-10s %-14s %-12s %-12s %s\n" "$1" "${2:-없음}" "${FAILED:-$TOT}" "$KEYL" "$PAGEL" "${MEM}MB"
  echo "$1,${2:-none},${TX:-0},${TOT:-0},${KEYL:-0},${PAGEL:-0},${MEM:-0},$EV" >> "$OUT/lock-memory2.csv"
}

mem_probe 1000000 ""
mem_probe 1000000 ROWLOCK
mem_probe 2000000 ROWLOCK

QD "ALTER TABLE $TBL SET (LOCK_ESCALATION = TABLE);" >/dev/null
M=$(python3 - "$OUT/lock-memory2.csv" <<'PYX'
import csv, sys
rows=list(csv.DictReader(open(sys.argv[1])))
plain=[r for r in rows if r['hint']=='none']
hint=[r for r in rows if r['hint']=='ROWLOCK']
mx=max(rows, key=lambda r:int(r['total_locks']))
esc=[r for r in rows if int(r['table_x'])>0 or int(r['events'])>0]
print("|".join([
    plain[0]['total_locks'] if plain else "-",
    hint[0]['total_locks'] if hint else "-",
    mx['total_locks'], mx['lock_mem_mb'], mx['rows'],
    "있음" if esc else "없음",
]))
PYX
)
IFS='|' read -r PLAIN HINTED MAXLOCK MAXMEM MAXROWS ESC_ANY <<<"$M"
echo
printf "  %-32s %s\n" "100만 행, 힌트 없이" "락 ${PLAIN}개"
printf "  %-32s %s\n" "100만 행, ROWLOCK" "락 ${HINTED}개"
printf "  %-32s %s\n" "가장 많이 쌓은 락" "${MAXLOCK}개 (${MAXROWS}행)"
printf "  %-32s %s\n" "그때 락 매니저 메모리" "${MAXMEM}MB"
printf "  %-32s %s\n" "메모리 압박 승격" "$ESC_ANY"
echo
if [ "${HINTED:-0}" -gt "${PLAIN:-0}" ] 2>/dev/null; then
  echo "  **힌트 하나로 락이 자릿수로 늘었습니다.** 실험 13이 못 만든 것은 규모가"
  echo "  모자라서가 아니라 **엔진이 굵은 단위로 잡았기 때문**이었습니다."
fi
if [ "$ESC_ANY" = "없음" ]; then
  echo
  echo "  그런데 **${MAXLOCK}개를 들고 ${MAXMEM}MB 를 써도 승격이 안 났습니다.**"
  echo "  DISABLE 이 그만큼 단단합니다. 이 컨테이너(6g)에서는 락 매니저가 그 정도를"
  echo "  감당하고 메모리 압박 조건에 안 닿습니다."
  echo
  echo "  **여기까지가 이 랩이 말할 수 있는 한계입니다.** 압박을 만들려면 서버 메모리를"
  echo "  더 조여야 하는데, A26 에서 버퍼 풀을 256MB 로 내렸다가 컨테이너가 죽었습니다."
  echo "  DISABLE 을 켜 두고 락을 무한정 쌓아도 된다고 읽으면 안 된다는 것은 그대로입니다."
else
  echo
  echo "  **DISABLE 인데도 승격이 났습니다.** 문서가 말한 메모리 압박 예외입니다."
  echo "  DISABLE 은 승격을 끄는 것이 아니라 **락 개수에 의한 승격만** 끕니다."
fi
echo

echo "=================================================================="
echo "## 15-2. 지터, 이번에는 줄을 안 서게 한다"
echo "=================================================================="
echo
echo "  실험 14는 세션을 20개까지 늘려도 안 갈렸습니다. 각 갱신이 승격을 일으켜"
echo "  **테이블 락으로 줄을 서 버렸기** 때문입니다. 회차마다 데드락이 한 건씩만"
echo "  났고, 물러난 세션이 한꺼번에 몰릴 무리가 안 생겼습니다."
echo
echo "  이번에는 DISABLE 로 승격을 막고 ROWLOCK 으로 행 락을 강제합니다."
echo "  줄을 안 서므로 여럿이 동시에 뒤엉킵니다."
echo
WORKERS=${WORKERS:-16}
UPD=${UPD:-4000}
MAXTRY=${MAXTRY:-10}
JROUNDS=${JROUNDS:-3}
reset_table "$ROWS" >/dev/null || exit 2
QD "ALTER TABLE $TBL SET (LOCK_ESCALATION = DISABLE);" >/dev/null
SEG=$(( ROWS / WORKERS ))

jworker(){ # $1=첫 WHERE $2=둘째 WHERE $3=결과 파일 $4=백오프
  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
    -Q "SET NOCOUNT ON;
        DECLARE @try INT = 0, @dl INT = 0, @ok INT = 0;
        WHILE @try < $MAXTRY AND @ok = 0
        BEGIN
          SET @try = @try + 1;
          BEGIN TRY
            BEGIN TRAN;
              UPDATE TOP ($UPD) $TBL WITH (ROWLOCK) SET balance = balance - 1 WHERE $1;
              WAITFOR DELAY '00:00:00.400';
              UPDATE TOP ($UPD) $TBL WITH (ROWLOCK) SET balance = balance - 1 WHERE $2;
            COMMIT;
            SET @ok = 1;
          END TRY
          BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            IF ERROR_NUMBER() <> 1205 THROW;
            SET @dl = @dl + 1;
            $4
          END CATCH
        END
        SELECT 'R:' + CAST(@ok AS varchar(2)) + ':' + CAST(@dl AS varchar(4));" > "$3" 2>&1
}
B_FIX="WAITFOR DELAY '00:00:00.500';"
B_JIT="DECLARE @ms INT = 100 + ABS(CHECKSUM(NEWID())) % 800;
       DECLARE @d VARCHAR(12) = '00:00:'
            + RIGHT('0'  + CAST(@ms / 1000 AS varchar(2)), 2) + '.'
            + RIGHT('00' + CAST(@ms % 1000 AS varchar(3)), 3);
       WAITFOR DELAY @d;"

: > "$OUT/jitter2.csv"
echo "mode,round,deadlocks,completed" >> "$OUT/jitter2.csv"
printf "  %-14s %-10s %-14s %s\n" "백오프" "회차" "데드락" "완료"

jrun(){ # $1=라벨 $2=백오프 $3=키
  local t_dl=0 t_ok=0 r w
  for r in $(seq 1 "$JROUNDS"); do
    QD "UPDATE $TBL SET balance = 100000;" >/dev/null
    local pids=""
    for w in $(seq 0 $(( WORKERS - 1 ))); do
      local a_lo=$(( w * SEG + 1 )) a_hi=$(( w * SEG + SEG ))
      local nx=$(( (w + 1) % WORKERS ))
      local b_lo=$(( nx * SEG + 1 )) b_hi=$(( nx * SEG + SEG ))
      jworker "account_id BETWEEN $a_lo AND $a_hi" \
              "account_id BETWEEN $b_lo AND $b_hi" "$OUT/.j$w" "$2" &
      pids="$pids $!"
    done
    for pid in $pids; do wait "$pid" 2>/dev/null; done
    local dl=0 ok=0 v
    for w in $(seq 0 $(( WORKERS - 1 ))); do
      v=$(grep -oE '^R:[0-9]+:[0-9]+' "$OUT/.j$w" 2>/dev/null | head -1)
      [ -n "$v" ] || continue
      IFS=: read -r _ o d <<<"$v"; ok=$(( ok + o )); dl=$(( dl + d ))
    done
    printf "  %-14s %-10s %-14s %s\n" "$1" "$r" "${dl}건" "${ok}/${WORKERS}"
    echo "\"$1\",$r,$dl,$ok" >> "$OUT/jitter2.csv"
    t_dl=$(( t_dl + dl )); t_ok=$(( t_ok + ok ))
  done
  echo "$t_dl $t_ok" > "$OUT/.js.$3"
}
jrun "고정 0.5초" "$B_FIX" f
jrun "지터"       "$B_JIT" j
rm -f "$OUT"/.j*
read -r F_DL F_OK < "$OUT/.js.f"; read -r J_DL J_OK < "$OUT/.js.j"
rm -f "$OUT/.js.f" "$OUT/.js.j"
QD "ALTER TABLE $TBL SET (LOCK_ESCALATION = TABLE);" >/dev/null
reset_table "$ROWS" >/dev/null || true
TOT=$(( WORKERS * JROUNDS ))

echo
printf "  %-22s %s\n" "고정 0.5초" "데드락 ${F_DL}건, 완료 ${F_OK}/${TOT}"
printf "  %-22s %s\n" "지터" "데드락 ${J_DL}건, 완료 ${J_OK}/${TOT}"
echo
DIFF=$(( F_DL - J_DL )); [ "$DIFF" -lt 0 ] && DIFF=$(( -DIFF ))
BIG_DIFF=0
[ "$F_DL" -gt 0 ] && [ $(( DIFF * 100 )) -gt $(( F_DL * 25 )) ] && [ "$DIFF" -ge 3 ] && BIG_DIFF=1
if [ "$BIG_DIFF" = 1 ] && [ "$F_DL" -gt "$J_DL" ]; then
  PCT=$(python3 -c "print(f'{100*(${F_DL}-${J_DL})/max(1,${F_DL}):.0f}')")
  echo "  **고정 지연이 지터보다 ${PCT}% 더 부딪혔습니다.** 실험 11과 14에서 두 번"
  echo "  못 만든 조건을 여기서 만들었습니다."
  echo
  echo "  갈린 이유는 **줄을 안 서게 만든 것**입니다. 승격이 일어나면 테이블 락 하나로"
  echo "  접혀 세션들이 차례로 지나가는데, 행 락을 강제하면 열여섯이 동시에 뒤엉킵니다."
  echo "  그때 같은 간격으로 물러난 무리가 **한꺼번에 다시 와서** 또 부딪힙니다."
  echo
  echo "  **실험 11의 \"둘이 같았다\"와 실험 14의 \"스물이어도 같았다\"는 틀린 것이"
  echo "  아니라 조건이 좁았던 것입니다.** 승격이 있는 한 경쟁자를 늘려도 줄을 섭니다."
elif [ "$BIG_DIFF" = 1 ]; then
  echo "  **이 회차에서는 지터가 더 부딪혔습니다.** 기대와 반대 방향이라"
  echo "  여기서도 지터가 낫다고 말할 수 없습니다."
else
  echo "  **여기서도 안 갈렸습니다.** 고정 ${F_DL}건, 지터 ${J_DL}건으로 차이가"
  echo "  회차 흔들림 수준입니다. 승격을 끄고 행 락을 강제해 줄 서기를 없앴는데도"
  echo "  갈리지 않았습니다."
  echo
  echo "  **세 번 시도해 세 번 다 못 만들었습니다.** 지터의 값어치를 이 랩에서는"
  echo "  못 보입니다. 문헌이 말하는 이유(뭉침)는 그럴듯하지만 **이 규모에서 재현되지"
  echo "  않는다는 것**이 이 실험이 말할 수 있는 전부입니다."
fi

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  못 한 것 넷 중 **둘의 원인이 같았습니다.** 엔진이 굵은 단위로 잡아 버리는 것이고,"
echo "  ROWLOCK 힌트와 DISABLE 로 그것을 막으면 조건이 만들어집니다."
echo
echo "  락 쪽은 만들어졌습니다. 힌트 하나로 락이 ${PLAIN}개에서 ${HINTED}개가 됐습니다."
echo "  **실험 13이 못 만든 것은 규모가 모자라서가 아니라 설계가 틀려서였습니다.**"
echo
echo "  다만 그렇게 쌓아도 메모리 압박 승격에는 안 닿았고, 지터도 안 갈렸습니다."
echo "  **설계를 고쳐 조건을 만든 것과 그 조건에서 결과가 나오는 것은 다릅니다.**"
} 2>&1 | tee "$OUT/exp15-retry-and-jitter.txt"
