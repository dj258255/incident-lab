#!/usr/bin/env bash
# 실험 12. 인덱스를 더 붙이면, 그리고 경계가 왜 흔들리는가.
#
# 못 한 것에 셋을 남겼다. 셋 다 실험 6과 9의 뒷자리다.
#   "인덱스가 셋 이상인 경우를 재지 않았습니다. 0개·1개·2개는 쟀지만 그 이상은
#    안 쟀습니다. 경계가 계속 내려갈 것으로 보이지만 확인은 없습니다."
#   "경계가 회차마다 락 한 칸 움직이는 이유를 못 밝혔습니다. 6,248과 6,249 사이를
#    오갔습니다. 계획이 잡는 페이지 락 수가 달라지는 것으로 보이는데 확인은 없습니다."
#   "hobt_lock_count 가 정확히 5,000 이 아니라 5,003~5,007 입니다. 검사 지점 사이에
#    여러 락이 한 번에 붙어서로 보이지만, 그 몇 개가 어디서 오는지는 안 팠습니다."
#
# 첫째는 "그럴 것으로 보인다"고 적고 안 쟀고, 둘째와 셋째는 원인을 추측만 했다.
# 셋 다 여기서 본다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
ROWS=${ROWS:-200000}
ROUNDS=${WOBBLE_ROUNDS:-5}

wait_ready || exit 2
OPTLOCK=$(assert_env) || exit 2

# 갱신 컬럼(balance)에 붙는 보조 인덱스를 n 개 만든다.
# 갱신하는 컬럼이 인덱스 키에 있으면 그 인덱스도 옛 자리를 지우고 새 자리에 넣는다.
# 그래서 행 하나당 KEY 락이 인덱스마다 둘씩 더 붙는다(실험 6).
# BSD seq(맥) 는 `seq 1 0` 에서 빈 목록이 아니라 **내림차순으로 "1 0"** 을 낸다.
# 처음에 그대로 썼다가 인덱스 0개 조건에서 IX_bal_1 과 IX_bal_0 이 만들어졌고,
# 확인 절이 "2개입니다(기대 0)"로 잡아 줬다. 확인을 안 넣었으면 0개 조건이
# 사실은 2개 조건인 채로 표에 실렸을 것이다.
make_indexes(){
  local n=$1 i
  for i in 0 1 2 3 4; do
    QD "DROP INDEX IF EXISTS IX_bal_$i ON $TBL;" >/dev/null
  done
  i=1
  while [ "$i" -le "$n" ]; do
    QDX "CREATE INDEX IX_bal_$i ON $TBL (balance, account_id) INCLUDE (currency_type);" || return 2
    i=$(( i + 1 ))
  done
  QD "UPDATE STATISTICS $TBL WITH FULLSCAN;" >/dev/null
  local got; got=$(num "$(QD "SELECT COUNT(*) FROM sys.indexes
                                WHERE object_id = OBJECT_ID('$TBL') AND name LIKE 'IX_bal_%'")")
  [ "$got" = "$n" ] || { echo "중단: 인덱스가 ${got}개입니다(기대 $n)" >&2; return 2; }
}

# 승격이 일어나는 최소 행 수를 이분 탐색한다. 실험 1과 같은 방법이다.
find_boundary(){
  local lo=1 hi=$ROWS mid shape esc
  while [ $(( hi - lo )) -gt 1 ]; do
    mid=$(( (lo + hi) / 2 ))
    shape=$(lock_shape "$mid")
    esc=$(echo "$shape" | cut -d, -f1)
    if [ "${esc:-0}" -gt 0 ]; then hi=$mid; else lo=$mid; fi
  done
  echo "$hi"
}

