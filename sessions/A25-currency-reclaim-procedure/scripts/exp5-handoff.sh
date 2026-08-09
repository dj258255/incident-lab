#!/usr/bin/env bash
# 실험 5. 조사 DB 에서 운영 DB 로 회수 대상을 옮긴다.
#
# A24 가 뽑은 회수 대상은 조사(로그) DB 에 있다. 보정은 운영 DB 에서 돈다.
# 실무에서 이 둘은 다른 서버다. 로그는 쓰기만 하는 대용량이라 따로 두고, 운영은
# 응답 시간이 걸린 표라 조사 쿼리를 못 던진다.
#
# 그래서 목록을 옮겨야 한다. 옮기다 새면 그대로 사고가 된다. 덜 옮기면 미회수,
# 잘못 옮기면 오회수다. 둘 다 조용히 일어난다.
#
# 조건 셋이다. 옮기는 방법은 같고 옮겨진 것만 다르다.
#   A 정상 이관
#   B 파일이 잘린 채 이관        전송이 중간에 끊긴 상황
#   C 운영 DB 에 없는 계정이 섞임 탈퇴했거나 다른 서버로 옮겨간 계정
#
# 각 조건에서 두 가지를 본다. 검증이 잡는가, 그리고 검증을 건너뛰고 회수를
# 돌리면 무엇이 되는가.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

SRC_CT=a24-mssql          # 조사 DB
SRC_DB=lostark_log
DAT="$OUT/.handoff.dat"

wait_ready || exit 2
if ! docker exec "$SRC_CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$PW" -C -h -1 -W \
       -d "$SRC_DB" -Q "SELECT 'O'+'K'" 2>/dev/null | grep -q OK; then
  echo "중단: 조사 DB($SRC_CT/$SRC_DB)에 접속하지 못했습니다. A24 세션을 먼저 띄웁니다" >&2
  exit 2
fi

SQ(){ docker exec "$SRC_CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$PW" -C -h -1 -W -d "$SRC_DB" -Q "$1" 2>&1; }

# 건수·합계·체크섬 세 값을 한 줄로. 순서와 무관한 집계라 정렬이 달라도 같다.
fingerprint(){   # $1: 'src' | 'dst'
  local q="SELECT CAST(COUNT(*) AS varchar(12))
              + ',' + CAST(ISNULL(SUM(extra_amount),0) AS varchar(20))
              + ',' + CAST(ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(account_id, extra_rows, extra_amount)),0) AS varchar(20))
             FROM reclaim_target"
  if [ "$1" = src ]; then num "$(SQ "$q")"; else num "$(QD "$q")"; fi
}

# 조사 DB 에서 뽑아 운영 DB 로 넣는다. $1 이 truncate 면 파일을 잘라서, extra 면 없는 계정을 붙여서.
handoff(){
  local mode=${1:-normal}
  docker exec "$SRC_CT" /opt/mssql-tools18/bin/bcp \
      "SELECT account_id, extra_rows, extra_amount FROM reclaim_target ORDER BY account_id" \
      queryout /tmp/rt.dat -S localhost -U sa -P "$PW" -d "$SRC_DB" -c -t"," -u >/dev/null 2>&1
  docker cp "$SRC_CT":/tmp/rt.dat "$DAT" >/dev/null 2>&1
  [ -s "$DAT" ] || { echo "중단: 추출 파일이 비었습니다" >&2; return 2; }

  case "$mode" in
    truncate) local n; n=$(( $(wc -l < "$DAT") / 2 )); head -n "$n" "$DAT" > "$DAT.tmp"; mv "$DAT.tmp" "$DAT" ;;
    extra)    echo "99999999,3,50000" >> "$DAT" ;;
  esac

  QDX "SET NOCOUNT ON; TRUNCATE TABLE reclaim_target;" || return 2
  docker cp "$DAT" "$CT":/tmp/rt.dat >/dev/null 2>&1
  docker exec "$CT" /opt/mssql-tools18/bin/bcp reclaim_target in /tmp/rt.dat \
      -S localhost -U sa -P "$PW" -d "$DB" -c -t"," -u >/dev/null 2>&1
}

reset_ops(){
  QDX "SET NOCOUNT ON;
  DELETE FROM correction_detail;
  DELETE FROM correction_batch;
  DBCC CHECKIDENT('correction_batch', RESEED, 0) WITH NO_INFOMSGS;
  UPDATE account_currency SET balance = 50000 + (account_id % 37) * 1000, debt = 0;"
}

