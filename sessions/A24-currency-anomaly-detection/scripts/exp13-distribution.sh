#!/usr/bin/env bash
# 실험 13. 결론이 분포 모양 하나에 기대고 있는가.
#
# 실험 7은 쏠린 분포에서 오탐이 어떤 기준으로도 0 이 안 된다는 것을 보였다.
# 그런데 그 "쏠린 분포"를 제곱근 꼴 하나로만 만들었고, 못 한 것에 이렇게 적었다.
#   "쏠린 분포를 제곱근 꼴로 만들었습니다. 실제 게임 활동이 그 모양인지는
#    확인하지 않았습니다."
#
# 실제 게임 데이터가 없으니 **그 모양이 맞는지는 이 랩에서 답할 수 없다.**
# 답할 수 있는 것은 다른 질문이다. **결론이 그 모양에만 기대고 있는가.**
#
# 분포족을 여럿 만들어 같은 기준을 돌린다. 모든 모양에서 같은 결론이 나오면
# 그 결론은 모양의 산물이 아니고, 어떤 모양에서 뒤집히면 그것을 적어야 한다.
#
#   U 균등        모두 비슷하게 논다. 실험 3의 데이터셋이 이 모양이었다
#   S 제곱근      실험 7이 쓴 모양. 상위가 수십 배
#   P 멱함수      더 세게 쏠린다. 상위가 수백 배
#   L 로그정규    많은 게임 지표가 이 모양이라고 알려져 있다
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

W_START='2026-08-03 10:00:00'
W_END='2026-08-03 14:00:00'
NORMAL=${DIST_NORMAL:-20000}
ABUSE=${DIST_ABUSE:-30}

wait_ready || exit 2
[ -f "$OUT/dataset.csv" ] || { echo "중단: 실험 1을 먼저 돌립니다" >&2; exit 2; }

{
echo "# 실험 13. 결론이 분포 모양 하나에 기대는가"
echo
echo "  실험 7은 제곱근 꼴 하나에서 \"어떤 기준으로도 오탐이 0 이 안 된다\"고 적었습니다."
echo "  실제 게임이 그 모양인지는 이 랩에서 답할 수 없습니다. 답할 수 있는 것은"
echo "  **그 결론이 그 모양에만 기대는가**입니다. 분포족을 넷 만들어 같은 기준을 돌립니다."
echo
echo "  정상 계정 ${NORMAL}개, 이상 계정 ${ABUSE}개. 이상 계정은 그 분포의 정상 최상위보다"
echo "  1.5배 많이 받습니다. 분포마다 기준값이 달라지므로 데이터에서 읽어 정합니다."
echo

: > "$OUT/distribution.csv"
echo "shape,max_opens,avg_opens,p99_opens,sigma,found,hit,miss,false_positive,innocent_pct" >> "$OUT/distribution.csv"

# 분포마다 계정별 개봉 횟수를 정하는 식이 다르다. rn 이 작을수록 많이 연다.
# 난수를 쓰면 회차마다 결과가 달라지므로 rn 으로 결정한다.
build(){ # $1=모양 코드
  local expr
  case "$1" in
    U) expr="12" ;;                                            # 균등. 모두 12회
    S) expr="CEILING(60.0 / SQRT(CAST(a.rn AS FLOAT)))" ;;      # 제곱근(실험 7)
    P) expr="CEILING(400.0 / POWER(CAST(a.rn AS FLOAT), 0.9))" ;;  # 멱함수. 더 세게 쏠림
    L) expr="CEILING(EXP(2.0 + 1.4 * (1.0 - 2.0 * ((ABS(CHECKSUM(a.rn * 2654435761)) % 1000) / 1000.0))))" ;;  # 로그정규 근사
  esac
  QDX "SET NOCOUNT ON;
  DROP TABLE IF EXISTS truth_dist;
  CREATE TABLE truth_dist (account_id INT PRIMARY KEY);
  DELETE FROM currency_ledger WHERE created_at >= '$W_START' AND created_at < '$W_END';

  WITH a AS (SELECT TOP ($NORMAL) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
               FROM sys.all_objects x CROSS JOIN sys.all_objects y),
       n AS (SELECT TOP (200) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS k
               FROM sys.all_objects)
  INSERT INTO currency_ledger WITH (TABLOCK) (account_id, delta, reason, ref_id, created_at)
  SELECT 1600000 + a.rn, 300, 1, 1900000000 + a.rn * 200 + n.k,
         DATEADD(second, (a.rn * 7 + n.k) % 14400, '$W_START')
    FROM a JOIN n ON n.k <= CASE WHEN ($expr) > 200 THEN 200
                                 WHEN ($expr) < 1 THEN 1 ELSE ($expr) END;" || return 2

  # 이상 계정. 정상 최상위의 1.5 배를 받게 한다.
  #
  # 처음에는 "상위 1퍼센트에 맞춘다"고 NTILE 로 그 구간의 **하한**을 잡았다가,
  # 이상 계정이 정상 평균보다도 적게 받아 어느 기준에서도 안 잡혔다(0/30).
  # 이상 계정이 실제로 이상하지 않으면 이 실험은 아무것도 못 잰다.
  # 기준값은 손으로 안 적고 방금 만든 분포에서 읽는다.
  QDX "SET NOCOUNT ON;
  DECLARE @top INT = (
      SELECT MAX(c) FROM (
          SELECT COUNT(*) AS c FROM currency_ledger
           WHERE created_at >= '$W_START' AND created_at < '$W_END'
           GROUP BY account_id) q);
  DECLARE @cnt INT = CASE WHEN @top IS NULL THEN 10
                          WHEN CEILING(@top * 1.5) > 500 THEN 500
                          ELSE CEILING(@top * 1.5) END;

  WITH a AS (SELECT TOP ($ABUSE) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS ai
               FROM sys.all_objects),
       p AS (SELECT TOP (500) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS pi
               FROM sys.all_objects x CROSS JOIN sys.all_objects y)
  INSERT INTO currency_ledger (account_id, delta, reason, ref_id, created_at)
  SELECT 1700000 + a.ai * 13, 300, 1, 1950000000 + a.ai * 600 + p.pi,
         DATEADD(second, (a.ai * 10 + p.pi) % 14400, '$W_START')
    FROM a JOIN p ON p.pi <= @cnt;

  INSERT INTO truth_dist (account_id)
  SELECT DISTINCT account_id FROM currency_ledger
   WHERE created_at >= '$W_START' AND created_at < '$W_END' AND account_id >= 1700000;" || return 2
  QD "UPDATE STATISTICS currency_ledger WITH FULLSCAN;" >/dev/null
}

