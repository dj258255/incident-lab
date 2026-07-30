#!/usr/bin/env python3
"""results/에서 증거 이미지를 만든다.

손으로 만든 이미지는 다시 만들 수 없고, 다시 만들 수 없는 이미지는 증거가 아니다.
그래서 이 스크립트는 results/ 아래 pgbench 출력과 SLRU 카운터 파일만 읽는다.

  사용법: python3 scripts/report.py
"""
import glob
import os
import re
import statistics

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "results")
S, T, M, G = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
BAD, GOOD, WARN = "#d03b3b", "#1baf7a", "#c98a1e"

CONDS = [
    ("none", "0", "256kB", "서브트랜잭션 없음"),
    ("sub64", "64", "256kB", "64개\n캐시 한도 이내"),
    ("sub10k", "10,000", "256kB", "1만 개\n캐시 초과, SLRU 안"),
    ("sub500k", "500,000", "256kB", "50만 개\nSLRU 페이지 초과"),
    ("sub500k-buf", "500,000", "4MB", "50만 개\nSLRU 확대(해소)"),
]


def font():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import font_manager
    for c in ["AppleSDGothicNeo", "Apple SD Gothic Neo", "NanumGothic"]:
        if any(c in f.name for f in font_manager.fontManager.ttflist):
            plt.rcParams["font.family"] = c
            break
    plt.rcParams["axes.unicode_minus"] = False
    return plt


def rounds(label):
    """회차별 파일을 찾는다. run0은 발행에 쓴 첫 측정이다.

    회차마다 한 번씩만 재고 결론을 내면 방향까지 틀릴 수 있다는 것이 이 저장소의
    반복된 교훈이라(CONVENTIONS 11절), 중앙값과 min~max를 함께 낸다.
    """
    pres = sorted({os.path.basename(p).split(label)[0]
                   for p in glob.glob(f"{OUT}/run*-{label}-reader.txt")})
    return pres or [""]


def load(label, pre=""):
    txt = open(f"{OUT}/{pre}{label}-reader.txt").read()
    tps = float(re.search(r"^tps = ([\d.]+)", txt, re.M).group(1))
    lat = float(re.search(r"^latency average = ([\d.]+)", txt, re.M).group(1))
    hit, read = (int(x) for x in open(f"{OUT}/{pre}{label}-slru.txt").read().split())
    waits = open(f"{OUT}/{pre}{label}-waits.txt").read().splitlines()
    slru = sum(1 for w in waits if "SubtransSLRU" in w)
    return {"tps": tps, "lat": lat, "hit": hit, "read": read,
            "lookups": hit + read,
            "miss_pct": read / (hit + read) * 100 if hit + read else 0.0,
            "slru_wait": slru, "waits": len(waits),
            "wait_pct": slru / len(waits) * 100 if waits else 0.0}


