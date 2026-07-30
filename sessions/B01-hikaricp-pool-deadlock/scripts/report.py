#!/usr/bin/env python3
"""results/에서 증거 이미지를 만든다.

손으로 만든 이미지는 다시 만들 수 없고, 다시 만들 수 없는 이미지는 증거가 아니다.
그래서 이 스크립트는 results/ 아래 실측 파일만 읽는다. 측정이 바뀌면 다시 돌린다.

  사용법: python3 scripts/report.py
"""
import csv
import json
import os

import statistics

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "results")
S, T, M, G = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
BAD, GOOD, WARN = "#d03b3b", "#1baf7a", "#c98a1e"

CONDS = [
    ("two-10", "커넥션 2개 요구\n풀 10"),
    ("jpa-10", "JPA save()\n풀 10 (원 사례)"),
    ("jpa-24", "JPA save()\n풀 24 (해소책)"),
    ("one-10", "동시 보유 1개\n풀 10"),
]
DURATION = 40
WORKERS = 16


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


def runs(label):
    """회차별 파일을 모두 찾는다. run0은 발행에 쓴 첫 측정(git에서 복구)이다.

    회차마다 한 번씩만 재고 결론을 내면 방향까지 틀릴 수 있다는 것이 이 저장소의
    반복된 교훈이라(CONVENTIONS 11절), 여기서는 중앙값과 min~max를 함께 그린다.
    """
    import glob
    paths = sorted(glob.glob(f"{OUT}/run*-{label}-req.csv"))
    return paths or [f"{OUT}/{label}-req.csv"]


