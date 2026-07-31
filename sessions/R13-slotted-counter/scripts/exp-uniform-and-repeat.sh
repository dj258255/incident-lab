#!/usr/bin/env bash
# README 의 "못 한 것" 두 개를 잡는다.
#
#   1) 자동 슬롯을 고른 부하에서 재지 않았습니다
#      "7절은 zipf 부하 하나이고, 트래픽이 고르게 퍼지면 슬롯 하나만 받은 방송에서
#       경합이 생길 수 있는데 그 조건은 만들지 않았습니다. 문턱 200건도 하나만 썼습니다."
#
#      쏠린 부하에서만 재면 자동 조절이 실제로 조절을 하는지, 아니면 그냥 항상 늘리는지
#      갈리지 않는다. 고른 부하에서 슬롯을 안 늘려야 조절이라 부를 수 있다.
#      문턱도 여러 값으로 잰다.
#
#   2) 복제 대조를 한 번씩만 쟀습니다
#      6절의 0.53초와 41.83초는 각각 1회다. 반복한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
REPEAT=${REPEAT:-3}

M(){ docker exec r13-mysql mysql -uroot -plab spoon -N -B -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }

{
echo "# 고른 부하에서의 자동 슬롯, 문턱 스윕, 복제 대조 반복"
echo "# 각 조건 1회 실행이고 복제 대조만 ${REPEAT}회입니다."
echo

# ── 1) 고른 부하 대 쏠린 부하 ───────────────────────────────────────────
echo "=================================================================="
echo "## 1) 자동 슬롯이 고른 부하에서도 슬롯을 늘리는가"
echo "=================================================================="
echo "  같은 자동 슬롯 설정에 시나리오만 바꿔 넣습니다."
echo "  zipf 는 소수 방송에 쏠리고 uniform 은 1,000개에 고르게 퍼집니다."
echo
: > "$OUT/uniform-vs-zipf.csv"
echo "scenario,threshold,rows,live_rows,tps,p95_ms" >> "$OUT/uniform-vs-zipf.csv"

# run.sh 의 인자 순서는 <MODE> <SLOTS> <SCENARIO> <LABEL> 이다.
for scen in zipf uniform; do
  for th in 50 200 1000; do
    label="auto-${scen}-th${th}"
    echo "### ${scen} 부하, 문턱 ${th}건"
    AUTO_STEP="$th" bash "$ROOT/scripts/run.sh" slot-auto 64 "$scen" "$label" \
      > "$OUT/${label}-run.log" 2>&1 || { echo "  실행 실패"; continue; }
    # 판정은 /verify 가 돌려주는 슬롯 히스토그램으로 한다. 방송마다 실제로 몇 개를
    # 배정받았는지가 여기 들어 있다. 슬롯 테이블의 행 수만 세면 과거 실행의 잔재가 섞인다.
    VER="$OUT/${SCEN_DIR:-$scen}/${label}.verify.json"
    [ -f "$VER" ] || VER=$(ls "$ROOT/results"/*/"${label}.verify.json" 2>/dev/null | head -1)
    read -r ROWS LIVES MAXS < <(python3 - "${VER:-}" <<'PY2'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    h = d.get("slot_histogram") or {}
    lives = sum(int(v) for v in h.values())
    rows = sum(int(k) * int(v) for k, v in h.items())
    maxs = max((int(k) for k in h), default=0)
    print(rows, lives, maxs)
except Exception:
    print(0, 0, 0)
PY2
)
    TPS=$(grep -oE 'http_reqs[^ ]*[ ]+[0-9]+[^0-9]+([0-9.]+)/s' "$OUT/${label}-run.log" 2>/dev/null \
          | grep -oE '[0-9.]+/s' | head -1 | tr -d '/s')
    P95=$(grep -oE 'p\(95\)=[0-9.]+' "$OUT/${label}-run.log" 2>/dev/null | head -1 | cut -d= -f2)
    printf "  배정된 슬롯 합 %7s개 (방송 %5s개, 최대 %3s개/방송), tps %8s, p95 %8s\n" \
      "${ROWS:-?}" "${LIVES:-?}" "${MAXS:-?}" "${TPS:-?}" "${P95:-?}"
    echo "$scen,$th,${ROWS:-0},${LIVES:-0},${TPS:-},${P95:-}" >> "$OUT/uniform-vs-zipf.csv"
  done
  echo
done

python3 - "$OUT/uniform-vs-zipf.csv" <<'PY'
import csv, sys, collections
rows = collections.defaultdict(dict)
for r in csv.DictReader(open(sys.argv[1])):
    rows[r['threshold']][r['scenario']] = r
print(f"  {'문턱':>6} {'zipf 슬롯행':>13} {'uniform 슬롯행':>16} {'비율':>8}")
for th in sorted(rows, key=int):
    z = rows[th].get('zipf'); u = rows[th].get('uniform')
    if not z or not u: continue
    zr, ur = int(z['rows']), int(u['rows'])
    print(f"  {th:>6} {zr:>13,} {ur:>16,} {(ur/zr if zr else 0):>7.2f}배")
print()
print("  uniform 쪽 슬롯 행이 zipf 쪽보다 훨씬 적어야 '조절'입니다.")
print("  비슷하거나 더 많으면 문턱이 쏠림을 못 가리고 그냥 요청 수만 보고 있는 것입니다.")
print("  문턱을 올릴수록 두 조건 다 슬롯이 줄어야 하고, 그 감소폭이 문턱의 값어치입니다.")
PY
echo

# ── 2) 복제 대조 반복 ───────────────────────────────────────────────────
echo "=================================================================="
echo "## 2) 복제 대조를 ${REPEAT}회"
echo "=================================================================="
for run in $(seq 1 "$REPEAT"); do
  echo "### 회차 $run"
  bash "$ROOT/scripts/run-replica.sh" > "$OUT/replica-run${run}.log" 2>&1 || true
done
echo
# 회차 값을 셸 정규식으로 뽑다가 한 건도 못 잡은 적이 있다.
# "single" 과 시간 사이의 (mode=atomic slots=0) 에 숫자가 들어 있어서
# [^0-9]* 가 건너뛰지 못했다. 로그는 멀쩡한데 표만 비었다.
# 절 단위로 읽는 파이썬으로 옮겼고, 남은 로그로 다시 돌릴 수 있다.
python3 "$ROOT/scripts/summarize-replica-repeat.py" "$OUT"/replica-run*.log
echo
echo "  각 조건 1회 실행이고 복제 대조만 ${REPEAT}회입니다."
} 2>&1 | tee "$OUT/exp-uniform-and-repeat.txt"
