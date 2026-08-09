#!/usr/bin/env bash
# 실험 6. 회수에 승인을 붙인다.
#
# 지금까지의 usp_ReclaimCurrency 는 실행하면 바로 돈다. 회수는 이용자 자산을 줄이는
# 작업인데 한 사람이 마음먹으면 그대로 나간다. 삼성증권 사건에서 착오 입고가 제약
# 없이 커밋된 것과 같은 자리다(F02).
#
# 승인 대기를 붙이고 넷을 확인한다.
#   A 정상          요청 → 다른 사람이 승인 → 실행
#   B 미승인 실행   승인 없이 바로 돌리면
#   C 자기 승인     요청자가 자기 요청을 승인하면
#   D 목록 바꿔치기 승인은 받아 두고 그 뒤에 대상을 바꾸면
#
# D 가 이 실험의 요점이다. 승인만 붙이면 거기가 뚫린다. 승인은 "이 목록을 회수해도
# 된다"는 뜻인데 목록이 바뀌면 그 승인은 다른 것에 대한 승인이 된다.
#
# 권한도 나눈다. 요청자는 승인 프로시저를, 승인자는 요청 프로시저를 실행할 수 없다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

wait_ready || exit 2

# 두 역할로 접속한다. 같은 sa 로 흉내 내면 권한 분리를 확인할 수 없다.
AS(){ # $1=로그인 $2=SQL
  docker exec "$CT" "$SQLCMD" -S localhost -U "$1" -P 'Role_Passw0rd!' -C -h -1 -W -d "$DB" -Q "$2" 2>&1
}
errno(){ echo "$1" | grep -oE '^(Msg|메시지) [0-9]+' | grep -oE '[0-9]+' | head -1; }

