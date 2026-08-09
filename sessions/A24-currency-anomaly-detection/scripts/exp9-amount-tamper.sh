#!/usr/bin/env bash
# 실험 9. 건수는 맞는데 금액만 조작된 사고.
#
# 지금까지 만든 사고는 둘 다 **지급 건수가 늘어난** 모양이었다.
#   실험 1  같은 참조로 지급이 여러 번 들어갔다 (참조 중복)
#   실험 5  참조가 아예 안 남았다 (참조 결측)
#
# 못 한 것에 이렇게 적어 두었다.
#   "값만 조작된 사고(지급 건수는 맞는데 금액만 부풀려진 경우)는 셋 다 못 잡을 텐데
#    만들지 않았습니다."
#
# **못 잡을 것이라고 적어 놓고 확인하지 않았다.** 여기서 만들어 확인하고, 못 잡는다면
# 무엇으로 잡을 수 있는지까지 만든다.
#
# 이 사고가 앞의 둘보다 고약한 이유가 있다. 개봉 한 번에 지급 한 번이라 **개봉 로그와
# 원장이 건수로는 완벽히 맞는다.** 대사가 통과한다. 어긋난 것은 금액뿐이다.
#
# 그리고 조작에는 갈래가 둘이다. 이 데이터셋의 상자는 지급액이 고정이 아니라
# 보상 테이블에서 무작위로 뽑힌다(100~700). 그러면 조작도 두 가지가 된다.
#   T1 테이블 밖의 값을 준다        900 처럼 애초에 나올 수 없는 값
#   T2 테이블 안에서 최고값만 준다  700 만 나온다. 한 건씩 보면 전부 정상이다
#
# 이 둘이 갈리는 자리가 이 실험의 핵심이다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

W_START='2026-08-01 10:00:00'
W_END='2026-08-01 14:00:00'
NORMAL=${TAMPER_NORMAL:-20000}   # 이 창에서 정상적으로 개봉하는 계정
BAD=${TAMPER_BAD:-50}            # 각 조작 유형의 계정 수
OUT_AMT=${OUT_AMT:-900}          # T1 이 받는 값. 보상 테이블 밖이다
OPEN_BASE=20000000               # open_id 는 IDENTITY 가 아니라 직접 넣는다

wait_ready || exit 2
[ -f "$OUT/dataset.csv" ] || { echo "중단: 실험 1을 먼저 돌립니다" >&2; exit 2; }

# 보상 테이블을 손으로 적지 않는다. 사고 이전 데이터에서 읽는다.
TABLE_MIN=$(num "$(QD "SELECT CAST(MIN(delta) AS varchar(12)) FROM currency_ledger
                        WHERE reason = 1 AND created_at < '2026-07-29'")")
TABLE_MAX=$(num "$(QD "SELECT CAST(MAX(delta) AS varchar(12)) FROM currency_ledger
                        WHERE reason = 1 AND created_at < '2026-07-29'")")
TABLE_N=$(num "$(QD "SELECT CAST(COUNT(DISTINCT delta) AS varchar(12)) FROM currency_ledger
                      WHERE reason = 1 AND created_at < '2026-07-29'")")
[ "${TABLE_N:-0}" -ge 2 ] || { echo "중단: 보상 테이블을 못 읽었습니다" >&2; exit 2; }