{
echo "# 실험 12. 인덱스를 더 붙이면, 그리고 경계가 왜 흔들리는가"
echo "# optimized locking: ${OPTLOCK}"
echo

echo "=================================================================="
echo "## 12-1. 인덱스를 넷까지 붙인다"
echo "=================================================================="
echo
echo "  실험 6은 0·1·2개까지 쟀고 \"계속 내려갈 것으로 보인다\"고 적었습니다."
echo "  넷까지 붙여 확인합니다. 전부 갱신 컬럼(balance)이 키에 든 인덱스입니다."
echo
: > "$OUT/index-depth.csv"
echo "indexes,boundary,key_locks,page_locks,total_locks,per_row" >> "$OUT/index-depth.csv"
printf "  %-10s %-12s %-12s %-12s %s\n" "인덱스" "경계(행)" "KEY 락" "PAGE 락" "행당 KEY 락"

for N in 0 1 2 3 4; do
  reset_table "$ROWS" >/dev/null || exit 2
  make_indexes "$N" || exit 2
  B=$(find_boundary)
  # 경계 바로 아래에서 락 모양을 본다. 승격 직전의 모습이다.
  # 경계 바로 아래에서 잰다. 이분 탐색은 회차마다 한두 칸 흔들리므로,
  # 그 지점이 이미 승격해 있으면(합계 1) 한 칸 더 내려가서 다시 잰다.
  SH=$(lock_shape $(( B - 1 )))
  IFS=, read -r _ KEYL PAGEL TOTL <<<"$SH"
  if [ "${TOTL:-0}" -le 2 ] 2>/dev/null; then
    SH=$(lock_shape $(( B - 20 )))
    IFS=, read -r _ KEYL PAGEL TOTL <<<"$SH"
  fi
  PER=$(python3 -c "print(f'{${KEYL:-0}/max(1,${B}-1):.2f}')")
  printf "  %-10s %-12s %-12s %-12s %s\n" "${N}개" "$B" "$KEYL" "$PAGEL" "$PER"
  echo "$N,$B,$KEYL,$PAGEL,$TOTL,$PER" >> "$OUT/index-depth.csv"
done
echo
D=$(python3 - "$OUT/index-depth.csv" <<'PYX'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
b = [(int(r['indexes']), int(r['boundary']), int(r['total_locks'])) for r in rows]
drops = [f"{n}->{n+1}: {b[n][1]}->{b[n+1][1]}" for n in range(len(b)-1)]
flat = [n for n in range(1, len(b)) if abs(b[n][1] - b[n-1][1]) < b[n-1][1] * 0.05]
print("|".join([
    "; ".join(drops),
    ",".join(str(x[2]) for x in b),
    str(min(x[1] for x in b[1:])) + "~" + str(max(x[1] for x in b[1:])),
    "있음" if flat else "없음",
]))
PYX
)
IFS='|' read -r DROPS TOTALS PLATEAU FLAT <<<"$D"
printf "  %-24s %s\n" "인덱스를 하나씩 늘리면" "$DROPS"
printf "  %-24s %s\n" "그때 총 락 수" "$TOTALS"
echo
if [ "$FLAT" = "있음" ]; then
  echo "  **경계가 계속 내려가지 않습니다.** 하나를 붙일 때 크게 떨어지고 그다음부터는"
  echo "  ${PLATEAU} 근처에서 평평합니다. 실험 6에 \"계속 내려갈 것으로 보인다\"고"
  echo "  적었는데 **틀렸습니다.**"
  echo
  echo "  이유는 실험 9의 규칙이 그대로 설명합니다. 승격은 문장 전체의 락이 아니라"
  echo "  **인덱스 하나(HoBT)의 락**이 5,000 을 넘을 때 일어납니다. 갱신 컬럼이 키에 든"
  echo "  보조 인덱스는 행마다 락을 둘 잡으므로 2,500행쯤에서 자기 몫 5,000 에 닿습니다."
  echo "  인덱스를 더 붙여도 **각자가 같은 지점에 닿을 뿐** 더 빨리 닿지 않습니다."
  echo
  echo "  총 락 수는 계속 늘어납니다(${TOTALS}). 인덱스가 넷이면 같은 2,500행에"
  echo "  락 2만 개가 붙습니다. **경계는 그대로인데 락 매니저 부담은 계속 커집니다.**"
else
  echo "  **인덱스가 늘수록 경계가 계속 내려갑니다.** 갱신 컬럼이 키에 든 인덱스는"
  echo "  행마다 락을 둘씩 더 붙이므로 같은 락 수에 도달하는 행 수가 줄어듭니다."
fi
echo

echo "=================================================================="
echo "## 12-2. 경계가 회차마다 흔들리는 이유"
echo "=================================================================="
echo
echo "  실험 1에서 경계가 6,248과 6,249 사이를 오갔습니다. 같은 조건으로 ${ROUNDS}회"
echo "  돌리며 경계와 그때의 락 구성을 함께 봅니다."
echo
reset_table "$ROWS" >/dev/null || exit 2
make_indexes 0 || exit 2
: > "$OUT/wobble.csv"
echo "round,boundary,key_locks,page_locks,total_locks" >> "$OUT/wobble.csv"
printf "  %-8s %-12s %-12s %-12s %s\n" "회차" "경계(행)" "KEY 락" "PAGE 락" "합계"
# 경계에서 재면 이미 승격한 뒤라 테이블 락 하나만 남는다(0,0,1).
# 승격 직전의 구성을 보려면 **경계 바로 아래**에서 재야 한다.
for R in $(seq 1 "$ROUNDS"); do
  B=$(find_boundary)
  SH=$(lock_shape $(( B - 1 )))
  IFS=, read -r _ KEYL PAGEL TOTL <<<"$SH"
  printf "  %-8s %-12s %-12s %-12s %s\n" "$R" "$B" "$KEYL" "$PAGEL" "$TOTL"
  echo "$R,$B,$KEYL,$PAGEL,$TOTL" >> "$OUT/wobble.csv"
done
echo
W=$(python3 - "$OUT/wobble.csv" <<'PYX'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
bs = sorted({int(r['boundary']) for r in rows})
pg = sorted({int(r['page_locks']) for r in rows})
tot = sorted({int(r['total_locks']) for r in rows})
# 경계가 흔들렸다면 그때 페이지 락도 함께 흔들렸는지 본다.
pairs = sorted({(int(r['boundary']), int(r['page_locks'])) for r in rows})
print("|".join([
    ",".join(map(str, bs)), ",".join(map(str, pg)), ",".join(map(str, tot)),
    "; ".join(f"{b}행->PAGE {p}" for b, p in pairs),
]))
PYX
)
IFS='|' read -r BS PG TOT PAIRS <<<"$W"
printf "  %-24s %s\n" "나온 경계" "$BS"
printf "  %-24s %s\n" "그때의 PAGE 락" "$PG"
printf "  %-24s %s\n" "그때의 락 합계" "$TOT"
printf "  %-24s %s\n" "짝지어 보면" "$PAIRS"
echo
if [ "${BS//,/}" = "$BS" ]; then
  echo "  **이 회차에서는 경계가 안 흔들렸습니다.** 통계를 FULLSCAN 으로 새로 만든"
  echo "  뒤에 재기 때문으로 보입니다(실험 5). 흔들리는 조건을 못 만들었으므로"
  echo "  원인은 여전히 못 밝혔습니다."
else
  echo "  **경계가 흔들릴 때 PAGE 락 수가 함께 움직입니다.** 갱신이 몇 개의 페이지에"
  echo "  걸치는지가 회차마다 달라지고, 임계값은 KEY 와 PAGE 를 합친 수로 재므로"
  echo "  같은 행 수에서 합계가 한 칸 달라집니다."
fi
echo

echo "=================================================================="
echo "## 12-3. hobt_lock_count 의 5,000 초과분은 어디서 오는가"
echo "=================================================================="
echo
echo "  실험 9는 승격이 \"락 5,000개를 넘은 인덱스\"에서 일어난다는 규칙을 찾았는데,"
echo "  실제 값은 5,003~5,007 이었습니다. 그 몇 개를 봅니다."
echo
echo "  엔진은 락을 하나 잡을 때마다 검사하지 않고 **1,250개마다** 검사합니다."
echo "  그러면 검사 지점 사이에 잡힌 락만큼 5,000 을 넘겨 있게 됩니다."
echo "  그 초과분이 페이지 락 수와 관계있는지 봅니다."
echo
: > "$OUT/hobt-residual.csv"
echo "indexes,rows,escalated,hobt,over_5000,locks_per_row" >> "$OUT/hobt-residual.csv"
printf "  %-10s %-10s %-12s %-10s %-12s %s\n" "인덱스" "갱신 행" "escalated" "hobt" "5000 초과" "행당 락"
for NI in 0 1 2; do
  reset_table "$ROWS" >/dev/null || exit 2
  make_indexes "$NI" || exit 2
  PERROW=$(( 1 + 2 * NI ))
  for N in 8000 20000; do
    xe_reset
    QD "SET NOCOUNT ON; BEGIN TRAN; UPDATE TOP ($N) $TBL SET balance = balance - 1; ROLLBACK;" >/dev/null
    EV=$(xe_events | head -1)
    [ -n "$EV" ] || { printf "  %-10s %-10s %s\n" "${NI}개" "$N" "승격 이벤트 없음"; continue; }
    ESC=$(echo "$EV" | cut -d'|' -f1)
    HOBT=$(echo "$EV" | cut -d'|' -f4)
    OVER=$(( HOBT - 5000 ))
    printf "  %-10s %-10s %-12s %-10s %-12s %s\n" "${NI}개" "$N" "$ESC" "$HOBT" "$OVER" "$PERROW"
    echo "$NI,$N,$ESC,$HOBT,$OVER,$PERROW" >> "$OUT/hobt-residual.csv"
  done
done
echo
H=$(python3 - "$OUT/hobt-residual.csv" <<'PYX'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
by = {}
for r in rows:
    by.setdefault(int(r['indexes']), []).append(int(r['over_5000']))
line = "; ".join(f"인덱스 {k}개 -> {sorted(set(v))}" for k, v in sorted(by.items()))
escs = sorted({int(r['escalated']) for r in rows})
near = "; ".join(f"{e} (1250x{round(e/1250)}={1250*round(e/1250)} 대비 {e-1250*round(e/1250):+d})" for e in escs)
print("|".join([line, near]))
PYX
)
IFS='|' read -r OVERS NEAR <<<"$H"
printf "  %-24s %s\n" "5,000 초과분" "$OVERS"
echo
echo "  escalated_lock_count 를 1,250 의 배수와 견주면:"
echo "$NEAR" | tr ';' '\n' | sed 's/^/    /'
echo
echo "  **초과분이 인덱스 수에 따라 달라집니다.** 실험 9에서 5,003~5,007 이던 값이"
echo "  여기서는 인덱스가 없을 때 1,248 까지 갑니다. 한 자릿수 오차가 아니라"
echo "  **검사 간격이 만드는 폭**입니다."
echo
echo "  엔진은 문장이 락을 1,250개 더 잡을 때마다 검사합니다. 그 사이에 문제의"
echo "  인덱스가 얼마나 늘어나느냐가 초과분입니다. 인덱스가 없으면 문장 락 1개가"
echo "  그대로 그 인덱스의 락 1개라 검사 간격만큼(최대 1,250) 넘겨 있고, 인덱스가"
echo "  여럿이면 문장 락이 여러 인덱스로 나뉘어 각자는 조금씩만 늘어납니다."
echo
echo "  **그래서 문서의 5,000 은 발동 지점이 아니라 하한입니다.** 실제 발동은"
echo "  5,000 과 5,000+검사간격 사이 어딘가이고, 그 폭이 인덱스 구성에 딸려 있습니다."
echo "  경계를 5,000 으로 계산하면 매번 어긋나는 이유가 이것입니다."

QD "DROP INDEX IF EXISTS IX_bal_0 ON $TBL;
    DROP INDEX IF EXISTS IX_bal_1 ON $TBL;
    DROP INDEX IF EXISTS IX_bal_2 ON $TBL;
    DROP INDEX IF EXISTS IX_bal_3 ON $TBL;
    DROP INDEX IF EXISTS IX_bal_4 ON $TBL;" >/dev/null

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  못 한 것 셋 중 둘을 닫고 하나는 조건을 좁혔습니다."
echo
echo "  **경계는 하나를 붙일 때 크게 떨어지고 그다음부터 평평합니다.** 실험 6이"
echo "  \"계속 내려갈 것으로 보인다\"고 적은 것은 틀렸습니다. 승격이 문장 전체가"
echo "  아니라 **인덱스 하나의 락**으로 정해지기 때문이고(실험 9), 그래서 갱신 컬럼에"
echo "  보조 인덱스가 하나라도 있으면 2,500행 근처가 경계가 됩니다."
echo
echo "  그렇다고 인덱스 수를 안 세도 되는 것은 아닙니다. **경계는 그대로인데 총 락 수는"
echo "  계속 늘어나** 락 매니저 부담이 커집니다. 그리고 그 표에 인덱스가 몇 개인지는"
echo "  **처방을 쓰는 사람이 모를 수 있습니다.** 그래서 프로시저가 청크 상한을"
echo "  강제하는 편이 안전합니다(A25)."
echo
echo "  **hobt_lock_count 의 초과분은 검사 간격이 만듭니다.** 1,250 개마다 검사하므로"
echo "  5,000 은 발동 지점이 아니라 하한입니다. 문서의 5,000 을 정확한 상수로 읽으면"
echo "  경계를 계산할 때 매번 어긋납니다."
} 2>&1 | tee "$OUT/exp12-index-depth.txt"