{
echo "# 실험 6. 회수에 승인을 붙인다"
echo

QFX "$(cat "$ROOT/scripts/reclaim.sql")" || exit 2
QD "DROP TABLE IF EXISTS correction_request;" >/dev/null
QFX "$(cat "$ROOT/scripts/approval.sql")" || exit 2
echo "  usp_RequestReclaim / usp_ApproveReclaim / usp_ReclaimCurrencyGated 설치 완료"

# 역할 둘. 각자 자기 프로시저만 실행할 수 있다.
QD "IF SUSER_ID('maker')   IS NULL CREATE LOGIN maker   WITH PASSWORD='Role_Passw0rd!', CHECK_POLICY=OFF;
    IF SUSER_ID('checker') IS NULL CREATE LOGIN checker WITH PASSWORD='Role_Passw0rd!', CHECK_POLICY=OFF;" >/dev/null
QDX "IF USER_ID('maker')   IS NULL CREATE USER maker   FOR LOGIN maker;
     IF USER_ID('checker') IS NULL CREATE USER checker FOR LOGIN checker;
     GRANT EXECUTE ON usp_RequestReclaim        TO maker;
     GRANT EXECUTE ON usp_ReclaimCurrencyGated  TO maker;
     GRANT EXECUTE ON usp_ApproveReclaim        TO checker;
     DENY  EXECUTE ON usp_ApproveReclaim        TO maker;
     DENY  EXECUTE ON usp_RequestReclaim        TO checker;
     DENY  EXECUTE ON usp_ReclaimCurrency       TO maker, checker;" || exit 2
# 권한으로 막는 것과 로직으로 막는 것은 다르다. 역할 분리가 안 된 조직에서도
# 자기 승인은 막혀야 하므로, 둘 다 할 수 있는 로그인을 따로 둬 로직만 시험한다.
QD "IF SUSER_ID('operator') IS NULL CREATE LOGIN operator WITH PASSWORD='Role_Passw0rd!', CHECK_POLICY=OFF;" >/dev/null
QDX "IF USER_ID('operator') IS NULL CREATE USER operator FOR LOGIN operator;
     GRANT EXECUTE ON usp_RequestReclaim TO operator;
     GRANT EXECUTE ON usp_ApproveReclaim TO operator;" || exit 2
echo "  로그인 maker / checker 생성, 각자 자기 프로시저만 실행 가능"
echo "  로그인 operator 생성. 둘 다 할 수 있어 자기 승인 로직만 따로 시험합니다"
echo

# 실험 5의 마지막 조건이 운영 DB 에 없는 계정을 남겨 둔다. 그대로 두면 검산이
# 그것 때문에 터져서 이 실험의 판정이 섞인다. 조건 간 상태 누수를 먼저 끊는다.
GHOST=$(num "$(QD "SELECT COUNT(*) FROM reclaim_target r
                    WHERE NOT EXISTS (SELECT 1 FROM account_currency a WHERE a.account_id = r.account_id)")")
if [ "${GHOST:-0}" -gt 0 ]; then
  QDX "DELETE FROM reclaim_target
        WHERE NOT EXISTS (SELECT 1 FROM account_currency a WHERE a.account_id = reclaim_target.account_id);" || exit 2
  echo "  앞 실험이 남긴 운영 DB 밖 계정 ${GHOST}개를 걷어냈습니다"
fi
echo

reset_ops(){
  QDX "SET NOCOUNT ON;
  DELETE FROM correction_detail;
  DELETE FROM correction_batch;
  DELETE FROM correction_request;
  DBCC CHECKIDENT('correction_batch', RESEED, 0) WITH NO_INFOMSGS;
  DBCC CHECKIDENT('correction_request', RESEED, 0) WITH NO_INFOMSGS;
  UPDATE account_currency SET balance = 50000 + (account_id % 37) * 1000, debt = 0;"
}

: > "$OUT/approval.csv"
echo "case,result,errno,reclaimed" >> "$OUT/approval.csv"
printf "  %-24s %-38s %s\n" "조건" "결과" "회수액"

report(){ # $1=라벨 $2=출력 $3=성공 시 기대
  local e; e=$(errno "$2")
  local got; got=$(num "$(QD "SELECT ISNULL(SUM(applied_amount + debt_amount),0) FROM correction_detail")")
  local desc
  case "${e:-}" in
    "")      desc="통과" ;;
    50022)   desc="**거부 — 자기 요청은 자기가 승인 못 함**" ;;
    50025)   desc="**거부 — 승인되지 않은 요청**" ;;
    50026)   desc="**거부 — 승인 뒤 대상이 바뀜**" ;;
    229)     desc="**거부 — 권한 없음**" ;;
    *)       desc="거부 (Msg ${e})" ;;
  esac
  printf "  %-24s %-38s %s\n" "$1" "$desc" "$got"
  echo "\"$1\",\"$desc\",${e:-0},$got" >> "$OUT/approval.csv"
}

echo "## 6-1. 네 조건"
echo
# A 정상
reset_ops || exit 2
RID=$(num "$(AS maker "SET NOCOUNT ON; DECLARE @r INT; EXEC usp_RequestReclaim @reason=N'A24 탐지분 회수', @request_id=@r OUTPUT;")")
AS checker "EXEC usp_ApproveReclaim @request_id = $RID" >/dev/null
OUTA=$(AS maker "EXEC usp_ReclaimCurrencyGated @request_id = $RID, @mode='DEBT', @chunk=$CHUNK")
report "A 요청→승인→실행" "$OUTA"

# B 미승인 실행
reset_ops || exit 2
RID=$(num "$(AS maker "SET NOCOUNT ON; DECLARE @r INT; EXEC usp_RequestReclaim @reason=N'승인 없이', @request_id=@r OUTPUT;")")
OUTB=$(AS maker "EXEC usp_ReclaimCurrencyGated @request_id = $RID, @mode='DEBT', @chunk=$CHUNK")
report "B 승인 없이 실행" "$OUTB"

# C 자기 승인. 권한이 아니라 로직이 막는지 보려고 둘 다 되는 로그인으로 던진다.
reset_ops || exit 2
RID=$(num "$(AS operator "SET NOCOUNT ON; DECLARE @r INT; EXEC usp_RequestReclaim @reason=N'자기 승인', @request_id=@r OUTPUT;")")
OUTC=$(AS operator "EXEC usp_ApproveReclaim @request_id = $RID")
report "C 요청자가 자기 승인" "$OUTC"

