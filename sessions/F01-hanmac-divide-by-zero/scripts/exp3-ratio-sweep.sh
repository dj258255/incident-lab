#!/usr/bin/env bash
# 비정상 비율을 바꿔 가며 킬스위치 임계값의 부수 피해를 잰다.
# 7절의 배치는 정상 100 대 비정상 20 하나였다. 임계값 3건이 만드는 부수 피해가
# 그 비율에 매여 있는지, 비율이 바뀌면 어떻게 되는지가 질문이다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
python3 - "$OUT" <<'PY' 2>&1 | tee "$OUT/exp3-ratio-sweep.txt"
import sys, csv, math, random
out = sys.argv[1]
NORMAL = 100
THRESHOLD = 3          # 연속 비정상 N 건이면 킬스위치
RATIOS = [0, 1, 2, 5, 10, 20, 50, 100, 200]
ROUNDS = 200           # 같은 비율에서 순서를 섞어 여러 번

def run(bad_n, seed):
    rnd = random.Random(seed)
    orders = [('good', 1)] * NORMAL + [('bad', float('inf'))] * bad_n
    rnd.shuffle(orders)
    streak = 0; killed_at = None
    for i, (kind, _) in enumerate(orders):
        if kind == 'bad':
            streak += 1
            if streak >= THRESHOLD and killed_at is None:
                killed_at = i + 1; break
        else:
            streak = 0
    if killed_at is None:
        return None, sum(1 for k,_ in orders if k=='bad'), 0
    stopped = len(orders) - killed_at
    blocked_good = sum(1 for k,_ in orders[killed_at:] if k=='good')
    leaked_bad   = sum(1 for k,_ in orders[:killed_at] if k=='bad')
    return killed_at, leaked_bad, blocked_good

print("# 비정상 비율에 따른 킬스위치의 부수 피해")
print(f"# 정상 {NORMAL}건 고정, 임계 연속 {THRESHOLD}건, 비율마다 순서를 {ROUNDS}회 섞음")
print()
print(f"  {'비정상':>6} {'비율':>7} {'발동률':>7} {'(회차)':>10} {'통과한 비정상':>11} {'막힌 정상':>10}")
rows=[]
for bad in RATIOS:
    fired=0; leaks=[]; blocks=[]
    for s in range(ROUNDS):
        k, leak, block = run(bad, s)
        if k is not None:
            fired += 1; leaks.append(leak); blocks.append(block)
    # 정수 나눗셈은 200회 중 1회를 0%로 깎는다. 그러면 "발동률 0%인데 통과 3건"이
    # 나와서 앞뒤가 안 맞는 표가 된다. 회차 수를 그대로 함께 적는다.
    rate = fired*100/ROUNDS
    ml = sum(leaks)/len(leaks) if leaks else 0
    mb = sum(blocks)/len(blocks) if blocks else 0
    pct = bad*100/(NORMAL+bad) if (NORMAL+bad) else 0
    print(f"  {bad:>6} {pct:>6.1f}% {rate:>6.1f}% ({fired:>3}/{ROUNDS}) {ml:>11.1f} {mb:>10.1f}")
    rows.append((bad, round(pct,1), round(rate,1), fired, round(ml,1), round(mb,1)))
with open(f"{out}/ratio-sweep.csv","w",newline='',encoding='utf-8') as f:
    w=csv.writer(f); w.writerow(["bad_orders","bad_pct","fire_rate_pct","fired_rounds","leaked_bad_avg","blocked_good_avg"]); w.writerows(rows)
print()
print("  발동률이 100%가 아닌 구간에서는 킬스위치가 아예 안 걸리고 비정상이 전부 통과합니다.")
print("  발동해도 임계 직전까지의 비정상은 이미 나갑니다. 그 수가 통과한 비정상 열입니다.")
print("  막힌 정상은 킬스위치가 부수 피해로 세우는 정상 주문 수입니다.")
PY
