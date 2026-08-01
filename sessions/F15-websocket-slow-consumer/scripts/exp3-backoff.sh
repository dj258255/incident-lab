#!/usr/bin/env bash
# 여러 구독자가 동시에 끊겼을 때 백오프 전략이 재접속 폭풍을 얼마나 줄이는가.
# 본문은 느린 구독자 한 명으로만 봤고 백오프 전략별 비교는 재지 않았다고 적었다.
# 서버가 감당할 수 있는 동시 수락 수를 넘는 재접속이 얼마나 몰리는지를 센다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
python3 - "$OUT" <<'PY' 2>&1 | tee "$OUT/exp3-backoff.txt"
import sys, csv, random, statistics as st
out = sys.argv[1]
CLIENTS = 500          # 동시에 끊긴 구독자
CAPACITY = 40          # 서버가 한 틱에 수락할 수 있는 수
TICKS = 300            # 관측 틱(각 틱 = 100ms 로 본다)
TRIALS = 50

def simulate(strategy, seed):
    rnd = random.Random(seed)
    # 각 클라이언트의 다음 시도 시각과 시도 횟수
    nxt = [0]*CLIENTS; tries=[0]*CLIENTS; done=[False]*CLIENTS
    peak = 0; rejected = 0; connected = 0
    for t in range(TICKS):
        want = [i for i in range(CLIENTS) if not done[i] and nxt[i] <= t]
        peak = max(peak, len(want))
        accept = want[:CAPACITY]
        for i in accept:
            done[i] = True; connected += 1
        for i in want[CAPACITY:]:
            rejected += 1; tries[i] += 1
            n = tries[i]
            if strategy == 'none':          delay = 1
            elif strategy == 'fixed':       delay = 10
            elif strategy == 'exp':         delay = min(2**n, 64)
            elif strategy == 'exp_jitter':  delay = rnd.randint(1, min(2**n, 64))
            nxt[i] = t + delay
        if all(done): break
    settle = t
    return peak, rejected, connected, settle

print("# 재접속 백오프 전략 비교")
print(f"# 동시에 끊긴 구독자 {CLIENTS}명, 서버가 한 틱에 받는 수 {CAPACITY}, {TRIALS}회 평균")
print()
print(f"  {'전략':<14} {'동시 시도 최대':>14} {'거절 누적':>12} {'전원 복귀 틱':>14} {'복귀율':>8}")
rows=[]
for s,ko in (('none','백오프 없음'),('fixed','고정 지연'),('exp','지수 백오프'),('exp_jitter','지수+지터')):
    P=[];R=[];S=[];C=[]
    for k in range(TRIALS):
        p,r,c,se = simulate(s,k)
        P.append(p);R.append(r);S.append(se);C.append(c)
    rate = st.mean(C)*100/CLIENTS
    print(f"  {ko:<14} {st.mean(P):>14.0f} {st.mean(R):>12.0f} {st.mean(S):>14.0f} {rate:>7.1f}%")
    rows.append((s, round(st.mean(P)), round(st.mean(R)), round(st.mean(S)), round(rate,1)))
with open(f"{out}/backoff.csv","w",newline='',encoding='utf-8') as f:
    w=csv.writer(f); w.writerow(["strategy","peak_concurrent_attempts","rejected_total","settle_tick","reconnect_rate_pct"]); w.writerows(rows)
print()
print("  동시 시도 최대가 서버 수락 능력보다 크면 그 차이가 그대로 거절이 됩니다.")
print("  지터가 없는 지수 백오프는 같은 시각에 재시도가 다시 몰립니다(동기화).")
PY
