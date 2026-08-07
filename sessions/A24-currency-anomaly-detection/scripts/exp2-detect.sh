#!/usr/bin/env bash
# 실험 2. 이상 지급을 찾는 세 가지 방법과 그 정확도.
#
# 사고가 나면 먼저 정해야 하는 것이 "전면 롤백이냐 선별 회수냐" 다. 그 선택은
# 취향이 아니라 **셀 수 있느냐**로 갈린다. 누가 얼마나 부당 취득했는지 못 세면
# 롤백 말고 선택지가 없다. 로스트아크가 2022년에 선별 회수를 택하고 2023년에
# "63계정 3,806회분"이라고 숫자를 붙여 공지할 수 있었던 것은 셀 수 있었기 때문이다.
#
# 세 가지 방법을 정답지와 대조한다. 조사 쿼리는 truth_accounts 를 보지 않는다.
#
#   A 참조 대사   같은 ref_id 에 지급이 여러 건 붙은 것을 찾는다
#   B 통계 이탈   계정별 창 안 획득량이 정상 분포에서 벗어난 것을 찾는다
#   C 개봉 대사   개봉 로그와 원장의 건수를 조인해 맞춰 본다
#
# 재는 것은 적발률과 거짓 양성이다. 거짓 음성은 회수 누락이고 거짓 양성은 오회수다.
# 둘 다 사고이지만 성격이 다르다. 오회수는 정상 이용자의 재화를 빼앗는 것이라
# 더 무겁다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

wait_ready || exit 2
WIN_START=$(grep '^window_start,' "$OUT/dataset.csv" | cut -d, -f2-)
WIN_END=$(grep '^window_end,'   "$OUT/dataset.csv" | cut -d, -f2-)
[ -n "$WIN_START" ] || { echo "중단: dataset.csv 가 없습니다. 실험 1을 먼저 돌립니다" >&2; exit 2; }

TRUTH=$(num "$(QD "SELECT COUNT(*) FROM truth_accounts")")
[ "${TRUTH:-0}" -gt 0 ] || { echo "중단: 정답지가 비었습니다" >&2; exit 2; }

