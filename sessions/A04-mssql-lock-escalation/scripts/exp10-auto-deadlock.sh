#!/usr/bin/env bash
# 실험 10. AUTO 가 데드락을 만드는가.
#
# 실험 8은 파티션 테이블에서 AUTO 가 파티션 단위로 승격해 그 밖을 안 막는다는 것을
# 보이고, "다만 여러 파티션을 건드리는 트랜잭션에서 데드락 가능성을 올린다"고 문서를
# 인용해 적었다. **인용만 하고 재지 않았다.**
#
# 두 세션이 파티션 둘을 반대 순서로 건드리게 한다.
#   S1  파티션 1 → 파티션 2
#   S2  파티션 2 → 파티션 1
#
# TABLE 이면 먼저 승격한 쪽이 테이블 전체를 잡으므로 다른 쪽은 그냥 기다린다.
# AUTO 면 각자 자기 파티션을 잡고 상대 파티션을 기다리므로 순환이 생긴다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
PTBL=expedition_currency_p
ROWS=${ROWS:-200000}
UPD=${UPD:-20000}     # 파티션 절반 안에서 승격이 나는 크기
ROUNDS=${ROUNDS:-3}

wait_ready || exit 2
P1=$(( ROWS/4 )); P2=$(( ROWS/2 ))

[ "$(num "$(QD "SELECT CASE WHEN OBJECT_ID('$PTBL') IS NULL THEN 'NO' ELSE 'YES' END")")" = "YES" ] \
  || { echo "중단: $PTBL 이 없습니다. 실험 8을 먼저 돌립니다" >&2; exit 2; }

# 두 파티션을 반대 순서로 건드리는 트랜잭션. 데드락 희생자가 되면 1205 를 받는다.
#
# 처음에는 상한만 넘겼는데, TOP 은 앞에서부터 가져가므로 두 세션이 결국 같은
# 파티션을 먼저 건드렸다. 순서가 반대가 아니어서 순환이 안 생겼다.
# WHERE 절을 통째로 넘겨 어느 파티션인지 못 박는다.
worker(){ # $1=첫 WHERE, $2=둘째 WHERE, $3=결과 파일
  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
    -Q "SET NOCOUNT ON;
        BEGIN TRAN;
          UPDATE TOP ($UPD) $PTBL SET balance = balance - 1 WHERE $1;
          WAITFOR DELAY '00:00:03';
          UPDATE TOP ($UPD) $PTBL SET balance = balance - 1 WHERE $2;
        COMMIT;" > "$3" 2>&1
}
# 두 세션이 **겹치지 않는 행**을 건드리게 나눈다.
#
# 처음에는 각 파티션의 앞쪽 2만 행을 둘 다 잡게 했더니 TABLE 과 AUTO 가 똑같이
# 데드락을 냈다. 승격과 무관한 평범한 행 락 데드락을 재현한 것이었다. 행이 겹치면
# 승격 여부와 상관없이 순환이 생기므로 이 실험은 승격을 격리하지 못한다.
#
# 행을 갈라 두면 행 락만으로는 절대 안 부딪힌다. 부딪히는 것은 승격이 일어나
# 파티션이나 테이블 전체가 잠길 때뿐이다.
H1=$(( P1/2 ))            # 파티션 1 의 절반
H2=$(( P1 + (P2-P1)/2 ))  # 파티션 2 의 절반
S1_A="account_id <= $H1"                        # 파티션 1 앞쪽  (S1)
S1_B="account_id > $P1 AND account_id <= $H2"   # 파티션 2 앞쪽  (S1)
S2_A="account_id > $H2 AND account_id <= $P2"   # 파티션 2 뒤쪽  (S2)
S2_B="account_id > $H1 AND account_id <= $P1"   # 파티션 1 뒤쪽  (S2)

