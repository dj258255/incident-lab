#!/usr/bin/env bash
# README 의 "못 한 것" 하나를 잡는다.
#
#   구독자 수를 늘려 보지 않았습니다
#   "정상 5명 + 느린 1명 한 가지 구성입니다. 느린 구독자 비율이 올라가면 결과가
#    달라질 수 있습니다."
#
# 느린 구독자가 하나일 때의 결과를 여럿일 때로 일반화할 수 있는지가 질문이다.
# 세 가지가 갈릴 수 있다.
#   1) 힙 소진이 빨라지는가        (unbounded 는 느린 구독자마다 큐를 하나씩 만든다)
#   2) 정상 구독자의 지연이 나빠지는가 (direct 는 한 스레드가 순서대로 쓴다)
#   3) 절단이 여전히 통하는가       (terminate 는 넘친 구독자만 끊는다)
#
# 모드 셋 × 느린 구독자 1·2·4 명. 회차는 1 회다(모드 하나에 45~110초).
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="results"; mkdir -p "$OUT"

SLOWS=${SLOWS:-"1 2 4"}
SWEEP_MODES=${SWEEP_MODES:-"direct unbounded terminate"}
NORMAL=${NORMAL:-5}

{
echo "# 느린 구독자 수를 늘리면"
echo "# 모드 ${SWEEP_MODES}, 느린 구독자 ${SLOWS}, 정상 ${NORMAL}명 고정, 각 1회 실행"
echo

for n in $SLOWS; do
  for m in $SWEEP_MODES; do
    echo "=================================================================="
    echo "## ${m}, 느린 구독자 ${n}명"
    echo "=================================================================="
    SLOW="$n" LABEL_SUFFIX="-s${n}" MODES="$m" RUNS=1 NORMAL="$NORMAL" \
      bash scripts/run-suite.sh 2>&1 | grep -E "SUMMARY|Exception|OutOfMemory|=== " | sed 's/^/  /'
    echo
  done
done

echo "=================================================================="
echo "## 정리"
echo "=================================================================="
python3 - "$OUT/raw" <<'PY'
import glob, os, re, sys

raw = sys.argv[1]
rows = []
for f in sorted(glob.glob(os.path.join(raw, "client-*-s*-r1.txt"))):
    txt = open(f, encoding='utf-8', errors='replace').read()
    m = re.search(r"^SUMMARY (.+)$", txt, re.M)
    if not m:
        continue
    kv = dict(p.split("=", 1) for p in m.group(1).split() if "=" in p)
    base = os.path.basename(f)
    ms = re.match(r"client-(.+)-s(\d+)-r1\.txt", base)
    if not ms:
        continue
    rows.append({"mode": ms.group(1), "slow": int(ms.group(2)), **kv})

if not rows:
    print("  요약 줄을 못 찾았습니다. results/raw 의 client-*.txt 를 직접 봐야 합니다.")
else:
    print(f"  {'모드':<12} {'느린':>4} {'정상 p95':>10} {'정상 max':>10} "
          f"{'수신 합':>10} {'절단':>6} {'느린 읽기':>12}")
    for r in sorted(rows, key=lambda x: (x["mode"], x["slow"])):
        print(f"  {r['mode']:<12} {r['slow']:>4} "
              f"{float(r.get('lat_p95_ms', 0)):>9.0f}ms {float(r.get('lat_max_ms', 0)):>9.0f}ms "
              f"{int(r.get('recv_total', 0)):>10,} {r.get('slow_closed_n', '?'):>6} "
              f"{int(r.get('slow_read_bytes', 0))/1024:>10.0f}KB")
    print()
    print("  정상 구독자의 지연이 느린 구독자 수에 따라 어떻게 가는지가 이 표의 요지입니다.")
    print("  direct 는 한 스레드가 순서대로 쓰므로 느린 쪽이 늘수록 나빠져야 하고,")
    print("  terminate 는 넘친 구독자만 끊으므로 정상 쪽이 거의 그대로여야 합니다.")
PY
echo
echo "  각 조건 1회 실행입니다."
} 2>&1 | tee "$OUT/exp-slow-count-sweep.txt"