def main():
    plt = font()
    allr = {k: [load(k, p) for p in rounds(k)] for k, _, _, _ in CONDS}
    # run1~3의 waits 파일은 회차마다 누적됐다(스크립트가 초기화하지 않았다. 지금은 고쳤다).
    # 회차별 비중을 보려면 차분해야 한다. 그러지 않으면 뒤 회차가 앞 회차에 희석된다.
    for k, _, _, _ in CONDS:
        pt = ps = 0
        for r in allr[k]:
            dt, ds = r["waits"] - pt, r["slru_wait"] - ps
            pt, ps = r["waits"], r["slru_wait"]
            if dt > 0:
                r["waits"], r["slru_wait"] = dt, ds
                r["wait_pct"] = ds / dt * 100
    def rng(k, f):
        v = [r[f] for r in allr[k]]; return min(v), max(v)
    d = {k: {f: statistics.median([r[f] for r in allr[k]])
             for f in ("tps","lat","hit","read","lookups","miss_pct","slru_wait","waits","wait_pct")}
         for k, _, _, _ in CONDS}
    for k, _, _, _ in CONDS:
        d[k]["n"] = len(allr[k])
    keys = [k for k, _, _, _ in CONDS]
    labels = [lab for _, _, _, lab in CONDS]
    base = d["none"]["tps"]
    y = np.arange(len(keys))

    fig, axes = plt.subplots(1, 3, figsize=(15, 4.4), facecolor=S)
    fig.subplots_adjust(wspace=0.5, left=0.135, right=0.98, top=0.71, bottom=0.16)

    # 1) 처리량. 기준선 대비 비율을 함께 적는다.
    ax = axes[0]
    vals = [d[k]["tps"] for k in keys]
    cols = [BAD if v < base * 0.8 else GOOD for v in vals]
    ax.barh(y, vals, height=0.55, color=cols)
    for i, v in enumerate(vals):
        # 기준선 대비는 회차마다 따로 계산해야 한다. 중앙값끼리 나누면 회차가 섞인다.
        ratios = [a["tps"] / b["tps"] * 100 for a, b in zip(allr[keys[i]], allr["none"])]
        r0, r1 = min(ratios), max(ratios)
        pct = f"{r0:.0f}%" if round(r0) == round(r1) else f"{r0:.0f}~{r1:.0f}%"
        ax.text(v + base * 0.02, i, f"{v:,.0f}  ({pct})", va="center", fontsize=8.5, color=T)
    ax.set_xlim(0, base * 1.42)
    ax.set_yticks(y); ax.set_yticklabels(labels, fontsize=8.5)
    ax.set_xlabel("리더 초당 처리량 (괄호는 기준선 대비)", color=M, fontsize=9)
    ax.set_title("처리량", color=T, fontsize=11, fontweight="bold", loc="left", pad=10)

    # 2) 조회 중 빗나간 비율. 로그 축으로 건수를 그리면 761만 건 중 6건이
    #    실제보다 커 보이므로 비율로 그리고 건수는 글로 적는다.
    ax = axes[1]
    vals = [d[k]["miss_pct"] for k in keys]
    ax.barh(y, vals, height=0.55, color=[BAD if v > 1 else GOOD for v in vals])
    for i, k in enumerate(keys):
        lk, ms = d[k]["lookups"], d[k]["read"]
        m0, m1 = rng(k, "read")
        cnt = f"{m0:,.0f}건" if m0 == m1 else f"{m0:,.0f}~{m1:,.0f}건"
        txt = "조회 0건" if lk == 0 else f"{lk / 1e6:.2f}M 조회 중 {cnt}"
        ax.text(vals[i] + 0.8, i, txt, va="center", fontsize=8.5, color=T)
    ax.set_xlim(0, 30)
    ax.set_xticks([0, 10, 20, 30])
    ax.set_xticklabels(["0", "10%", "20%", "30%"])
    ax.set_yticks(y); ax.set_yticklabels([])
    ax.set_xlabel("pg_subtrans 조회가 SLRU 캐시에서 빗나간 비율", color=M, fontsize=9)
    ax.set_title("조회는 64를 넘으면 생기고, 빗나감은 65,536을 넘어야 생긴다",
                 color=T, fontsize=10, fontweight="bold", loc="left", pad=10)

    # 3) 원인 지표. 대기 샘플 중 SubtransSLRU 비중.
    ax = axes[2]
    vals = [d[k]["wait_pct"] for k in keys]
    ax.barh(y, vals, height=0.55, color=[BAD if v > 10 else GOOD for v in vals])
    for i, v in enumerate(vals):
        k = keys[i]
        w0, w1 = rng(k, "wait_pct")
        lab = f"{v:.0f}%" if round(w0) == round(w1) else f"{w0:.0f}~{w1:.0f}%"
        ax.text(v + 1.5, i, lab, va="center", fontsize=9, color=T)
    ax.set_xlim(0, 72)
    ax.set_xticks([0, 20, 40, 60])
    ax.set_xticklabels(["0", "20%", "40%", "60%"])
    ax.set_yticks(y); ax.set_yticklabels([])
    ax.set_xlabel("활성 리더 대기 샘플 중 LWLock/SubtransSLRU 비중", color=M, fontsize=9)
    ax.set_title("원인 지표", color=T, fontsize=11, fontweight="bold", loc="left", pad=10)

    for ax in axes:
        ax.set_facecolor(S)
        ax.grid(axis="x", color=G, lw=0.7)
        ax.set_axisbelow(True)
        for sp in ("top", "right", "left"):
            ax.spines[sp].set_visible(False)
        ax.spines["bottom"].set_color(G)
        ax.tick_params(colors=M, labelsize=8.5, length=0)

    fig.suptitle(f"같은 50만 행을 몇 개의 서브트랜잭션으로 나눌지만 바꿈 · "
                 f"동시 리더 64, 각 20초, {d['none']['n']}회 반복의 중앙값 · PostgreSQL 17.5",
                 color=M, fontsize=9.5, x=0.135, ha="left", y=0.93)
    p = f"{OUT}/chart-slru.png"
    fig.savefig(p, dpi=160, facecolor=S)
    print("wrote", p)

    for k, n, b, _ in CONDS:
        v = d[k]; t0, t1 = rng(k, "tps"); m0, m1 = rng(k, "miss_pct"); w0, w1 = rng(k, "wait_pct")
        ratios = [a["tps"] / c["tps"] * 100 for a, c in zip(allr[k], allr["none"])]
        print(f"  {k:12} n={v['n']} 서브TX={n:>7} 버퍼={b:6} tps중앙={v['tps']:8,.0f} "
              f"({t0:,.0f}~{t1:,.0f})  기준선대비 {min(ratios):3.0f}~{max(ratios):3.0f}%  "
              f"미스율 {m0:4.1f}~{m1:4.1f}%  SubtransSLRU {w0:3.0f}~{w1:3.0f}%")


if __name__ == "__main__":
    main()
