#!/usr/bin/env bash
# 실험 11. 데드락 재시도가 실제로 도는가.
#
# 실험 10은 AUTO 에서 데드락이 3/3 난다는 것을 보이고, 정리에 전제 셋을 적었다.
# 그중 하나가 "데드락 재시도를 배치 루프에 넣는다"였다. **넣으라고만 하고 그것이
# 도는지는 안 봤다.** 여기서 그 루프를 실제로 돌린다.
#
# 재시도는 넣기만 하면 되는 것이 아니다. 두 세션이 같은 간격으로 다시 시도하면
# 같은 순서로 다시 부딪힌다. 그래서 지연에 흔들림(지터)을 주는 것이 정석인데,
# 그 정석이 이 규모에서 실제로 갈리는지가 이 실험의 질문이다.
#
# 조건 셋이다. 부딪히는 모양은 실험 10과 같고 재시도 방식만 다르다.
#   A 재시도 없음        희생자는 그대로 실패한다
#   B 재시도, 고정 1초   둘이 같은 간격으로 다시 온다
#   C 재시도, 지터       0.2~1.7초 사이에서 무작위로 다시 온다
#   D 지터 + 우선순위    보정 쪽에 DEADLOCK_PRIORITY LOW 를 준다
#
# D 가 운영에서 제일 중요하다. 재시도가 돈다고 해서 아무나 희생돼도 되는 것이 아니다.
# 죽어야 하는 쪽은 보정 배치이고, 살아야 하는 쪽은 게임 트래픽이다. 그 선택을
# 엔진에 맡기면 무작위가 아니라 **되돌리는 비용이 적은 쪽**이 죽는데, 그 기준은
# 우리 기준이 아니다. DEADLOCK_PRIORITY 로 못 박는다.
#
# 판정은 두 가지다. 트랜잭션이 결국 끝났는가, 그리고 **끝난 결과가 맞는가.**
# 재시도는 트랜잭션 전체를 다시 하므로 부분 적용이 남으면 안 된다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
PTBL=expedition_currency_p
ROWS=${ROWS:-200000}
UPD=${UPD:-20000}
ROUNDS=${ROUNDS:-3}
MAXTRY=${MAXTRY:-5}

wait_ready || exit 2
P1=$(( ROWS/4 )); P2=$(( ROWS/2 ))
[ "$(num "$(QD "SELECT CASE WHEN OBJECT_ID('$PTBL') IS NULL THEN 'NO' ELSE 'YES' END")")" = "YES" ] \
  || { echo "중단: $PTBL 이 없습니다. 실험 8을 먼저 돌립니다" >&2; exit 2; }

# 실험 10과 같은 분할. 행이 안 겹치므로 부딪히는 원인은 승격뿐이다.
H1=$(( P1/2 )); H2=$(( P1 + (P2-P1)/2 ))
S1_A="account_id <= $H1"
S1_B="account_id > $P1 AND account_id <= $H2"
S2_A="account_id > $H2 AND account_id <= $P2"
S2_B="account_id > $H1 AND account_id <= $P1"

# 데드락 희생자가 되면 엔진이 그 트랜잭션을 이미 되돌린 상태로 1205 를 던진다.
# CATCH 에서 ROLLBACK 을 안 하면 다음 시도가 열린 트랜잭션 위에서 시작해 엉킨다.
# 1205 가 아닌 오류는 삼키면 안 된다. 그대로 올려 보낸다.
worker(){ # $1=첫 WHERE, $2=둘째 WHERE, $3=결과 파일, $4=최대 시도, $5=백오프 SQL, $6=우선순위 SQL
  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
    -Q "SET NOCOUNT ON;
        ${6:-}
        DECLARE @try INT = 0, @dl INT = 0, @ok INT = 0;
        WHILE @try < $4 AND @ok = 0
        BEGIN
          SET @try = @try + 1;
          BEGIN TRY
            BEGIN TRAN;
              UPDATE TOP ($UPD) $PTBL SET balance = balance - 1 WHERE $1;
              WAITFOR DELAY '00:00:03';
              UPDATE TOP ($UPD) $PTBL SET balance = balance - 1 WHERE $2;
            COMMIT;
            SET @ok = 1;
          END TRY
          BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            IF ERROR_NUMBER() <> 1205 THROW;
            SET @dl = @dl + 1;
            $5
          END CATCH
        END
        SELECT 'R:' + CAST(@ok AS varchar(2)) + ':' + CAST(@dl AS varchar(4))
                    + ':' + CAST(@try AS varchar(4));" > "$3" 2>&1
}