{
echo "# 실험 9. 건수는 맞는데 금액만 조작된 사고"
echo
echo "  이 상자는 지급액이 고정이 아닙니다. 사고 이전 데이터에서 읽은 보상 테이블은"
echo "  ${TABLE_MIN} 부터 ${TABLE_MAX} 까지 ${TABLE_N} 가지입니다."
echo
echo "  세 번째 창(${W_START} ~ ${W_END})에 두 가지 조작을 심습니다."
echo "    T1 테이블 밖의 값(${OUT_AMT})을 받는 계정 ${BAD}개"
echo "    T2 테이블 안이지만 최고값(${TABLE_MAX})만 받는 계정 ${BAD}개"
echo
echo "  **둘 다 개봉 한 번에 지급 한 번입니다.** 참조도 정상이고 건수도 맞습니다."
echo

QDX "SET NOCOUNT ON;
DELETE FROM currency_ledger WHERE created_at >= '$W_START' AND created_at < '$W_END';
DELETE FROM box_open_log   WHERE opened_at  >= '$W_START' AND opened_at  < '$W_END';
DROP TABLE IF EXISTS truth_tamper;
CREATE TABLE truth_tamper (account_id INT PRIMARY KEY, kind CHAR(2) NOT NULL);" || exit 2

# 개봉 로그. open_id 는 IDENTITY 가 아니므로 직접 넣는다. 처음에 안 넣고 돌렸다가
# Msg 515 로 죽었다. box_id 도 INT 이고 이 데이터셋에서는 상자 종류(1~5)다.
# 처음에 70 억대를 넣었다가 Msg 8115(산술 오버플로)를 봤다.
#
# 계정마다 개봉 횟수를 다르게(1~12회) 준다. 그래야 합계만 보는 방법이 조작을
# 활동량 차이와 구분하지 못하는 것이 드러난다.
QDX "SET NOCOUNT ON;
WITH a AS (SELECT TOP ($(( NORMAL + BAD * 2 ))) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
             FROM sys.all_objects x CROSS JOIN sys.all_objects y),
     k AS (SELECT TOP (12) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
             FROM sys.all_objects)
INSERT INTO box_open_log (open_id, account_id, box_id, opened_at)
SELECT $OPEN_BASE + a.rn * 20 + k.i,
       800000 + a.rn,
       (a.rn + k.i) % 5 + 1,
       DATEADD(second, (a.rn * 11 + k.i) % 14400, '$W_START')
  FROM a JOIN k ON k.i <= (a.rn % 12) + 1;" || exit 2

# 계정을 셋으로 가른다. 앞쪽은 정상, 그다음 BAD 개가 T1, 마지막 BAD 개가 T2 다.
T1_LO=$(( 800000 + NORMAL + 1 ));       T1_HI=$(( 800000 + NORMAL + BAD ))
T2_LO=$(( T1_HI + 1 ));                 T2_HI=$(( T1_HI + BAD ))

# 원장. 정상은 보상 테이블에서 뽑고, T1 은 테이블 밖, T2 는 최고값 고정.
#
# 정상의 추첨은 open_id 를 해시해서 정한다. 난수를 쓰면 회차마다 결과가 달라지고,
# 그렇다고 open_id % N 으로 돌리면 **값이 순환해서** 개봉을 몇 번 하든 최고값만
# 받는 계정이 생기지 않는다. 처음에 그렇게 짰다가 9-3 의 오탐이 0 으로 나왔고,
# 그것은 조작을 잘 가른 것이 아니라 **우연을 만들지 않은 것**이었다.
QDX "SET NOCOUNT ON;
INSERT INTO currency_ledger (account_id, delta, reason, ref_id, created_at)
SELECT b.account_id,
       CASE WHEN b.account_id BETWEEN $T1_LO AND $T1_HI THEN $OUT_AMT
            WHEN b.account_id BETWEEN $T2_LO AND $T2_HI THEN $TABLE_MAX
            ELSE ((ABS(CHECKSUM(b.open_id * 2654435761)) % $TABLE_N) + 1) * $TABLE_MIN END,
       1, b.open_id, b.opened_at
  FROM box_open_log b
 WHERE b.opened_at >= '$W_START' AND b.opened_at < '$W_END';

INSERT INTO truth_tamper (account_id, kind)
SELECT DISTINCT account_id, 'T1' FROM box_open_log
 WHERE opened_at >= '$W_START' AND opened_at < '$W_END'
   AND account_id BETWEEN $T1_LO AND $T1_HI;
INSERT INTO truth_tamper (account_id, kind)
SELECT DISTINCT account_id, 'T2' FROM box_open_log
 WHERE opened_at >= '$W_START' AND opened_at < '$W_END'
   AND account_id BETWEEN $T2_LO AND $T2_HI;" || exit 2
QD "UPDATE STATISTICS currency_ledger WITH FULLSCAN;" >/dev/null

T1_N=$(num "$(QD "SELECT COUNT(*) FROM truth_tamper WHERE kind='T1'")")
T2_N=$(num "$(QD "SELECT COUNT(*) FROM truth_tamper WHERE kind='T2'")")
[ "$T1_N" = "$BAD" ] && [ "$T2_N" = "$BAD" ] \
  || { echo "중단: 이상 계정이 T1 ${T1_N} / T2 ${T2_N} 입니다(기대 각 ${BAD})" >&2; exit 2; }
OPENS=$(num "$(QD "SELECT COUNT(*) FROM box_open_log WHERE opened_at >= '$W_START' AND opened_at < '$W_END'")")
GRANTS=$(num "$(QD "SELECT COUNT(*) FROM currency_ledger WHERE reason = 1 AND created_at >= '$W_START' AND created_at < '$W_END'")")
ACTIVE=$(num "$(QD "SELECT COUNT(DISTINCT account_id) FROM currency_ledger WHERE created_at >= '$W_START' AND created_at < '$W_END'")")
NORMAL_N=$(( ACTIVE - T1_N - T2_N ))

printf "  %-22s %s\n" "개봉 건수" "$OPENS"
printf "  %-22s %s\n" "지급 건수" "$GRANTS"
printf "  %-22s %s\n" "활동 계정" "${ACTIVE}개 (정상 ${NORMAL_N}, T1 ${T1_N}, T2 ${T2_N})"
echo

: > "$OUT/tamper.csv"
echo "method,found,t1_hit,t2_hit,false_positive" >> "$OUT/tamper.csv"

echo "## 9-1. 지금까지의 방법들이 잡는가"
echo
printf "  %-30s %-9s %-11s %-11s %s\n" "방법" "지목" "T1 적발" "T2 적발" "오탐"

score(){ # $1=라벨 $2=지목 계정을 뽑는 SELECT
  local r
  r=$(QD "SET NOCOUNT ON;
  DROP TABLE IF EXISTS #f;
  CREATE TABLE #f (account_id INT PRIMARY KEY);
  INSERT INTO #f (account_id) $2;
  SELECT CAST((SELECT COUNT(*) FROM #f f JOIN truth_tamper t ON t.account_id=f.account_id AND t.kind='T1') AS varchar(12))
       + ',' + CAST((SELECT COUNT(*) FROM #f f JOIN truth_tamper t ON t.account_id=f.account_id AND t.kind='T2') AS varchar(12))
       + ',' + CAST((SELECT COUNT(*) FROM #f) AS varchar(12));")
  IFS=, read -r h1 h2 found <<<"$(num "$r")"
  local fp=$(( found - h1 - h2 ))
  printf "  %-30s %-9s %-11s %-11s %s\n" "$1" "${found}개" "${h1}/${T1_N}" "${h2}/${T2_N}" "${fp}개"
  echo "\"$1\",$found,$h1,$h2,$fp" >> "$OUT/tamper.csv"
}

WIN="created_at >= '$W_START' AND created_at < '$W_END'"

score "A 참조 대사(중복 지급)" "
SELECT DISTINCT account_id FROM currency_ledger
 WHERE reason = 1 AND $WIN
   AND ref_id IN (SELECT ref_id FROM currency_ledger
                   WHERE reason = 1 AND $WIN GROUP BY ref_id HAVING COUNT(*) > 1)"

score "C 개봉 대사(건수 대조)" "
SELECT g.account_id
  FROM (SELECT account_id, COUNT(*) AS c FROM currency_ledger
         WHERE reason = 1 AND $WIN GROUP BY account_id) g
  JOIN (SELECT account_id, COUNT(*) AS c FROM box_open_log
         WHERE opened_at >= '$W_START' AND opened_at < '$W_END'
         GROUP BY account_id) o ON o.account_id = g.account_id
 WHERE g.c > o.c"

score "D 참조 결측" "
SELECT DISTINCT account_id FROM currency_ledger
 WHERE reason = 1 AND $WIN AND ref_id IS NULL"

score "B 통계 이탈(합계 3시그마)" "
SELECT account_id FROM (SELECT account_id, SUM(delta) AS s FROM currency_ledger
                         WHERE reason = 1 AND $WIN GROUP BY account_id) q
 CROSS JOIN (SELECT AVG(CAST(s AS FLOAT)) a, STDEV(CAST(s AS FLOAT)) d
               FROM (SELECT account_id, SUM(delta) AS s FROM currency_ledger
                      WHERE reason = 1 AND $WIN GROUP BY account_id) z) m
 WHERE CAST(q.s AS FLOAT) > m.a + 3 * ISNULL(m.d, 0)"

echo
echo "  **건수를 보는 셋(A·C·D)은 한 건도 못 잡습니다.** 이 사고는 건수가 맞습니다."
echo "  B 는 활동이 많은 정상 계정과 섞입니다."
echo

echo "## 9-2. 보상 테이블 대사"
echo
echo "  건수가 아니라 **한 건의 값**을 봅니다. 게임이 줄 수 있는 값은 정해져 있으므로,"
echo "  그 목록에 없는 값이 나왔다면 그 자체가 결정론적 근거입니다."
echo "  목록은 손으로 적지 않고 사고 이전 데이터에서 읽습니다."
echo
printf "  %-30s %-9s %-11s %-11s %s\n" "방법" "지목" "T1 적발" "T2 적발" "오탐"
score "E 보상 테이블 밖의 값" "
SELECT DISTINCT account_id FROM currency_ledger
 WHERE reason = 1 AND $WIN
   AND delta NOT IN (SELECT DISTINCT delta FROM currency_ledger
                      WHERE reason = 1 AND created_at < '2026-07-29')"

echo
echo "  **E 는 T1 을 전부 잡고 오탐이 0 입니다.** 앞의 결정론적 방법들과 같은 성질입니다."
echo "  **그런데 T2 는 한 건도 못 잡습니다.** T2 가 받은 값은 전부 테이블 안에 있습니다."
echo "  한 건씩 떼어 보면 어느 것도 불법이 아닙니다."
echo

echo "## 9-3. 테이블 안에 머무는 조작"
echo
echo "  T2 를 잡으려면 값 하나가 아니라 **그 계정의 분포**를 봐야 합니다."
echo "  최고값이 나온 비율을 세고 기준을 넘는 계정을 지목합니다."
echo
printf "  %-30s %-9s %-11s %-11s %s\n" "방법" "지목" "T1 적발" "T2 적발" "오탐"
# 두 손잡이가 있다. 최고값 비율과 **최소 개봉 수**다. 개봉을 한 번만 한 계정은
# 우연히 최고값을 받을 확률이 1/7 이라 아무 기준으로도 못 가른다.
for COND in "100 1" "100 3" "100 6" "80 3"; do
  set -- $COND; RATIO=$1; MINC=$2
  score "F 최고값 ${RATIO}%, 개봉 ${MINC}회 이상" "
  SELECT account_id FROM (
      SELECT account_id,
             SUM(CASE WHEN delta = $TABLE_MAX THEN 1 ELSE 0 END) * 100.0 / COUNT(*) AS pct,
             COUNT(*) AS c
        FROM currency_ledger WHERE reason = 1 AND $WIN
       GROUP BY account_id) q
   WHERE q.pct >= $RATIO AND q.c >= $MINC"
done

# 결론을 손으로 안 적는다. 방금 쓴 CSV 에서 뽑는다.
R=$(python3 - "$OUT/tamper.csv" <<'PYX'
import csv, sys
rows = {r['method']: r for r in csv.DictReader(open(sys.argv[1]))}
def g(k, f): return int(rows[k][f])
out = []
for k in ["F 최고값 100%, 개봉 1회 이상", "F 최고값 100%, 개봉 3회 이상",
          "F 최고값 100%, 개봉 6회 이상"]:
    found, hit, fp = g(k, 'found'), g(k, 't2_hit'), g(k, 'false_positive')
    inno = f"{100*fp/found:.0f}" if found else "-"
    out += [str(hit), str(fp), inno]
print("|".join(out))
PYX
)
IFS='|' read -r H1 F1 I1 H3 F3 I3 H6 F6 I6 <<<"$R"
echo
echo "  **오탐이 생깁니다.** 개봉을 한 번만 한 계정은 우연히 최고값을 받을 확률이"
echo "  $(( 100 / TABLE_N ))% 가까이 되고, 그 계정은 조작과 구분되지 않습니다."
echo
printf "  %-26s %s\n" "개봉 1회 이상까지 보면" "${H1}/${T2_N} 을 잡지만 오탐 ${F1}개(지목 중 ${I1}%)"
printf "  %-26s %s\n" "개봉 3회 이상으로 올리면" "${H3}/${T2_N}, 오탐 ${F3}개(${I3}%)"
printf "  %-26s %s\n" "개봉 6회 이상으로 올리면" "${H6}/${T2_N}, 오탐 ${F6}개(${I6}%)"
echo
echo "  **오탐을 0 으로 만들 수는 있는데 그러면 절반 가까이 놓칩니다.** 개봉을 적게 한"
echo "  조작 계정은 우연과 구분할 근거가 아예 없습니다. 실험 7에서 본 것과 같은"
echo "  맞바꿈이고, 원인도 같습니다. 통계는 **표본이 쌓여야** 말할 수 있습니다."
echo

echo "## 9-4. 회수액을 정할 수 있는가"
echo
T1_EXCESS=$(num "$(QD "SET NOCOUNT ON;
SELECT CAST(SUM(delta - $TABLE_MAX) AS varchar(30)) FROM currency_ledger
 WHERE reason = 1 AND $WIN AND account_id IN (SELECT account_id FROM truth_tamper WHERE kind='T1')")")
T1_FULL=$(num "$(QD "SET NOCOUNT ON;
SELECT CAST(SUM(delta) AS varchar(30)) FROM currency_ledger
 WHERE reason = 1 AND $WIN AND account_id IN (SELECT account_id FROM truth_tamper WHERE kind='T1')")")
T1_ROWS=$(num "$(QD "SELECT COUNT(*) FROM currency_ledger
 WHERE reason = 1 AND $WIN AND account_id IN (SELECT account_id FROM truth_tamper WHERE kind='T1')")")
T1_CHK=$(num "$(QD "SELECT CAST(($OUT_AMT - $TABLE_MAX) * $T1_ROWS AS varchar(30))")")
printf "  %-34s %s\n" "T1 지급 건수" "$T1_ROWS"
printf "  %-34s %s\n" "테이블 최고값으로 내리면" "$T1_EXCESS"
printf "  %-34s %s\n" "그 기대값" "$T1_CHK"
printf "  %-34s %s\n" "전액을 회수하면" "$T1_FULL"
echo "\"T1 초과분 회수\",$T1_EXCESS,$T1_CHK,0,0" >> "$OUT/tamper.csv"
if [ "$T1_EXCESS" = "$T1_CHK" ]; then
  echo
  echo "  초과분 산정이 기대값과 정확히 맞습니다."
else
  echo
  echo "  **어긋납니다.** 회수 근거로 쓸 수 없습니다."
fi
echo
echo "  다만 **얼마를 회수할지는 DB 가 정하지 못합니다.** 지급액이 무작위라 \"정상이었다면"
echo "  얼마였을까\"를 알 수 없기 때문입니다. DB 가 줄 수 있는 것은 두 숫자입니다."
echo "    테이블 최고값까지 인정하고 초과분만 회수  ${T1_EXCESS}"
echo "    그 지급 자체를 무효로 보고 전액 회수      ${T1_FULL}"
echo "  어느 쪽인지는 정책이 정합니다. **DBA 가 할 일은 두 숫자를 정확히 대는 것**입니다."
echo
echo "  T2 는 회수액을 아예 못 냅니다. 받은 값이 전부 합법이라 초과분이라는 개념이"
echo "  없습니다. 지목 목록은 조사 대상까지이고 근거는 다른 데서 와야 합니다."
echo "  (지급 로직의 코드나 서버 로그, 즉 DB 밖입니다.)"

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  못 한 것에 \"셋 다 못 잡을 텐데 만들지 않았습니다\"라고 적어 둔 것을 만들었습니다."
echo "  못 잡는 것은 맞았는데, **이유가 제가 생각한 것보다 구조적이었습니다.**"
echo
echo "  A·C·D 가 못 잡는 이유가 같습니다. 셋 다 **건수를 세는 방법**입니다."
echo "  참조 중복도 건수, 개봉 대조도 건수, 참조 결측도 결국 건수입니다."
echo "  결정론적 방법을 셋이나 갖췄다고 안심했는데 **셋이 같은 축을 보고 있었습니다.**"
echo "  방법을 늘리는 것과 **보는 축을 늘리는 것**은 다릅니다."
echo
echo "  축을 하나 더 놓자(E) T1 이 오탐 0 으로 잡혔습니다. 게임이 줄 수 있는 값이"
echo "  정해져 있다는 **설계 자체가 근거**라 통계가 아니라 규칙과 대조하는 것입니다."
echo
echo "  그런데 T2 에서 선이 하나 더 드러났습니다."
echo
echo "    조작이 **규칙 밖으로 나가면** 결정론적으로 잡히고 회수액도 정확히 나온다"
echo "    조작이 **규칙 안에 머물면** 어느 결정론적 방법도 못 잡는다. 통계로 가야 하고"
echo "    거기서는 오탐이 따라오며 회수 근거를 못 만든다"
echo
echo "  실험 5는 \"참조가 안 남는 사고에는 통계밖에 없다\"였고 이것은 \"규칙 안에 머무는"
echo "  조작에는 통계밖에 없다\"입니다. **결정론적 방법이 닿는 범위는 규칙이 정한 경계까지**"
echo "  이고, 그 안쪽은 통계의 몫입니다. 통계적 탐지를 버릴 수 없는 두 번째 이유입니다."
echo
echo "  운영으로 옮기면 대사 항목이 하나 늘어납니다."
echo "    1 참조 대사      같은 참조로 두 번 지급됐는가"
echo "    2 개봉 대사      개봉 수와 지급 수가 맞는가"
echo "    3 참조 결측      참조가 없는 지급이 있는가"
echo "    4 보상 테이블    **지급액이 줄 수 있는 값의 목록 안에 있는가**"
echo "  그리고 4번까지 통과한 뒤에도 통계 감시는 남겨 둡니다."
} 2>&1 | tee "$OUT/exp9-amount-tamper.txt"
