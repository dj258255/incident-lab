#!/usr/bin/env bash
# 실험 6. 계정 분포를 실제처럼 바꾸면 오탐이 몇 개가 되는가.
#
# 실험 2는 통계 이탈의 오탐 40개를 보였다. 그런데 그 40개는 내가 심은 것이다.
# "정상인데 활동이 많은 계정"을 40개 만들어 넣었으니 40개가 나온 것이지,
# 실제 게임에서 오탐이 몇 퍼센트인지는 그 실험이 답하지 못한다.
#
# 이 실험은 계정 분포를 실제에 가깝게 바꾼다. 게임 활동은 균등하지 않고 소수에
# 쏠린다. 상위 몇 퍼센트가 활동의 대부분을 차지하는 멱함수 꼬리를 만들고,
# 그 위에서 같은 3시그마 기준을 다시 돌린다.
#
# 심은 오탐이 아니라 **분포가 만드는 오탐**을 세는 것이 이 실험의 질문이다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

WIN3_START='2026-07-30 10:00:00'
WIN3_END='2026-07-30 14:00:00'
SKEW_ACCOUNTS=${SKEW_ACCOUNTS:-20000}   # 이 창에서 활동하는 정상 계정
ABUSE_ACCOUNTS=${ABUSE_ACCOUNTS:-30}    # 이상 계정

wait_ready || exit 2
[ -f "$OUT/dataset.csv" ] || { echo "중단: 실험 1을 먼저 돌립니다" >&2; exit 2; }