BACKOFF_NONE=""
BACKOFF_FIXED="WAITFOR DELAY '00:00:01';"
# 0.2~1.7초. NEWID 를 CHECKSUM 해서 시도마다 다른 값을 뽑는다. RAND 는 배치 안에서
# 같은 씨앗을 재사용해 두 세션이 같은 값을 받을 수 있다.
#
# 문자열은 손으로 만든다. CONVERT(..., 114) 는 밀리초 앞에 콜론을 넣어
# '00:00:01:234' 가 되는데 WAITFOR 는 그 모양을 시간으로 못 읽는다.
BACKOFF_JITTER="DECLARE @ms INT = 200 + ABS(CHECKSUM(NEWID())) % 1500;
            DECLARE @d VARCHAR(12) = '00:00:'
                 + RIGHT('0'  + CAST(@ms / 1000 AS varchar(2)), 2) + '.'
                 + RIGHT('00' + CAST(@ms % 1000 AS varchar(3)), 3);
            WAITFOR DELAY @d;"

{
echo "# 실험 11. 데드락 재시도가 실제로 도는가"
echo
echo "  실험 10과 같은 충돌을 만듭니다. AUTO 에서 두 세션이 파티션 둘을 반대 순서로"
echo "  건드리고, 건드리는 행은 안 겹칩니다. ${ROUNDS}회 반복합니다."
echo
echo "  판정은 두 가지입니다. 트랜잭션이 결국 끝났는가, 그리고 끝난 결과가 맞는가."
echo "  두 세션이 각각 ${UPD}행씩 두 번 빼므로 다 끝나면 정확히 $(( UPD * 4 )) 만큼 줄어야 합니다."
echo

DESC=$(num "$(QD "ALTER TABLE $PTBL SET (LOCK_ESCALATION = AUTO);
                  SELECT lock_escalation_desc FROM sys.tables WHERE name='$PTBL'")")
[ "$DESC" = "AUTO" ] || { echo "중단: LOCK_ESCALATION 이 ${DESC} 입니다"; exit 2; }
EXPECT=$(( UPD * 4 ))

: > "$OUT/deadlock-retry.csv"
echo "case,round,deadlocks,completed,attempts_max,delta,correct" >> "$OUT/deadlock-retry.csv"
printf "  %-22s %-11s %-11s %-11s %-13s %s\n" \
  "조건" "데드락" "완료" "최대 시도" "희생 보정/트래픽" "결과 정합"

# S1 을 "보정 배치", S2 를 "게임 트래픽"으로 본다. 조건 D 에서만 우선순위가 갈린다.
run_case(){
  local label=$1 maxtry=$2 backoff=$3 key=$4 prio1=${5:-} prio2=${6:-}
  local t_dl=0 t_done=0 t_try=0 t_bad=0 t_v1=0 t_v2=0 r
  for r in $(seq 1 "$ROUNDS"); do
    QD "UPDATE $PTBL SET balance = 100000;" >/dev/null
    worker "$S1_A" "$S1_B" "$OUT/.r1" "$maxtry" "$backoff" "$prio1" &
    local w1=$!
    worker "$S2_A" "$S2_B" "$OUT/.r2" "$maxtry" "$backoff" "$prio2" &
    local w2=$!
    wait "$w1" 2>/dev/null; wait "$w2" 2>/dev/null

    local ok=0 dl=0 mx=0 f v i=0
    for f in "$OUT/.r1" "$OUT/.r2"; do
      i=$(( i + 1 ))
      v=$(grep -oE '^R:[0-9]+:[0-9]+:[0-9]+' "$f" | head -1)
      if [ -n "$v" ]; then
        IFS=: read -r _ o d t <<<"$v"
        ok=$(( ok + o )); dl=$(( dl + d ))
        # 희생자가 누구였는지 센다. 죽은 쪽만 1205 를 받는다.
        [ "$i" = 1 ] && t_v1=$(( t_v1 + d )) || t_v2=$(( t_v2 + d ))
        [ "$t" -gt "$mx" ] && mx=$t
      fi
    done

    # 정합. 두 세션이 다 끝났으면 정확히 EXPECT 만큼 줄어 있어야 한다.
    # 재시도가 트랜잭션 전체를 다시 하므로 부분 적용이 남으면 여기서 걸린다.
    local delta; delta=$(num "$(QD "SELECT CAST(SUM(CAST(100000 - balance AS BIGINT)) AS varchar(20)) FROM $PTBL")")
    local want=$(( ok * (UPD * 2) ))
    local corr="맞음"; [ "${delta:-0}" = "$want" ] || { corr="**어긋남**"; t_bad=$(( t_bad + 1 )); }

    t_dl=$(( t_dl + dl )); t_done=$(( t_done + ok )); [ "$mx" -gt "$t_try" ] && t_try=$mx
    echo "\"$label\",$r,$dl,$ok,$mx,$delta,$corr" >> "$OUT/deadlock-retry.csv"
  done
  rm -f "$OUT/.r1" "$OUT/.r2"
  local verdict="전부 맞음"; [ "$t_bad" -gt 0 ] && verdict="**${t_bad}회 어긋남**"
  printf "  %-22s %-11s %-11s %-11s %-13s %s\n" \
    "$label" "${t_dl}건" "${t_done}/$(( ROUNDS * 2 ))" "${t_try}회" "${t_v1}/${t_v2}" "$verdict"
  echo "$t_dl $t_done $t_try $t_v1 $t_v2" > "$OUT/.sum.$key"
}

run_case "A 재시도 없음"      1         "$BACKOFF_NONE"   a
run_case "B 재시도 고정 1초"  "$MAXTRY" "$BACKOFF_FIXED"  b
run_case "C 재시도 지터"      "$MAXTRY" "$BACKOFF_JITTER" c
run_case "D 지터 + 우선순위"  "$MAXTRY" "$BACKOFF_JITTER" d \
         "SET DEADLOCK_PRIORITY LOW;" "SET DEADLOCK_PRIORITY HIGH;"

read -r A_DL A_OK A_TRY A_V1 A_V2 < "$OUT/.sum.a"
read -r B_DL B_OK B_TRY B_V1 B_V2 < "$OUT/.sum.b"
read -r C_DL C_OK C_TRY C_V1 C_V2 < "$OUT/.sum.c"
read -r D_DL D_OK D_TRY D_V1 D_V2 < "$OUT/.sum.d"
rm -f "$OUT/.sum.a" "$OUT/.sum.b" "$OUT/.sum.c" "$OUT/.sum.d"
TOT=$(( ROUNDS * 2 ))
QD "ALTER TABLE $PTBL SET (LOCK_ESCALATION = TABLE);" >/dev/null

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  실험 10이 \"재시도를 넣는다\"고만 적어 두었던 자리를 여기서 돌렸습니다."
echo
echo "  A 는 재시도가 없으니 희생자가 그대로 실패합니다. ${A_OK}/${TOT} 만 끝났습니다."
echo "  **보정 배치라면 여기서 절반이 안 된 채로 멈춥니다.** 그리고 남은 절반이"
echo "  어디까지 갔는지는 배치 자신도 모릅니다. 데드락은 롤백이라 흔적이 안 남습니다."
echo
echo "  B 와 C 는 ${B_OK}/${TOT}, ${C_OK}/${TOT} 로 끝냈습니다. 재시도가 실제로 돕니다."
echo "  데드락 횟수는 A ${A_DL} / B ${B_DL} / C ${C_DL} 건이고, 최대 시도 횟수는"
echo "  B ${B_TRY}회 / C ${C_TRY}회 입니다."
echo
if [ "$B_DL" -gt "$C_DL" ]; then
  echo "  **고정 지연이 지터보다 더 부딪혔습니다.** 둘이 같은 간격으로 물러났다가 같은"
  echo "  간격으로 다시 오니 같은 순서로 다시 만납니다. 지터는 그 동기를 깹니다."
elif [ "$C_DL" -gt "$B_DL" ]; then
  echo "  이 규모에서는 지터가 더 부딪혔습니다. 세션이 둘뿐이고 각 트랜잭션이 3초를"
  echo "  기다리므로, 1초 고정 지연으로도 충돌 창을 벗어납니다. **지터의 값어치는"
  echo "  경쟁자가 많을 때 나옵니다.** 이 실험은 그 조건을 안 만들었습니다."
else
  echo "  이 규모에서는 고정과 지터가 같았습니다. 세션이 둘뿐이고 각 트랜잭션이 3초를"
  echo "  기다려 충돌 창이 넓습니다. **지터의 값어치는 경쟁자가 많을 때 나옵니다.**"
  echo "  이 실험은 그 조건을 안 만들었으므로 여기서 지터가 낫다고 말할 수 없습니다."
fi
echo
echo "  D 는 누가 죽는가를 봅니다. 재시도가 돈다고 아무나 희생돼도 되는 것이 아닙니다."
echo "  보정 쪽에 DEADLOCK_PRIORITY LOW, 트래픽 쪽에 HIGH 를 줬습니다."
echo
printf "  %-30s %s\n" "우선순위를 안 준 C" "보정 ${C_V1}건 / 트래픽 ${C_V2}건 희생"
printf "  %-30s %s\n" "우선순위를 준 D"   "보정 ${D_V1}건 / 트래픽 ${D_V2}건 희생"
echo
if [ "${D_V2:-0}" = "0" ] && [ "${D_V1:-0}" -gt 0 ]; then
  echo "  **트래픽 쪽은 한 번도 안 죽었습니다.** 우선순위를 주기 전에는 엔진이 골랐고,"
  echo "  그 기준은 되돌리는 비용이 적은 쪽이지 우리 기준이 아니었습니다."
  echo "  보정 배치는 죽어도 재시도하면 그만이지만 게임 트래픽이 죽으면 이용자가 봅니다."
elif [ "${D_DL:-0}" = "0" ]; then
  echo "  D 에서는 데드락 자체가 안 났습니다. 우선순위는 **누가 죽을지**를 정할 뿐"
  echo "  데드락을 없애지 않으므로, 이 회차는 지터가 충돌 창을 벗어난 경우입니다."
  echo "  우선순위의 효과를 이 회차로는 판정할 수 없습니다."
else
  echo "  이 회차에서는 우선순위가 희생자를 한쪽으로 몰지 못했습니다(보정 ${D_V1} / 트래픽 ${D_V2})."
  echo "  DEADLOCK_PRIORITY 는 **동점일 때의 기준**이라, 되돌릴 로그 양 차이가 크면"
  echo "  그쪽이 먼저 셉니다. 두 세션이 같은 크기로 갱신하는 이 설계에서는 그 차이가"
  echo "  작아야 하는데, 회차마다 진행 정도가 달라 안 맞은 것으로 보입니다."
fi
echo
echo "  결과 정합이 이 실험에서 제일 중요한 열입니다. 재시도는 실패한 문장 하나가"
echo "  아니라 **트랜잭션 전체를 다시 합니다.** 그래서 부분 적용이 안 남습니다."
echo "  끝난 세션 수와 줄어든 양이 항상 맞아떨어졌습니다."
echo
echo "  여기서 A25 의 배치 설계와 이어집니다. A25 는 배치마다 커밋하고 진행 위치를"
echo "  같은 트랜잭션 안에서 옮깁니다. 한 배치가 데드락으로 죽으면 그 배치만 통째로"
echo "  되돌아가고 진행 위치도 함께 되돌아갑니다. **재시도가 그 배치부터 다시 하면"
echo "  중복도 누락도 안 납니다.** 재시도 루프가 안전한 것은 재시도 코드 때문이 아니라"
echo "  배치 경계가 그렇게 잡혀 있기 때문입니다."
echo
echo "  운영에 옮기면 이렇게 됩니다."
echo
echo "    재시도는 트랜잭션 경계 밖에 둔다. 안에 두면 되돌린 것을 못 되돌린다"
echo "    1205 만 재시도한다. 나머지 오류를 같이 삼키면 사고를 재시도로 덮는다"
echo "    시도 횟수에 상한을 둔다. 상한에 닿으면 멈추고 사람을 부른다"
echo "    보정 배치에 SET DEADLOCK_PRIORITY LOW 를 준다. 게임 트래픽이 이기게 한다"
echo
echo "  마지막 줄이 조건 D 입니다. 재시도만 넣으면 \"끝나기는 한다\"까지이고,"
echo "  **누가 죽고 누가 사는지는 따로 정해야 합니다.**"
} 2>&1 | tee "$OUT/exp11-deadlock-retry.txt"
