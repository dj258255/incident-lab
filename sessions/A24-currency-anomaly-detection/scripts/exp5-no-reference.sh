#!/usr/bin/env bash
# 실험 5. 참조가 안 남는 사고에서는 무엇으로 잡는가.
#
# 실험 2는 세 방법을 견주고 "통계 이탈은 조사 범위를 좁히는 데만 쓰고 회수 근거로는
# 쓰지 말라"고 결론지었다. 오탐 40개가 오회수가 되기 때문이다.
#
# 그런데 그 결론에는 짝이 되는 문장이 필요하다. **그러면 통계 이탈은 왜 버리지 않나.**
# 실험 2에서는 참조 대사와 개봉 대사가 오탐 0으로 다 잡았으니 통계 이탈이 없어도
# 아쉬울 것이 없어 보인다.
#
# 그 짝을 이 실험이 만든다. 모든 사고가 참조를 남기는 것은 아니다. 재화가 어디서
# 왔는지 원장에 안 적히는 사고가 있다. 치트나 어뷰징으로 지급 경로 자체가 우회되면
# ref_id 가 NULL 로 들어오거나 아예 원인 로그가 없다.
#
# 두 번째 사고를 그 모양으로 심고 세 방법을 다시 돌린다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

WIN2_START='2026-07-29 10:00:00'   # 두 번째 사고 창. 첫 사고와 겹치지 않는다
WIN2_END='2026-07-29 14:00:00'
GHOST_ACCOUNTS=${GHOST_ACCOUNTS:-40}
GHOST_ROWS=${GHOST_ROWS:-20}

wait_ready || exit 2
[ -f "$OUT/dataset.csv" ] || { echo "중단: 실험 1을 먼저 돌립니다" >&2; exit 2; }