def load(label, path=None):
    rows = []
    with open(path or f"{OUT}/{label}-req.csv") as f:
        for r in csv.DictReader(f):
            if r["ms"].lstrip("-").isdigit():
                rows.append((int(r["ms"]), r["status"]))
    ms = sorted(v for v, _ in rows)
    ok = sum(1 for _, s in rows if s == "ok")
    fail = len(rows) - ok
    slow = [v for v in ms if v > 1000]
    try:
        with open(f"{OUT}/{label}-final.json") as f:
            fin = json.load(f)
    except FileNotFoundError:
        fin = {"total": 0, "db_threads_connected": 0}
    return {
        "ok": ok, "fail": fail, "total": len(rows),
        "tps": ok / DURATION,
        "p50": ms[len(ms) // 2], "p95": ms[int(len(ms) * 0.95)], "max": ms[-1],
        "slow_n": len(slow),
        "slow_share": sum(slow) / sum(ms) * 100 if ms else 0,
        "pool": fin["total"], "db": fin["db_threads_connected"],
    }


def main():
    plt = font()
    # 조건별로 회차 전체를 읽고, 그리기에는 중앙값을 쓰고 범위를 따로 남긴다.
    allruns = {k: [load(k, p) for p in runs(k)] for k, _ in CONDS}
    def med(k, field):
        return statistics.median([r[field] for r in allruns[k]])
    def rng(k, field):
        v = [r[field] for r in allruns[k]]
        return min(v), max(v)
    d = {k: {f: med(k, f) for f in ("ok","fail","total","tps","p50","p95","max","slow_n","slow_share")}
         for k, _ in CONDS}
    for k, _ in CONDS:
        d[k]["pool"] = allruns[k][0]["pool"]; d[k]["db"] = allruns[k][0]["db"]
        d[k]["n"] = len(allruns[k])
    labels = [lab for _, lab in CONDS]
    keys = [k for k, _ in CONDS]
    y = np.arange(len(keys))

    fig, axes = plt.subplots(1, 3, figsize=(14.5, 4.2), facecolor=S)
    fig.subplots_adjust(wspace=0.55, left=0.13, right=0.98, top=0.72, bottom=0.16)

    # 1) 처리량. 로그 축이 아니면 two-10의 0.3이 보이지 않는다.
    ax = axes[0]
    vals = [d[k]["tps"] for k in keys]
    cols = [BAD if d[k]["fail"] else GOOD for k in keys]
    ax.barh(y, [max(v, 0.05) for v in vals], height=0.55, color=cols)
    for i, v in enumerate(vals):
        t0, t1 = rng(keys[i], "tps")
        lab = f"{v:,.1f}" if abs(t1 - t0) < 0.05 else f"{v:,.1f}  ({t0:,.1f}~{t1:,.1f})"
        ax.text(max(v, 0.05) * 1.25, i, lab, va="center", fontsize=8.5, color=T)
    ax.set_xscale("log")
    ax.set_xlim(0.1, max(vals) * 90)
    # 로그 포매터의 음수 지수가 기본 폰트에서 깨지므로 눈금을 직접 준다.
    ax.set_xticks([0.1, 1, 10, 100, 1000])
    ax.set_xticklabels(["0.1", "1", "10", "100", "1000"])
    ax.set_yticks(y); ax.set_yticklabels(labels, fontsize=8.5)
    ax.set_xlabel("성공 요청 초당 처리량 · 로그 축", color=M, fontsize=9)
    ax.set_title("처리량", color=T, fontsize=11, fontweight="bold", loc="left", pad=10)

    # 2) 실패율. 여기만 보면 jpa-10이 정상으로 보인다는 것이 요점이다.
    ax = axes[1]
    vals = [d[k]["fail"] / d[k]["total"] * 100 for k in keys]
    ax.barh(y, vals, height=0.55, color=[BAD if v else GOOD for v in vals])
    for i, v in enumerate(vals):
        f0, f1 = rng(keys[i], "fail")
        lab = f"{f0:.0f}건" if f0 == f1 else f"{f0:.0f}~{f1:.0f}건"
        ax.text(max(v, 0) + max(vals) * 0.02, i, f"{v:.1f}%  ({lab})",
                va="center", fontsize=9, color=T)
    ax.set_xlim(0, max(vals) * 1.55)
    ax.set_yticks(y); ax.set_yticklabels([])
    ax.set_xticks([0, 20, 40, 60, 80, 100])
    ax.set_xticklabels(["0", "20%", "40%", "60%", "80%", "100%"])
    ax.set_xlabel("요청 실패율", color=M, fontsize=9)
    ax.set_title("실패율", color=T, fontsize=11, fontweight="bold", loc="left", pad=10)

    # 3) 1초 초과 요청이 먹은 워커 시간 비중. 실패율과 대비된다.
    ax = axes[2]
    vals = [d[k]["slow_share"] for k in keys]
    ax.barh(y, vals, height=0.55, color=[BAD if v > 50 else (WARN if v > 0 else GOOD) for v in vals])
    for i, v in enumerate(vals):
        s0, s1 = rng(keys[i], "slow_n")
        lab = f"{s0:.0f}건" if s0 == s1 else f"{s0:.0f}~{s1:.0f}건"
        ax.text(max(v, 0) + 2, i, f"{v:.1f}%  ({lab})", va="center", fontsize=9, color=T)
    ax.set_xlim(0, 128)
    ax.set_xticks([0, 20, 40, 60, 80, 100])
    ax.set_xticklabels(["0", "20%", "40%", "60%", "80%", "100%"])
    ax.set_yticks(y); ax.set_yticklabels([])
    ax.set_xlabel("1초 초과 요청이 차지한 워커 시간 비중", color=M, fontsize=9)
    ax.set_title("소수의 느린 요청이 먹은 시간", color=T, fontsize=11,
                 fontweight="bold", loc="left", pad=10)

    for ax in axes:
        ax.set_facecolor(S)
        ax.grid(axis="x", color=G, lw=0.7)
        ax.set_axisbelow(True)
        for sp in ("top", "right", "left"):
            ax.spines[sp].set_visible(False)
        ax.spines["bottom"].set_color(G)
        ax.tick_params(colors=M, labelsize=8.5, length=0)

    n = d[CONDS[0][0]]["n"]
    fig.suptitle(f"동시 요청 {WORKERS}, 각 {DURATION}초, {n}회 반복의 중앙값 · MySQL 8.4.3 · Spring Boot 3.4.1 (Hibernate 6)",
                 color=M, fontsize=9.5, x=0.13, ha="left", y=0.93)
    p = f"{OUT}/chart-pool.png"
    fig.savefig(p, dpi=160, facecolor=S)
    print("wrote", p)

    for k, _ in CONDS:
        v = d[k]
        t0, t1 = rng(k, "tps"); f0, f1 = rng(k, "fail"); s0, s1 = rng(k, "slow_share")
        print(f"  {k:8} n={v['n']} tps중앙={v['tps']:7.1f} (범위 {t0:.1f}~{t1:.1f})  "
              f"실패 {f0:.0f}~{f1:.0f}  1초초과={v['slow_n']:.0f}건  워커시간 {s0:.1f}~{s1:.1f}%  풀={v['pool']}")


if __name__ == "__main__":
    main()
