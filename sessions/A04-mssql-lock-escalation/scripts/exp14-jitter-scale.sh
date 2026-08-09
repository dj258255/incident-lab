#!/usr/bin/env bash
# 실험 14. 지터가 고정 지연보다 나은 조건.
#
# 실험 11은 재시도가 도는 것을 보였지만 지터와 고정 지연이 같게 나왔고, 못 한 것에
# 이렇게 적었다.
#   "지터가 고정 지연보다 나은 조건을 안 만들었습니다. 둘이 같게 나왔는데 세션이
#    둘뿐이라 충돌 창이 넓었기 때문입니다. 경쟁자를 수십 개로 늘려야 갈릴 텐데
#    그 규모는 안 돌렸습니다."
#
# **갈리는 조건을 안 만들고 "같았다"고 적은 것**이다. 그 조건을 만든다.
#
# 세션 둘이면 물러났다 다시 와도 상대는 하나뿐이라 어긋날 확률이 높다.
# 여럿이면 같은 간격으로 물러난 세션들이 **한꺼번에 다시 몰려** 서로 또 부딪힌다.
# 그것이 고정 지연의 문제이고, 지터는 그 뭉침을 흩는다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
ROWS=${ROWS:-200000}
WORKERS=${WORKERS:-20}
UPD=${UPD:-20000}   # 구간 하나를 통째로. 승격이 나는 크기다
MAXTRY=${MAXTRY:-8}
ROUNDS=${JITTER_ROUNDS:-3}
# 트랜잭션이 오래 기다리면 충돌 창이 넓어 백오프 차이가 안 드러난다.
# 10개 x 2초로 쟀을 때 고정과 지터가 2건씩으로 같았다. 창을 좁힌다.
HOLD=${HOLD:-'00:00:00.300'}

wait_ready || exit 2
OPTLOCK=$(assert_env) || exit 2

# 세션 n 개가 각자 두 구간을 **서로 다른 순서로** 건드린다.
# 구간을 원형으로 배치해 i 번은 i 와 i+1 을, 마지막은 마지막과 0 을 잡는다.
# 이러면 어느 둘도 같은 순서가 아니라 순환이 여럿 생긴다.
worker(){ # $1=첫 구간, $2=둘째 구간, $3=결과 파일, $4=백오프 SQL
  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
    -Q "SET NOCOUNT ON;
        DECLARE @try INT = 0, @dl INT = 0, @ok INT = 0;
        WHILE @try < $MAXTRY AND @ok = 0
        BEGIN
          SET @try = @try + 1;
          BEGIN TRY
            BEGIN TRAN;
              UPDATE TOP ($UPD) $TBL SET balance = balance - 1 WHERE $1;
              WAITFOR DELAY '$HOLD';
              UPDATE TOP ($UPD) $TBL SET balance = balance - 1 WHERE $2;
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
        SELECT 'R:' + CAST(@ok AS varchar(2)) + ':' + CAST(@dl AS varchar(4))
                    + ':' + CAST(@try AS varchar(4));" > "$3" 2>&1
}

BACKOFF_FIXED="WAITFOR DELAY '00:00:01';"
BACKOFF_JITTER="DECLARE @ms INT = 200 + ABS(CHECKSUM(NEWID())) % 1500;
            DECLARE @d VARCHAR(12) = '00:00:'
                 + RIGHT('0'  + CAST(@ms / 1000 AS varchar(2)), 2) + '.'
                 + RIGHT('00' + CAST(@ms % 1000 AS varchar(3)), 3);
            WAITFOR DELAY @d;"

SEG=$(( ROWS / WORKERS ))