# 탐지 결과를 임시 표에 담고 정답지와 대조한다.
score(){   # $1=라벨  $2=탐지 결과를 #found (account_id) 로 채우는 SQL
  local label=$1 sql=$2
  local r
  r=$(QD "SET NOCOUNT ON;
  DROP TABLE IF EXISTS #found;
  CREATE TABLE #found (account_id INT PRIMARY KEY);
  $sql
  SELECT CAST((SELECT COUNT(*) FROM #found f JOIN truth_accounts t ON t.account_id = f.account_id) AS varchar(12))
       + ',' + CAST((SELECT COUNT(*) FROM #found) AS varchar(12))
       + ',' + CAST((SELECT COUNT(*) FROM truth_accounts t
                      WHERE NOT EXISTS (SELECT 1 FROM #found f WHERE f.account_id = t.account_id)) AS varchar(12));")
  if echo "$r" | grep -qE '^(Msg|메시지) [0-9]+'; then
    printf "  %-14s %s\n" "$label" "**질의 실패**"
    echo "$r" | grep -E '^(Msg|메시지)' | head -2
    echo "$label,ERROR,,," >> "$OUT/detection.csv"
    return
  fi
  IFS=, read -r hit found miss <<<"$(num "$r")"
  local fp=$(( found - hit ))
  local rate="0"
  [ "$TRUTH" -gt 0 ] && rate=$(python3 -c "print(f'{100*$hit/$TRUTH:.1f}')")
  printf "  %-14s %-10s %-12s %-12s %s\n" "$label" "${found}개" "${hit}/${TRUTH}" "${miss}개" "${fp}개"
  echo "$label,$found,$hit,$miss,$fp,$rate" >> "$OUT/detection.csv"
}

{
echo "# 실험 2. 이상 지급을 찾는 세 방법과 정확도"
echo
echo "  정답: 이상 계정 ${TRUTH}개. 조사 쿼리는 정답지를 보지 않습니다."
echo "  사고 창: ${WIN_START} ~ ${WIN_END}"
echo
: > "$OUT/detection.csv"
echo "method,found,hit,miss,false_positive,recall_pct" >> "$OUT/detection.csv"
printf "  %-14s %-10s %-12s %-12s %s\n" "방법" "지목" "적발" "놓침" "오탐"

# A. 참조 대사. 같은 개봉에 지급이 두 번 이상 붙은 것.
score "A 참조 대사" "
INSERT INTO #found (account_id)
SELECT DISTINCT account_id
  FROM currency_ledger
 WHERE reason = 1
   AND created_at >= '$WIN_START' AND created_at < '$WIN_END'
   AND ref_id IN (SELECT ref_id
                    FROM currency_ledger
                   WHERE reason = 1
                     AND created_at >= '$WIN_START' AND created_at < '$WIN_END'
                   GROUP BY ref_id HAVING COUNT(*) > 1);"

# B. 통계 이탈. 창 안 획득량이 같은 창의 평균에서 크게 벗어난 계정.
#    ref_id 가 없는 사고에도 통하는 대신 정상 상위 이용자를 함께 집는다.
score "B 통계 이탈" "
DECLARE @avg FLOAT, @sd FLOAT;
SELECT @avg = AVG(CAST(s AS FLOAT)), @sd = STDEV(CAST(s AS FLOAT))
  FROM (SELECT account_id, SUM(delta) AS s
          FROM currency_ledger
         WHERE reason = 1 AND created_at >= '$WIN_START' AND created_at < '$WIN_END'
         GROUP BY account_id) q;
INSERT INTO #found (account_id)
SELECT account_id
  FROM (SELECT account_id, SUM(delta) AS s
          FROM currency_ledger
         WHERE reason = 1 AND created_at >= '$WIN_START' AND created_at < '$WIN_END'
         GROUP BY account_id) q
 WHERE CAST(s AS FLOAT) > @avg + 3 * ISNULL(@sd, 0);"

# C. 개봉 대사. 개봉 1건에 지급 1건이라는 불변식을 조인으로 확인한다.
score "C 개봉 대사" "
INSERT INTO #found (account_id)
SELECT DISTINCT b.account_id
  FROM box_open_log b
  JOIN (SELECT ref_id, COUNT(*) AS c
          FROM currency_ledger
         WHERE reason = 1
           AND created_at >= '$WIN_START' AND created_at < '$WIN_END'
         GROUP BY ref_id) l ON l.ref_id = b.open_id
 WHERE b.opened_at >= '$WIN_START' AND b.opened_at < '$WIN_END'
   AND l.c <> 1;"

echo
echo "## 2-2. 회수 대상 산정"
echo
echo "  적발이 전부인 방법으로 회수량까지 뽑습니다. 계정만 알아서는 회수를 못 하고"
echo "  **얼마를 되돌릴지**가 나와야 합니다. 첫 지급은 정상이므로 두 번째부터가 대상입니다."
echo
QD "SET NOCOUNT ON;
DROP TABLE IF EXISTS reclaim_target;
SELECT account_id,
       COUNT(*)   AS extra_rows,
       SUM(delta) AS extra_amount
  INTO reclaim_target
  FROM (SELECT account_id, delta,
               ROW_NUMBER() OVER (PARTITION BY ref_id ORDER BY ledger_id) AS rn
          FROM currency_ledger
         WHERE reason = 1
           AND created_at >= '$WIN_START' AND created_at < '$WIN_END') q
 WHERE rn > 1
 GROUP BY account_id;" >/dev/null

CMP=$(num "$(QD "SELECT CAST(COUNT(*) AS varchar(12))
     + ',' + CAST(SUM(CASE WHEN r.extra_rows = t.extra_rows AND r.extra_amount = t.extra_amount
                           THEN 1 ELSE 0 END) AS varchar(12))
     + ',' + CAST(ISNULL(SUM(r.extra_amount), 0) AS varchar(20))
     + ',' + CAST((SELECT ISNULL(SUM(extra_amount),0) FROM truth_accounts) AS varchar(20))
  FROM reclaim_target r
  FULL JOIN truth_accounts t ON t.account_id = r.account_id;")")
IFS=, read -r n_rows n_match amt_found amt_truth <<<"$CMP"
printf "  %-24s %s\n" "산정한 계정" "${n_rows}개"
printf "  %-24s %s\n" "정답과 건수·금액 일치" "${n_match}개"
printf "  %-24s %s\n" "산정 회수액" "${amt_found}"
printf "  %-24s %s\n" "정답 회수액" "${amt_truth}"
echo
if [ "$amt_found" = "$amt_truth" ] && [ "$n_match" = "$TRUTH" ]; then
  echo "  **회수 대상이 계정 단위로 정확합니다.** 이 표가 보정 절차의 입력이 됩니다."
else
  echo "  **산정이 정답과 어긋납니다. 이 표를 보정에 쓰면 안 됩니다.**"
fi
echo "reclaim_accounts,$n_rows,$n_match,$amt_found,$amt_truth" >> "$OUT/detection.csv"

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  A 와 C 는 같은 불변식을 다른 각도에서 봅니다. 개봉 1건에 지급 1건이라는"
echo "  규칙을 A 는 원장 안에서, C 는 개봉 로그와 조인해서 확인합니다."
echo
echo "  B 는 참조가 없어도 통하는 대신 정상 상위 이용자를 함께 집습니다."
echo "  오탐은 오회수이고, 오회수는 정상 이용자의 재화를 빼앗는 것이라 더 무겁습니다."
echo "  통계 이탈은 **조사 대상을 좁히는 데 쓰고 회수 근거로는 쓰지 않는 것**이 맞습니다."
echo
echo "  회수 대상 표는 계정과 금액을 함께 냅니다. 계정만으로는 보정을 못 합니다."
} 2>&1 | tee "$OUT/exp2-detect.txt"