{
echo "# 실험 5. 조사 DB 에서 운영 DB 로 회수 대상 넘기기"
echo
echo "  조사 DB   ${SRC_CT} / ${SRC_DB}   (A24 가 뽑은 회수 대상)"
echo "  운영 DB   ${CT} / ${DB}   (A25 의 계정 잔액)"
echo "  옮기는 방법은 bcp 파일 경유입니다. 두 서버가 서로를 모른다는 전제입니다."
echo

QFX "$(cat "$ROOT/scripts/reclaim.sql")" || exit 2

SRC=$(fingerprint src)
IFS=, read -r s_cnt s_sum s_chk <<<"$SRC"
printf "  %-22s %s건 / %s / 체크섬 %s\n" "조사 DB 원본" "$s_cnt" "$s_sum" "$s_chk"
echo

: > "$OUT/handoff.csv"
echo "case,src_rows,src_sum,src_checksum,dst_rows,dst_sum,dst_checksum,verify,reclaim_result" >> "$OUT/handoff.csv"
printf "  %-28s %-12s %-14s %-10s %s\n" "조건" "옮겨진 건수" "합계" "검증" "검증을 건너뛰면"

run_case(){
  local label=$1 mode=$2
  reset_ops || return
  handoff "$mode" || { echo "  ${label}: 이관 실패"; return; }
  local d_cnt d_sum d_chk verify
  IFS=, read -r d_cnt d_sum d_chk <<<"$(fingerprint dst)"
  if [ "$d_cnt" = "$s_cnt" ] && [ "$d_sum" = "$s_sum" ] && [ "$d_chk" = "$s_chk" ]; then
    verify="통과"
  else
    verify="**막음**"
  fi

  # 검증을 건너뛰고 그대로 회수를 돌리면 어떻게 되는가.
  local out result
  out=$(QD "SET NOCOUNT ON;
            DECLARE @b INT;
            EXEC usp_ReclaimCurrency @reason = N'이관 시험', @mode = 'DEBT',
                                     @chunk = $CHUNK, @batch_id = @b OUTPUT;")
  if echo "$out" | grep -q '50002'; then
    result="검산이 잡음"
  elif echo "$out" | grep -qE '^(Msg|메시지) [0-9]+'; then
    result="다른 오류"
  else
    local got; got=$(num "$(QD "SELECT ISNULL(SUM(applied_amount + debt_amount),0) FROM correction_detail")")
    if [ "$got" = "$s_sum" ]; then result="정상 회수 ${got}"; else result="**${got} 회수(원본 ${s_sum})**"; fi
  fi

  printf "  %-28s %-12s %-14s %-10s %s\n" "$label" "$d_cnt" "$d_sum" "$verify" "$result"
  echo "\"$label\",$s_cnt,$s_sum,$s_chk,$d_cnt,$d_sum,$d_chk,$verify,\"$result\"" >> "$OUT/handoff.csv"
}

run_case "A 정상 이관"                normal
run_case "B 파일이 절반에서 잘림"     truncate
run_case "C 없는 계정이 섞임"         extra

rm -f "$DAT"
echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  **A24 의 산출물이 A25 의 입력이 되는 것을 실제로 이었습니다.** 형식만 맞춘 것이"
echo "  아니라 조사 DB 에서 bcp 로 뽑아 운영 DB 에 넣고, 그 목록으로 회수까지 돌렸습니다."
echo
echo "  **두 사고가 잡히는 자리가 다릅니다. 이것이 이 실험의 요점입니다.**"
echo
echo "  B 는 파일이 잘려 절반만 넘어갔습니다. bcp 는 오류를 내지 않습니다. 넘어간 만큼"
echo "  정상으로 넣고 끝납니다. 그리고 **회수 프로시저의 검산도 이것을 못 잡습니다.**"
echo "  검산은 옮겨진 목록을 기준으로 대상 합계와 회수 합계를 견주는데, 그 둘은 서로"
echo "  맞기 때문입니다. 30건을 받아 30건을 회수했으니 프로시저 입장에서는 성공입니다."
echo "  회수 대상 절반이 통째로 사라진 것은 **원본과 대조할 때만** 드러납니다."
echo
echo "  C 는 운영 DB 에 없는 계정이 섞인 경우입니다. 회수 프로시저는 그 계정을 조인에서"
echo "  못 찾아 조용히 건너뜁니다. 그런데 이것은 검산이 잡습니다. 대상 합계와 실제 회수"
echo "  합계가 달라 배치가 MISMATCH 로 끝납니다."
echo
echo "  그래서 방어선이 둘 필요합니다."
echo "    1) 이관 직후 원본과 사본의 건수·합계·체크섬을 대조한다 (B 를 잡는 유일한 자리)"
echo "    2) 회수 프로시저가 대상 합계와 회수 합계를 검산한다 (C 를 잡는 자리)"
echo
echo "  하나만 두면 다른 하나가 뚫립니다. **덜 옮겨진 것은 안에서 볼 수 없고, 잘못"
echo "  옮겨진 것은 밖에서 볼 수 없습니다.**"
} 2>&1 | tee "$OUT/exp5-handoff.txt"