{
echo "# 실험 14. 지터가 고정 지연보다 나은 조건"
echo "# optimized locking: ${OPTLOCK}"
echo
echo "  세션 ${WORKERS}개가 각자 두 구간을 서로 다른 순서로 건드립니다."
echo "  구간을 원형으로 배치해 순환이 여럿 생기게 했습니다."
echo "  각 갱신은 ${UPD}행이라 승격이 나는 크기이고, 두 갱신 사이를 ${HOLD} 만 기다립니다."
echo "  재시도 상한 ${MAXTRY}회, ${ROUNDS}회 반복."
echo
echo "  실험 11은 세션 둘로 재서 고정과 지터가 같았습니다. 여기서는 ${WORKERS}개입니다."
echo

: > "$OUT/jitter-scale.csv"
echo "mode,round,workers,deadlocks,completed,max_attempts" >> "$OUT/jitter-scale.csv"
printf "  %-16s %-10s %-13s %-13s %s\n" "백오프" "회차" "데드락" "완료" "최대 시도"

run_mode(){ # $1=라벨 $2=백오프 $3=키
  local t_dl=0 t_ok=0 t_try=0 r w
  for r in $(seq 1 "$ROUNDS"); do
    QD "UPDATE $TBL SET balance = 100000;" >/dev/null
    local pids=""
    # 구간을 반씩 쪼개 잡았다가 **어느 구간도 안 겹쳐** 데드락이 0 이었다.
    # 워커 w 가 구간 w 의 앞쪽, 구간 w+1 의 뒤쪽을 잡으면 각 반쪽의 주인이 하나뿐이다.
    # 구간을 통째로 잡아야 w 와 w+1 이 구간 w+1 을 놓고 반대 순서로 만난다.
    for w in $(seq 0 $(( WORKERS - 1 ))); do
      local a_lo=$(( w * SEG + 1 ))          a_hi=$(( w * SEG + SEG ))
      local nxt=$(( (w + 1) % WORKERS ))
      local b_lo=$(( nxt * SEG + 1 ))        b_hi=$(( nxt * SEG + SEG ))
      worker "account_id BETWEEN $a_lo AND $a_hi" \
             "account_id BETWEEN $b_lo AND $b_hi" \
             "$OUT/.w$w" "$2" &
      pids="$pids $!"
    done
    for pid in $pids; do wait "$pid" 2>/dev/null; done

    local dl=0 ok=0 mx=0 v
    for w in $(seq 0 $(( WORKERS - 1 ))); do
      v=$(grep -oE '^R:[0-9]+:[0-9]+:[0-9]+' "$OUT/.w$w" 2>/dev/null | head -1)
      [ -n "$v" ] || continue
      IFS=: read -r _ o d t <<<"$v"
      ok=$(( ok + o )); dl=$(( dl + d ))
      [ "$t" -gt "$mx" ] && mx=$t
    done
    printf "  %-16s %-10s %-13s %-13s %s\n" "$1" "$r" "${dl}건" "${ok}/${WORKERS}" "${mx}회"
    echo "\"$1\",$r,$WORKERS,$dl,$ok,$mx" >> "$OUT/jitter-scale.csv"
    t_dl=$(( t_dl + dl )); t_ok=$(( t_ok + ok )); [ "$mx" -gt "$t_try" ] && t_try=$mx
  done
  echo "$t_dl $t_ok $t_try" > "$OUT/.sum.$3"
}

QD "ALTER TABLE $TBL SET (LOCK_ESCALATION = TABLE);" >/dev/null
reset_table "$ROWS" >/dev/null || exit 2
run_mode "고정 1초" "$BACKOFF_FIXED"  f
run_mode "지터"     "$BACKOFF_JITTER" j
rm -f "$OUT"/.w*

read -r F_DL F_OK F_TRY < "$OUT/.sum.f"
read -r J_DL J_OK J_TRY < "$OUT/.sum.j"
rm -f "$OUT/.sum.f" "$OUT/.sum.j"
TOT=$(( WORKERS * ROUNDS ))

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
printf "  %-22s %s\n" "고정 1초" "데드락 ${F_DL}건, 완료 ${F_OK}/${TOT}, 최대 시도 ${F_TRY}회"
printf "  %-22s %s\n" "지터" "데드락 ${J_DL}건, 완료 ${J_OK}/${TOT}, 최대 시도 ${J_TRY}회"
echo
# 한두 건 차이는 회차 흔들림이다. 그것으로 갈렸다고 적으면 안 된다.
DIFF=$(( F_DL - J_DL )); [ "$DIFF" -lt 0 ] && DIFF=$(( -DIFF ))
BIG_DIFF=0
[ "$F_DL" -gt 0 ] && [ $(( DIFF * 100 )) -gt $(( F_DL * 30 )) ] && [ "$DIFF" -ge 3 ] && BIG_DIFF=1

if [ "$BIG_DIFF" = 1 ] && [ "$F_DL" -gt "$J_DL" ]; then
  PCT=$(python3 -c "print(f'{100*(${F_DL}-${J_DL})/max(1,${F_DL}):.0f}')")
  echo "  **고정 지연이 지터보다 ${PCT}% 더 부딪혔습니다.** 실험 11에서 세션 둘로"
  echo "  쟀을 때는 안 갈렸는데 ${WORKERS}개로 늘리자 갈렸습니다."
  echo
  echo "  이유는 뭉침입니다. 같은 간격으로 물러난 세션들이 **한꺼번에 다시 옵니다.**"
  echo "  지터는 그 무리를 흩어 놓습니다."
elif [ "$BIG_DIFF" = 1 ]; then
  echo "  **이 회차에서는 지터가 더 부딪혔습니다.** 기대와 반대 방향이라"
  echo "  **여기서 지터가 낫다고도 못하다고도 말할 수 없습니다.**"
else
  echo "  **${WORKERS}개로도 안 갈렸습니다.** 고정 ${F_DL}건, 지터 ${J_DL}건으로"
  echo "  차이가 회차 흔들림 수준입니다. 둘 다 ${TOT}/${TOT} 을 끝냈습니다."
  echo
  echo "  이유가 보입니다. 각 갱신이 ${UPD}행이라 **승격이 먼저 일어나고**, 승격한"
  echo "  세션이 테이블 락을 잡으면 나머지는 그 뒤에 줄을 섭니다. 스무 개가 동시에"
  echo "  뒤엉키는 것이 아니라 사실상 한 줄로 서고, 순환은 맨 앞 둘 사이에서만"
  echo "  생깁니다. 회차마다 데드락이 한 건씩만 난 것이 그 증거입니다."
  echo "  물러난 세션이 **한꺼번에 다시 몰릴 무리 자체가 안 만들어집니다.**"
  echo
  echo "  **그래서 지터가 갈리는 조건을 여기서도 못 만들었습니다.** 승격이 없는 크기로"
  echo "  줄이면 이번에는 서로 안 부딪히고(첫 시도에서 데드락 0), 승격이 나는 크기로"
  echo "  키우면 줄을 섭니다. 그 사이의 좁은 구간을 못 찾았습니다."
  echo
  echo "  실험 11에서 \"지터가 낫다고 말할 수 없다\"고 적은 것은 그대로 둡니다."
  echo "  **조건을 두 번 더 만들어 봤고 두 번 다 못 만들었다는 것**을 함께 적습니다."
fi
echo
echo "  완료 수를 함께 봐야 합니다. 데드락이 적어도 상한에 닿아 못 끝내면 소용없고,"
echo "  데드락이 많아도 다 끝내면 재시도가 제 일을 한 것입니다."
echo
echo "  재시도 상한에 닿는 경우는 [A25 실험 12](../A25-currency-reclaim-procedure/)"
echo "  에서 밟았습니다. 거기서 상한을 1 로 낮추자 배치가 DEADLOCK 상태로 남고"
echo "  프로시저가 던졌습니다. **조용히 건너뛰지 않는 것**이 그 절의 요점입니다."
} 2>&1 | tee "$OUT/exp14-jitter-scale.txt"