{
echo "# 실험 5. 참조가 안 남는 사고"
echo
echo "  두 번째 사고를 심습니다. 첫 사고(${GHOST_ACCOUNTS}개와 겹치지 않는 계정)와 다른 점은"
echo "  **원장에 ref_id 가 안 남는다**는 것입니다. 지급 경로를 우회해 재화만 꽂힌 모양입니다."
echo "  개봉 로그에도 대응하는 행이 없습니다."
echo
echo "  사고 창: ${WIN2_START} ~ ${WIN2_END}"
echo

# 두 번째 사고를 심는다. 첫 사고 계정과 겹치면 판정이 섞이므로 뒤쪽 대역을 쓴다.
QDX "SET NOCOUNT ON;
DROP TABLE IF EXISTS truth_ghost;
CREATE TABLE truth_ghost (account_id INT PRIMARY KEY, extra_amount BIGINT NOT NULL);

DELETE FROM currency_ledger
 WHERE reason = 1 AND ref_id IS NULL
   AND created_at >= '$WIN2_START' AND created_at < '$WIN2_END';

WITH a AS (SELECT TOP ($GHOST_ACCOUNTS) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS ai
             FROM sys.all_objects),
     p AS (SELECT TOP ($GHOST_ROWS)     ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS pi
             FROM sys.all_objects)
INSERT INTO currency_ledger (account_id, delta, reason, ref_id, created_at)
SELECT 400000 + a.ai * 11, 700, 1, NULL,
       DATEADD(second, (a.ai * $GHOST_ROWS + p.pi) % 14400, '$WIN2_START')
  FROM a CROSS JOIN p;

INSERT INTO truth_ghost (account_id, extra_amount)
SELECT account_id, SUM(delta)
  FROM currency_ledger
 WHERE reason = 1 AND ref_id IS NULL
   AND created_at >= '$WIN2_START' AND created_at < '$WIN2_END'
 GROUP BY account_id;" || exit 2

QD "UPDATE STATISTICS currency_ledger WITH FULLSCAN;" >/dev/null

TRUTH=$(num "$(QD "SELECT COUNT(*) FROM truth_ghost")")
GSUM=$(num "$(QD "SELECT ISNULL(SUM(extra_amount),0) FROM truth_ghost")")
OVERLAP=$(num "$(QD "SELECT COUNT(*) FROM truth_ghost g JOIN truth_accounts t ON t.account_id = g.account_id")")
[ "$TRUTH" = "$GHOST_ACCOUNTS" ] || { echo "중단: 이상 계정이 ${TRUTH}개입니다(기대 ${GHOST_ACCOUNTS})"; exit 2; }
[ "$OVERLAP" = "0" ] || { echo "중단: 첫 사고 계정과 ${OVERLAP}개 겹칩니다"; exit 2; }
printf "  %-24s %s\n" "이상 계정 (정답)" "${TRUTH}개"
printf "  %-24s %s\n" "부당 취득 합계" "$GSUM"
printf "  %-24s %s\n" "첫 사고와 겹침" "${OVERLAP}개"
echo

score(){
  local label=$1 sql=$2
  local r
  r=$(QD "SET NOCOUNT ON;
  DROP TABLE IF EXISTS #found;
  CREATE TABLE #found (account_id INT PRIMARY KEY);
  $sql
  SELECT CAST((SELECT COUNT(*) FROM #found f JOIN truth_ghost t ON t.account_id = f.account_id) AS varchar(12))
       + ',' + CAST((SELECT COUNT(*) FROM #found) AS varchar(12));")
  if echo "$r" | grep -qE '^(Msg|메시지) [0-9]+'; then
    printf "  %-14s %s\n" "$label" "**질의 실패**"; echo "$r" | grep -E '^(Msg|메시지)' | head -1; return
  fi
  IFS=, read -r hit found <<<"$(num "$r")"
  local fp=$(( found - hit )) miss=$(( TRUTH - hit ))
  printf "  %-14s %-10s %-12s %-10s %s\n" "$label" "${found}개" "${hit}/${TRUTH}" "${miss}개" "${fp}개"
  echo "$label,$found,$hit,$miss,$fp" >> "$OUT/no-reference.csv"
}

: > "$OUT/no-reference.csv"
echo "method,found,hit,miss,false_positive" >> "$OUT/no-reference.csv"
printf "  %-14s %-10s %-12s %-10s %s\n" "방법" "지목" "적발" "놓침" "오탐"

# A 참조 대사. 같은 ref_id 에 지급이 여러 건인 것을 찾는다. ref_id 가 NULL 이면 묶일 것이 없다.
score "A 참조 대사" "
INSERT INTO #found (account_id)
SELECT DISTINCT account_id
  FROM currency_ledger
 WHERE reason = 1
   AND created_at >= '$WIN2_START' AND created_at < '$WIN2_END'
   AND ref_id IN (SELECT ref_id FROM currency_ledger
                   WHERE reason = 1
                     AND created_at >= '$WIN2_START' AND created_at < '$WIN2_END'
                   GROUP BY ref_id HAVING COUNT(*) > 1);"

# C 개봉 대사. 개봉 로그와 조인한다. 개봉 자체가 없으면 조인에 안 걸린다.
score "C 개봉 대사" "
INSERT INTO #found (account_id)
SELECT DISTINCT b.account_id
  FROM box_open_log b
  JOIN (SELECT ref_id, COUNT(*) AS c FROM currency_ledger
         WHERE reason = 1
           AND created_at >= '$WIN2_START' AND created_at < '$WIN2_END'
         GROUP BY ref_id) l ON l.ref_id = b.open_id
 WHERE b.opened_at >= '$WIN2_START' AND b.opened_at < '$WIN2_END'
   AND l.c <> 1;"

# B 통계 이탈. 참조를 안 본다. 획득량만 본다.
score "B 통계 이탈" "
DECLARE @avg FLOAT, @sd FLOAT;
SELECT @avg = AVG(CAST(s AS FLOAT)), @sd = STDEV(CAST(s AS FLOAT))
  FROM (SELECT account_id, SUM(delta) AS s
          FROM currency_ledger
         WHERE reason = 1 AND created_at >= '$WIN2_START' AND created_at < '$WIN2_END'
         GROUP BY account_id) q;
INSERT INTO #found (account_id)
SELECT account_id
  FROM (SELECT account_id, SUM(delta) AS s
          FROM currency_ledger
         WHERE reason = 1 AND created_at >= '$WIN2_START' AND created_at < '$WIN2_END'
         GROUP BY account_id) q
 WHERE CAST(s AS FLOAT) > @avg + 3 * ISNULL(@sd, 0);"

# D 참조 없음 자체를 신호로 삼는다. 이 사고 유형에만 통하는 맞춤 쿼리다.
score "D 참조 결측" "
INSERT INTO #found (account_id)
SELECT DISTINCT account_id
  FROM currency_ledger
 WHERE reason = 1 AND ref_id IS NULL
   AND created_at >= '$WIN2_START' AND created_at < '$WIN2_END';"

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  **A 와 C 가 한 건도 못 잡습니다.** 둘 다 참조를 축으로 삼기 때문입니다."
echo "  A 는 같은 ref_id 에 지급이 여러 건인 것을 찾는데 ref_id 가 NULL 이면 묶을 것이"
echo "  없습니다. C 는 개봉 로그와 조인하는데 개봉 자체가 없으니 조인에 안 걸립니다."
echo
echo "  **B 는 잡습니다.** 참조를 안 보고 획득량만 보기 때문입니다. 실험 2에서 오탐을"
echo "  만들어 회수 근거로 못 쓴다고 했던 바로 그 성질이, 여기서는 유일하게 통하는"
echo "  성질이 됩니다."
echo
echo "  다만 **여기서 B 의 오탐이 0인 것은 조건이 달라서입니다.** 이 두 번째 창에는"
echo "  정상 고활동 계정을 안 심었습니다. 실험 2의 첫 창에는 심어 두었고 거기서 오탐이"
echo "  40개 나왔습니다. B 의 오탐 성질이 사라진 것이 아니라 이 창에 그 원천이 없을"
echo "  뿐입니다. 두 실험의 오탐 수를 나란히 비교하면 안 됩니다."
echo
echo "  D 는 이 사고를 알고 나서 쓴 맞춤 쿼리입니다. ref_id 가 NULL 인 지급을 그냥"
echo "  세면 정확히 잡힙니다. 다만 이것은 **사고의 모양을 이미 안 뒤에야** 쓸 수 있습니다."
echo "  B 가 먼저 이상한 계정을 짚어 주지 않으면 ref_id 를 볼 생각도 못 합니다."
echo
echo "  그래서 실험 2의 결론에 짝이 붙습니다."
echo "    통계 이탈은 회수 근거로 쓰지 않는다. 오탐이 오회수가 된다."
echo "    그러나 버리지도 않는다. 참조가 없는 사고에서는 그것뿐이다."
echo
echo "  통계 이탈이 짚어 준 계정을 사람이 열어 보고 사고의 모양을 알아낸 다음,"
echo "  그 모양에 맞는 결정론적 쿼리를 만들어 회수 근거로 삼는 순서입니다."
} 2>&1 | tee "$OUT/exp5-no-reference.txt"