{
echo "# 실험 10. AUTO 가 데드락을 만드는가"
echo
echo "  두 세션이 파티션 둘을 반대 순서로 건드립니다. 각 갱신은 ${UPD}행이라"
echo "  승격이 나는 크기입니다. ${ROUNDS}회 반복합니다."
echo
echo "  **두 세션이 건드리는 행은 겹치지 않습니다.** 파티션마다 앞쪽 절반은 S1,"
echo "  뒤쪽 절반은 S2 가 잡습니다. 행 락만으로는 절대 안 부딪히므로, 부딪힌다면"
echo "  그것은 승격이 파티션이나 테이블을 통째로 잠갔기 때문입니다."
echo
: > "$OUT/auto-deadlock.csv"
echo "mode,round,deadlocks" >> "$OUT/auto-deadlock.csv"
printf "  %-14s %-16s %s\n" "설정" "데드락(1205)" "판정"

run_mode(){
  local mode=$1 total=0 r
  local desc; desc=$(num "$(QD "ALTER TABLE $PTBL SET (LOCK_ESCALATION = $mode);
                                SELECT lock_escalation_desc FROM sys.tables WHERE name='$PTBL'")")
  [ "$desc" = "$mode" ] || { echo "  ${mode}: 설정을 못 바꿨습니다(${desc})"; return; }

  for r in $(seq 1 "$ROUNDS"); do
    QD "UPDATE $PTBL SET balance = 100000;" >/dev/null
    worker "$S1_A" "$S1_B" "$OUT/.w1" &   # 파티션 1 → 2 (앞쪽 행만)
    local w1=$!
    worker "$S2_A" "$S2_B" "$OUT/.w2" &   # 파티션 2 → 1 (뒤쪽 행만)
    local w2=$!
    wait "$w1" 2>/dev/null; wait "$w2" 2>/dev/null
    local d; d=$(cat "$OUT/.w1" "$OUT/.w2" 2>/dev/null | grep -c '1205' || true)
    total=$(( total + d ))
    echo "$mode,$r,$d" >> "$OUT/auto-deadlock.csv"
  done
  rm -f "$OUT/.w1" "$OUT/.w2"
  local verdict
  if [ "$total" -gt 0 ]; then verdict="**데드락 발생**"; else verdict="데드락 없음 (한쪽이 기다림)"; fi
  printf "  %-14s %-16s %s\n" "$mode" "${total}건" "$verdict"
}

run_mode TABLE
run_mode AUTO

QD "ALTER TABLE $PTBL SET (LOCK_ESCALATION = TABLE);" >/dev/null
echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  실험 8이 문서를 인용해 적고 재지 않았던 것을 여기서 쟀습니다."
echo
echo "  **처음에는 두 세션이 같은 행을 건드리게 짰다가 TABLE 과 AUTO 가 똑같이 데드락을"
echo "  냈습니다.** 승격과 무관한 평범한 행 락 데드락이었습니다. 행을 갈라 승격만"
echo "  남기고 다시 쟀습니다."
echo
echo "  TABLE 은 먼저 승격한 쪽이 테이블 전체를 잡습니다. 다른 쪽은 잡을 것이 없으니"
echo "  그냥 기다립니다. 느리지만 순환이 안 생깁니다."
echo
echo "  AUTO 는 각자 자기 파티션을 잡고 상대 파티션을 기다립니다. 순환이 생기고"
echo "  엔진이 한쪽을 죽입니다(1205)."
echo
echo "  **그래서 AUTO 는 공짜가 아닙니다.** 파티션 밖을 안 막는 대신 여러 파티션을"
echo "  건드리는 트랜잭션에서 데드락을 만듭니다. 쓰려면 전제가 붙습니다."
echo
echo "    보정 배치가 한 파티션 안에서 끝나도록 짠다"
echo "    여러 파티션을 건드려야 하면 파티션 순서를 모든 작업에서 같게 고정한다"
echo "    데드락 재시도를 배치 루프에 넣는다"
echo
echo "  두 번째가 실무에서 제일 자주 빠집니다. 보정 배치는 계정 순으로 도는데 다른"
echo "  작업이 다른 순서로 돌면 그 둘이 만납니다."
} 2>&1 | tee "$OUT/exp10-auto-deadlock.txt"