# D 승인 뒤 목록 바꿔치기
reset_ops || exit 2
RID=$(num "$(AS maker "SET NOCOUNT ON; DECLARE @r INT; EXEC usp_RequestReclaim @reason=N'승인 후 변경', @request_id=@r OUTPUT;")")
AS checker "EXEC usp_ApproveReclaim @request_id = $RID" >/dev/null
QDX "INSERT INTO reclaim_target (account_id, extra_rows, extra_amount) VALUES (777777, 1, 999999);" || exit 2
OUTD=$(AS maker "EXEC usp_ReclaimCurrencyGated @request_id = $RID, @mode='DEBT', @chunk=$CHUNK")
report "D 승인 뒤 대상 추가" "$OUTD"
QD "DELETE FROM reclaim_target WHERE account_id = 777777;" >/dev/null

echo
echo "## 6-2. 권한 분리"
echo
E1=$(errno "$(AS maker   "EXEC usp_ApproveReclaim @request_id = 1")")
E2=$(errno "$(AS checker "SET NOCOUNT ON; DECLARE @r INT; EXEC usp_RequestReclaim @reason=N'x', @request_id=@r OUTPUT;")")
E3=$(errno "$(AS maker   "SET NOCOUNT ON; DECLARE @b INT; EXEC usp_ReclaimCurrency @reason=N'우회', @mode='DEBT', @chunk=$CHUNK, @batch_id=@b OUTPUT;")")
printf "  %-40s %s\n" "maker 가 승인 시도" "$([ "${E1:-}" = 229 ] && echo '**거부 — 권한 없음**' || echo "Msg ${E1:-없음}")"
printf "  %-40s %s\n" "checker 가 요청 시도" "$([ "${E2:-}" = 229 ] && echo '**거부 — 권한 없음**' || echo "Msg ${E2:-없음}")"
printf "  %-40s %s\n" "maker 가 게이트를 건너뛰고 직접 실행" "$([ "${E3:-}" = 229 ] && echo '**거부 — 권한 없음**' || echo "Msg ${E3:-없음}")"
{ echo "\"maker 가 승인 시도\",\"\",${E1:-0},"
  echo "\"checker 가 요청 시도\",\"\",${E2:-0},"
  echo "\"maker 가 직접 실행\",\"\",${E3:-0},"; } >> "$OUT/approval.csv"

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  승인 대기를 붙이자 셋이 막힙니다. 승인 없는 실행, 자기 승인, 그리고 게이트를"
echo "  건너뛰고 원래 프로시저를 직접 부르는 것까지."
echo
echo "  **막는 층이 둘로 나뉩니다.** 권한이 막는 것과 로직이 막는 것은 다릅니다."
echo "  maker 가 승인을 시도하는 것은 권한이 막고(Msg 229), 둘 다 할 수 있는 계정이"
echo "  자기 요청을 승인하는 것은 로직이 막습니다(Msg 50022). 역할 분리가 된 조직이면"
echo "  권한만으로 충분해 보이지만, 한 사람이 둘 다 맡는 조직에서는 로직만 남습니다."
echo "  둘 다 있어야 합니다. 그리고 원래 프로시저에 DENY EXECUTE 를 안 걸면 게이트는"
echo "  우회하면 그만입니다."
echo
echo "  **D 가 이 실험의 요점입니다.** 승인만 붙이면 거기가 뚫립니다. 승인을 받아 둔 뒤"
echo "  회수 대상 표에 행을 하나 더 넣으면, 승인은 그대로 유효한 채로 다른 목록이"
echo "  실행됩니다. 승인은 \"이 목록을 회수해도 된다\"는 뜻이지 \"언제든 회수해도 된다\"는"
echo "  뜻이 아닙니다."
echo
echo "  그래서 승인 시점의 대상 지문(건수·합계·체크섬)을 저장해 두고 실행할 때 다시"
echo "  대조합니다. 실험 5에서 이관 검증에 쓴 것과 같은 지문입니다. 한 번은 서버를"
echo "  건너올 때, 한 번은 시간을 건너올 때 씁니다."
} 2>&1 | tee "$OUT/exp6-approval.txt"