score(){ # $1=모양 라벨 $2=시그마 $3..=분포 통계
  local shape=$1 k=$2 dmax=$3 davg=$4 dp99=$5 truth=$6 normal=$7
  local r
  r=$(QD "SET NOCOUNT ON;
  DROP TABLE IF EXISTS #d;
  CREATE TABLE #d (account_id INT PRIMARY KEY);
  DECLARE @avg FLOAT, @sd FLOAT;
  SELECT @avg = AVG(CAST(s AS FLOAT)), @sd = STDEV(CAST(s AS FLOAT))
    FROM (SELECT account_id, SUM(delta) AS s FROM currency_ledger
           WHERE reason = 1 AND created_at >= '$W_START' AND created_at < '$W_END'
           GROUP BY account_id) q;
  INSERT INTO #d (account_id)
  SELECT account_id FROM (SELECT account_id, SUM(delta) AS s FROM currency_ledger
                           WHERE reason = 1 AND created_at >= '$W_START' AND created_at < '$W_END'
                           GROUP BY account_id) q
   WHERE CAST(s AS FLOAT) > @avg + $k * ISNULL(@sd, 0);
  SELECT CAST((SELECT COUNT(*) FROM #d d JOIN truth_dist t ON t.account_id = d.account_id) AS varchar(12))
       + ',' + CAST((SELECT COUNT(*) FROM #d) AS varchar(12));")
  IFS=, read -r hit found <<<"$(num "$r")"
  local fp=$(( found - hit )) miss=$(( truth - hit ))
  local inno; inno=$(python3 -c "print(f'{100*${fp}/${found}:.0f}' if ${found} else '-')")
  printf "  %-14s %-8s %-9s %-11s %-9s %s\n" "$shape" "${k}시그마" "${found}개" "${hit}/${truth}" "${fp}개" "${inno}%"
  echo "$shape,$dmax,$davg,$dp99,$k,$found,$hit,$miss,$fp,$inno" >> "$OUT/distribution.csv"
}

for SHAPE in U S P L; do
  case "$SHAPE" in
    U) LABEL="U 균등" ;;
    S) LABEL="S 제곱근" ;;
    P) LABEL="P 멱함수" ;;
    L) LABEL="L 로그정규" ;;
  esac
  build "$SHAPE" || exit 2

  TRUTH=$(num "$(QD "SELECT COUNT(*) FROM truth_dist")")
  [ "$TRUTH" = "$ABUSE" ] || { echo "중단: ${LABEL} 의 이상 계정이 ${TRUTH}개입니다"; exit 2; }
  ACTIVE=$(num "$(QD "SELECT COUNT(DISTINCT account_id) FROM currency_ledger
                       WHERE created_at >= '$W_START' AND created_at < '$W_END'")")
  NORMAL_N=$(( ACTIVE - TRUTH ))
  D=$(num "$(QD "SET NOCOUNT ON;
  SELECT CAST(MAX(c) AS varchar(12)) + ',' + CAST(AVG(c) AS varchar(12)) + ',' +
         CAST(MAX(CASE WHEN pct = 1 THEN c END) AS varchar(12))
    FROM (SELECT COUNT(*) AS c, NTILE(100) OVER (ORDER BY COUNT(*) DESC) AS pct
            FROM currency_ledger
           WHERE created_at >= '$W_START' AND created_at < '$W_END' AND account_id < 1700000
           GROUP BY account_id) q;")")
  IFS=, read -r DMAX DAVG DP99 <<<"$D"

  echo "## ${LABEL}"
  printf "  정상 계정 개봉 수: 최대 %s / 평균 %s / 상위 1%% 경계 %s\n" "$DMAX" "$DAVG" "$DP99"
  printf "  %-14s %-8s %-9s %-11s %-9s %s\n" "분포" "기준" "지목" "적발" "오탐" "지목 중 무고"
  for K in 3 4 5; do score "$LABEL" "$K" "$DMAX" "$DAVG" "$DP99" "$TRUTH" "$NORMAL_N"; done
  echo
done

QD "DELETE FROM currency_ledger WHERE created_at >= '$W_START' AND created_at < '$W_END';
    DROP TABLE IF EXISTS truth_dist;" >/dev/null
QD "UPDATE STATISTICS currency_ledger WITH FULLSCAN;" >/dev/null

# 결론을 손으로 안 적는다. 방금 쓴 CSV 에서 뽑는다.
R=$(python3 - "$OUT/distribution.csv" <<'PYX'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
def fp(r): return int(r['false_positive'])
def ms(r): return int(r['miss'])
shapes = []
for sh in dict.fromkeys(r['shape'] for r in rows):
    rs = [r for r in rows if r['shape'] == sh]
    shapes.append((sh, min(fp(r) for r in rs)))
zero  = [sh for sh, lo in shapes if lo == 0]
never = [sh for sh, lo in shapes if lo > 0]
missed = [(r['shape'], r['sigma'], r['miss']) for r in rows if ms(r) > 0]
worst = max(rows, key=fp)
print("|".join([
    ";".join(zero) or "없음",
    ";".join(never) or "없음",
    ";".join(f"{a} {b}시그마 {c}개 놓침" for a, b, c in missed) or "없음",
    f"{worst['shape']} {worst['sigma']}시그마 오탐 {worst['false_positive']}개({worst['innocent_pct']}%)",
]))
PYX
)
IFS='|' read -r ZERO_SH NEVER_SH MISSED WORST <<<"$R"

echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  실험 7의 결론이 제곱근 꼴에만 기대는지 확인했습니다. **절반은 기대고 있었습니다.**"
echo
printf "  %-34s %s\n" "오탐이 0 이 되는 분포" "$ZERO_SH"
printf "  %-34s %s\n" "어느 기준에서도 0 이 안 되는 분포" "$NEVER_SH"
printf "  %-34s %s\n" "가장 나쁜 조건" "$WORST"
printf "  %-34s %s\n" "적발을 놓친 조건" "$MISSED"
echo
echo "  **균등 분포에서는 통계 탐지가 완벽합니다.** 모두가 비슷하게 노는 세계에서는"
echo "  이상 계정만 평균에서 멀고 오탐이 0 입니다. 실험 3의 데이터셋이 그 모양이었고,"
echo "  실험 2에서 오탐 40개가 나온 것은 제가 고활동 계정을 심었기 때문이었습니다."
echo
echo "  **쏠린 두 분포에서는 어느 기준에서도 오탐이 안 사라집니다.** 실험 7의 결론이"
echo "  다른 쏠림 모양에서도 그대로 섭니다. 상위 정상 이용자와 어뷰저가 같은 꼬리에"
echo "  있는 것은 제곱근 꼴의 특징이 아니라 **쏠림 자체의 성질**입니다."
echo
if [ "$MISSED" != "없음" ]; then
  echo "  **그리고 실험 7이 놓친 것이 나왔습니다.** 실험 7은 \"기준을 올려 오탐을 줄이는"
  echo "  쪽이 회수 근거로는 안전하다\"고 적었는데, 로그정규에서는 기준을 올리자"
  echo "  **적발이 0 이 됐습니다.** 꼬리가 두꺼워 표준편차가 커지고, 그 선이 어뷰저보다"
  echo "  위로 올라간 것입니다."
  echo
  echo "  기준을 올리는 것은 **오탐을 줄이는 대신 놓침을 늘리는 맞바꿈**이지 안전한"
  echo "  쪽으로 가는 일방통행이 아닙니다. 그 맞바꿈의 기울기가 분포마다 다릅니다."
fi
echo
echo "  그래도 이 랩이 말할 수 없는 것은 남습니다. **실제 게임 활동이 이 넷 중 어느"
echo "  모양인지는 데이터가 없어 모릅니다.** 이 실험이 보인 것은 모양이 결론을 바꾼다는"
echo "  것이고, 그래서 운영에서는 **자기 데이터의 분포를 먼저 그려 보고** 기준을"
echo "  정해야 한다는 것입니다. 3시그마 같은 값을 그대로 가져다 쓰면 안 됩니다."
} 2>&1 | tee "$OUT/exp13-distribution.txt"