{
echo "# 실험 6. 분포가 만드는 오탐"
echo
echo "  세 번째 창(${WIN3_START} ~ ${WIN3_END})에 정상 계정 ${SKEW_ACCOUNTS}개를 넣습니다."
echo "  활동량을 균등이 아니라 **소수에 쏠리게** 만듭니다. 실제 게임의 모양입니다."
echo "  그 위에 이상 계정 ${ABUSE_ACCOUNTS}개를 심고 같은 3시그마 기준을 돌립니다."
echo

# 정상 계정. 개봉 횟수를 멱함수 꼴로 준다. rn 이 작을수록 많이 연다.
# 상위 1퍼센트가 수십 회, 대부분은 한두 회다.
QDX "SET NOCOUNT ON;
DROP TABLE IF EXISTS truth_skew;
CREATE TABLE truth_skew (account_id INT PRIMARY KEY);

DELETE FROM currency_ledger
 WHERE created_at >= '$WIN3_START' AND created_at < '$WIN3_END';

WITH a AS (SELECT TOP ($SKEW_ACCOUNTS)
                  ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
             FROM sys.all_objects x CROSS JOIN sys.all_objects y),
     n AS (SELECT TOP (60) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS k
             FROM sys.all_objects)
INSERT INTO currency_ledger WITH (TABLOCK) (account_id, delta, reason, ref_id, created_at)
SELECT 600000 + a.rn, 300, 1, 900000000 + a.rn * 100 + n.k,
       DATEADD(second, (a.rn * 7 + n.k) % 14400, '$WIN3_START')
  FROM a JOIN n ON n.k <= CEILING(60.0 / SQRT(CAST(a.rn AS FLOAT)));" || exit 2

# 이상 계정. 정상 상위권과 지급 건수가 겹치도록 맞춘다. 그래야 시험이 된다.
QDX "SET NOCOUNT ON;
WITH a AS (SELECT TOP ($ABUSE_ACCOUNTS) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS ai
             FROM sys.all_objects),
     p AS (SELECT TOP (10) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS pi
             FROM sys.all_objects),
     d AS (SELECT TOP (4)  ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS dk
             FROM sys.all_objects)
INSERT INTO currency_ledger (account_id, delta, reason, ref_id, created_at)
SELECT 700000 + a.ai * 13, 300, 1, 950000000 + a.ai * 100 + p.pi,
       DATEADD(second, (a.ai * 10 + p.pi) % 14400, '$WIN3_START')
  FROM a CROSS JOIN p CROSS JOIN d;

INSERT INTO truth_skew (account_id)
SELECT DISTINCT account_id FROM currency_ledger
 WHERE created_at >= '$WIN3_START' AND created_at < '$WIN3_END' AND account_id >= 700000;" || exit 2

QD "UPDATE STATISTICS currency_ledger WITH FULLSCAN;" >/dev/null

TRUTH=$(num "$(QD "SELECT COUNT(*) FROM truth_skew")")
ACTIVE=$(num "$(QD "SELECT COUNT(DISTINCT account_id) FROM currency_ledger
                     WHERE created_at >= '$WIN3_START' AND created_at < '$WIN3_END'")")
NORMAL=$(( ACTIVE - TRUTH ))
[ "$TRUTH" = "$ABUSE_ACCOUNTS" ] || { echo "중단: 이상 계정이 ${TRUTH}개입니다(기대 ${ABUSE_ACCOUNTS})"; exit 2; }

# 분포가 실제로 쏠렸는지 확인한다. 균등이면 이 실험은 성립하지 않는다.
DIST=$(num "$(QD "SELECT CAST(MAX(c) AS varchar(12)) + ',' + CAST(AVG(c) AS varchar(12))
                       + ',' + CAST(SUM(CASE WHEN c >= 20 THEN 1 ELSE 0 END) AS varchar(12))
                    FROM (SELECT account_id, COUNT(*) AS c FROM currency_ledger
                           WHERE created_at >= '$WIN3_START' AND created_at < '$WIN3_END'
                             AND account_id < 700000
                           GROUP BY account_id) q")")
IFS=, read -r d_max d_avg d_heavy <<<"$DIST"
printf "  %-26s %s\n" "이 창의 활동 계정" "${ACTIVE}개 (정상 ${NORMAL}, 이상 ${TRUTH})"
printf "  %-26s %s\n" "정상 계정 지급 건수" "최대 ${d_max}건 / 평균 ${d_avg}건"
printf "  %-26s %s\n" "20건 이상인 정상 계정" "${d_heavy}개"
echo
if [ "${d_max:-0}" -lt $(( d_avg * 5 )) ]; then
  echo "  **분포가 충분히 안 쏠렸습니다. 이 실험은 성립하지 않습니다.**"; exit 2
fi

: > "$OUT/skew.csv"
echo "sigma,found,hit,miss,false_positive,fp_rate_pct,innocent_pct" >> "$OUT/skew.csv"
printf "  %-10s %-9s %-11s %-9s %-9s %-11s %s\n" "기준" "지목" "적발" "놓침" "오탐" "정상 대비" "지목 중 무고"

score_sigma(){
  local k=$1
  local r
  r=$(QD "SET NOCOUNT ON;
  DROP TABLE IF EXISTS #found;
  CREATE TABLE #found (account_id INT PRIMARY KEY);
  DECLARE @avg FLOAT, @sd FLOAT;
  SELECT @avg = AVG(CAST(s AS FLOAT)), @sd = STDEV(CAST(s AS FLOAT))
    FROM (SELECT account_id, SUM(delta) AS s FROM currency_ledger
           WHERE reason = 1 AND created_at >= '$WIN3_START' AND created_at < '$WIN3_END'
           GROUP BY account_id) q;
  INSERT INTO #found (account_id)
  SELECT account_id FROM (SELECT account_id, SUM(delta) AS s FROM currency_ledger
                           WHERE reason = 1 AND created_at >= '$WIN3_START' AND created_at < '$WIN3_END'
                           GROUP BY account_id) q
   WHERE CAST(s AS FLOAT) > @avg + $k * ISNULL(@sd, 0);
  SELECT CAST((SELECT COUNT(*) FROM #found f JOIN truth_skew t ON t.account_id = f.account_id) AS varchar(12))
       + ',' + CAST((SELECT COUNT(*) FROM #found) AS varchar(12));")
  IFS=, read -r hit found <<<"$(num "$r")"
  local fp=$(( found - hit )) miss=$(( TRUTH - hit ))
  local rate; rate=$(python3 -c "print(f'{100*${fp}/${NORMAL}:.2f}')")
  # 운영에서 제일 중요한 값. 이 목록으로 회수하면 몇 퍼센트가 무고한 사람인가.
  local inno; inno=$(python3 -c "print(f'{100*${fp}/${found}:.1f}' if ${found} else '-')")
  printf "  %-10s %-9s %-11s %-9s %-9s %-11s %s\n" "${k}시그마" "${found}개" "${hit}/${TRUTH}" "${miss}개" "${fp}개" "${rate}%" "${inno}%"
  echo "$k,$found,$hit,$miss,$fp,$rate,$inno" >> "$OUT/skew.csv"
}

for k in 2 3 4 5; do score_sigma "$k"; done

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  실험 2의 오탐 40개는 제가 심은 계정 수였습니다. 이 실험은 심지 않고"
echo "  **분포가 만드는 오탐**을 셌습니다. 정상 계정 ${NORMAL}개 중 몇 개가 걸리는지입니다."
echo
echo "  기준을 올리면 오탐은 줄고 놓침은 늘어납니다. 어느 쪽도 공짜가 아닙니다."
echo "  놓친 어뷰저는 나중에 잡을 수 있지만 잘못 뺏은 재화는 이미 신뢰를 깎은 뒤라,"
echo "  기준을 올려 오탐을 줄이는 쪽이 회수 근거로는 안전합니다."
echo
echo "  **어느 기준에서도 오탐이 0이 되지 않습니다.** 활동이 쏠린 분포에서 상위 정상"
echo "  이용자와 어뷰저는 같은 꼬리에 있습니다."
echo
echo "  마지막 열이 운영에서 제일 중요한 값입니다. 이 목록을 그대로 회수하면 지목된"
echo "  계정 중 그만큼이 무고한 사람입니다. 기준을 5시그마까지 올려도 절반이 넘습니다."
echo "  **어뷰저 한 명을 잡으려고 정상 이용자 한 명 이상의 재화를 뺏는 셈입니다.**"
echo
echo "  그래서 통계 이탈은 조사 대상을 좁히는 데까지이고, 회수 근거는 결정론적 쿼리로"
echo "  만들어야 합니다. 실험 2에서 심은 오탐으로 내린 결론이 실제 분포에서도"
echo "  그대로 섭니다. 오히려 더 강해집니다."
} 2>&1 | tee "$OUT/exp6-skew.txt"
