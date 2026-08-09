#!/usr/bin/env bash
# 실험 12. 회수 프로시저가 데드락을 견디는가.
#
# 못 한 것에 이렇게 적어 두었다.
#   "데드락 재시도를 이 프로시저에 안 넣었습니다. A04 실험 11 에서 재시도 루프가
#    도는 것과 DEADLOCK_PRIORITY LOW 가 희생자를 뒤집는 것까지 쟀는데, 이
#    프로시저의 배치 루프에는 아직 그 코드가 없습니다."
#
# 다른 세션에서 검증한 것을 **이 프로시저에 옮기지 않은 채** 두고 있었다.
# reclaim.sql 에 재시도를 넣고 여기서 확인한다.
#
# 확인할 것이 셋이다.
#   1 경쟁이 있어도 회수가 끝나는가        재시도가 실제로 도는가
#   2 끝난 결과가 정확한가                 부분 적용이 안 남는가
#   3 상한에 닿으면 멈추고 알리는가        조용히 넘어가지 않는가
#
# 3번이 A04 에서도 못 본 자리다. 거기서는 상한 5회에 최대 2회로 끝나 도달하는
# 경우를 못 만들었다. 여기서는 상한을 1로 낮춰 그 길을 밟는다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
CHUNK=${CHUNK:-4000}

wait_ready || exit 2
[ "$(num "$(QD "SELECT CASE WHEN OBJECT_ID('reclaim_target') IS NULL THEN 'NO' ELSE 'YES' END")")" = "YES" ] \
  || { echo "중단: reclaim_target 이 없습니다. 실험 1을 먼저 돌립니다" >&2; exit 2; }

# 프로시저를 다시 심는다. 재시도가 들어간 판이다.
docker exec -i "$CT" sh -c 'cat > /tmp/reclaim.sql' < "$ROOT/scripts/reclaim.sql"
docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -d "$DB" -i /tmp/reclaim.sql >/dev/null 2>&1

TARGETS=$(num "$(QD "SELECT COUNT(*) FROM reclaim_target")")
TSUM=$(num "$(QD "SELECT CAST(SUM(extra_amount) AS varchar(30)) FROM reclaim_target")")

reset_state(){
  QDX "SET NOCOUNT ON;
  UPDATE account_currency SET balance = 100000, debt = 0;
  DELETE FROM correction_detail;
  DELETE FROM correction_batch;" || return 2
}

# 경쟁 세션. 회수 대상과 **같은 계정**을 반대 순서로 건드린다.
# 회수는 account_id 오름차순으로 돌므로 내림차순으로 가면 서로 앞을 막는다.
rival_start(){ # $1=몇 초 버틸지
  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
    -Q "SET NOCOUNT ON;
        SET DEADLOCK_PRIORITY HIGH;   -- 게임 트래픽 쪽이다. 이겨야 한다
        DECLARE @i INT = 0;
        WHILE @i < $1
        BEGIN
            BEGIN TRAN;
              UPDATE TOP (2000) a SET a.balance = a.balance + 1
                FROM account_currency a
                JOIN (SELECT TOP (2000) account_id FROM reclaim_target ORDER BY account_id DESC) t
                  ON t.account_id = a.account_id;
              WAITFOR DELAY '00:00:01';
              UPDATE TOP (2000) a SET a.balance = a.balance + 1
                FROM account_currency a
                JOIN (SELECT TOP (2000) account_id FROM reclaim_target ORDER BY account_id) t
                  ON t.account_id = a.account_id;
            COMMIT;
            SET @i = @i + 1;
        END" >/dev/null 2>&1 &
  RIVAL=$!
}

{
echo "# 실험 12. 회수 프로시저가 데드락을 견디는가"
echo
echo "  대상 ${TARGETS}계정, 회수 총액 ${TSUM}. 배치 ${CHUNK}행."
echo "  옆에서 같은 계정을 **반대 순서로** 건드리는 세션을 돌립니다."
echo "  회수는 오름차순, 경쟁 세션은 내림차순이라 서로 앞을 막습니다."
echo
echo "  경쟁 세션은 DEADLOCK_PRIORITY HIGH 입니다. 게임 트래픽이라고 보고,"
echo "  회수 쪽은 프로시저 안에서 LOW 를 잡습니다."
echo

: > "$OUT/reclaim-retry.csv"
echo "case,max_retry,completed,deadlocks,reclaimed,expected,status,msg" >> "$OUT/reclaim-retry.csv"
printf "  %-26s %-10s %-11s %-16s %s\n" "조건" "상한" "데드락" "회수액" "결과"

run_case(){ # $1=라벨 $2=상한 $3=경쟁 지속(회)
  reset_state || return 2
  rival_start "$3"
  # 경쟁 세션이 실제로 락을 잡을 때까지 기다린다. 고정 시간으로 하면 안 겹친다.
  local i
  for i in $(seq 1 30); do
    [ "$(num "$(Q "SELECT CAST(COUNT(*) AS varchar(4)) FROM sys.dm_exec_requests r
                     JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
                    WHERE s.is_user_process = 1 AND r.wait_type = 'WAITFOR'")")" -gt 0 ] 2>/dev/null && break
    sleep 1
  done

  local out
  out=$(QD "SET NOCOUNT ON;
    DECLARE @b INT, @dl INT;
    EXEC usp_ReclaimCurrency @reason = N'retry test', @mode = 'DEBT', @chunk = $CHUNK,
         @max_retry = $2, @deadlocks = @dl OUTPUT, @batch_id = @b OUTPUT;
    SELECT 'R:' + CAST(ISNULL(@dl, -1) AS varchar(8)) + ':' + CAST(ISNULL(@b, -1) AS varchar(12));")
  wait "$RIVAL" 2>/dev/null

  local m; m=$(echo "$out" | grep -oE '^(Msg|메시지) [0-9]+' | head -1)
  local v; v=$(echo "$out" | grep -oE '^R:[0-9-]+:[0-9-]+' | head -1)
  local dl=- bid=-
  [ -n "$v" ] && { IFS=: read -r _ dl bid <<<"$v"; }
  # 회수액은 감사 로그에서 센다. 경쟁 세션이 잔액을 건드리므로 잔액 차이로는 못 잰다.
  local got; got=$(num "$(QD "SET NOCOUNT ON;
    SELECT CAST(ISNULL(SUM(applied_amount + debt_amount), 0) AS varchar(30)) FROM correction_detail;")")
  local st; st=$(numsp "$(QD "SET NOCOUNT ON;
    SELECT TOP 1 status FROM correction_batch ORDER BY batch_id DESC;")")
  local done_txt="완료"; [ -n "$m" ] && done_txt="**중단** $m"
  local ok="정확"; [ "$got" = "$TSUM" ] || ok="**어긋남**"
  [ -n "$m" ] && ok="-"
  printf "  %-26s %-10s %-11s %-16s %s\n" "$1" "$2" "${dl}건" "${got} (${ok})" "${done_txt} / ${st}"
  echo "\"$1\",$2,\"$done_txt\",$dl,$got,$TSUM,\"$st\",\"$m\"" >> "$OUT/reclaim-retry.csv"
}

# 경쟁 지속과 재시도 상한의 관계가 결과를 정한다. 두 번 헤맸다.
#   경쟁 12회 + 상한 5   재시도 창(최대 8초)이 경쟁(12초 이상)보다 짧아 상한에 닿는다
#   경쟁 2회 + 상한 5    경쟁이 먼저 끝나 데드락이 0 이다. 재시도가 한 일이 없다
# 둘 다 "데드락을 겪고도 끝난다"를 못 보인다. 상한을 경쟁보다 길게 잡아야 한다.
run_case "A 경쟁 없음" 5 0
run_case "B 경쟁 오래, 상한 20" 20 12
run_case "C 경쟁 오래, 상한 1" 1 12

# 마지막으로 상태를 되돌린다.
reset_state || true

echo
R=$(python3 - "$OUT/reclaim-retry.csv" <<'PYX'
import csv, sys
rows = {r['case']: r for r in csv.DictReader(open(sys.argv[1]))}
def g(k, f): return rows[k][f]
print("|".join([
    g('B 경쟁 오래, 상한 20','deadlocks'), g('B 경쟁 오래, 상한 20','completed'),
    g('B 경쟁 오래, 상한 20','reclaimed'), g('B 경쟁 오래, 상한 20','expected'),
    g('C 경쟁 오래, 상한 1','completed'), g('C 경쟁 오래, 상한 1','status'),
    g('C 경쟁 오래, 상한 1','msg'),
]))
PYX
)
IFS='|' read -r B_DL B_DONE B_GOT B_EXP C_DONE C_ST C_MSG <<<"$R"

echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  A04 실험 11 에서 확인한 재시도를 **이 프로시저에 실제로 넣었습니다.**"
echo "  다른 데서 검증한 것을 옮기지 않으면 검증 안 한 것과 같습니다."
echo
printf "  %-30s %s\n" "경쟁 중 데드락" "${B_DL}건"
printf "  %-30s %s\n" "회수 완료 여부" "$B_DONE"
printf "  %-30s %s\n" "회수액 / 기대" "${B_GOT} / ${B_EXP}"
echo
if [ "$B_GOT" = "$B_EXP" ] && [ "$B_DONE" = "완료" ]; then
  echo "  **경쟁이 있어도 끝까지 돌고 회수액이 정확합니다.** 데드락으로 죽은 배치는"
  echo "  통째로 되돌아가고 진행 지점도 함께 되돌아가므로, 재시도가 그 배치부터"
  echo "  다시 하면 중복도 누락도 안 납니다."
  echo
  echo "  **회수액을 잔액 차이로 재면 안 됩니다.** 경쟁 세션이 같은 계정의 잔액을"
  echo "  건드리기 때문입니다. 감사 로그의 적용액과 빚을 더해야 회수한 몫만 나옵니다."
  echo "  A25 실험 3에서 이미 만난 자리이고 여기서도 같습니다."
fi
echo
printf "  %-30s %s\n" "경쟁이 오래가고 상한이 1이면" "$C_DONE"
printf "  %-30s %s\n" "배치 상태" "$C_ST"
echo
if [ "$C_ST" = "DEADLOCK" ]; then
  echo "  **상한에 닿으면 멈추고 배치를 DEADLOCK 으로 남깁니다.** A04 실험 11 에서는"
  echo "  상한 5회에 최대 2회로 끝나 이 길을 못 밟았는데, 상한을 1 로 낮춰 밟았습니다."
  echo
  echo "  이것이 중요한 이유는 **조용히 넘어가지 않기 때문**입니다. 재시도가 실패한"
  echo "  배치를 그냥 건너뛰면 검산에서만 어긋나고, 그때는 어느 배치가 빠졌는지"
  echo "  모릅니다. 배치 상태에 남겨 두면 그 지점부터 다시 돌 수 있습니다."
elif [ "$C_DONE" = "완료" ]; then
  echo "  상한 1 로도 끝났습니다. 이 회차에서는 데드락이 안 났거나 한 번에 성공한"
  echo "  것이고, **상한 도달 경로를 못 밟았습니다.**"
fi
echo
echo "  운영으로 옮기면 이렇게 됩니다."
echo "    프로시저 안에서 SET DEADLOCK_PRIORITY LOW 를 잡는다"
echo "    재시도는 배치 트랜잭션 **밖**에 둔다"
echo "    1205 만 재시도한다"
echo "    상한에 닿으면 배치 상태에 남기고 던진다. 건너뛰지 않는다"
} 2>&1 | tee "$OUT/exp12-reclaim-retry.txt"
