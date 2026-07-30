#!/usr/bin/env python3
"""results/에서 증거 이미지를 만든다.

손으로 만든 이미지는 다시 만들 수 없고, 다시 만들 수 없는 이미지는 증거가 아니다.
그래서 이 스크립트는 results/ 아래 실측 파일만 읽는다. 측정이 바뀌면 다시 돌린다.

  사용법: python3 scripts/report.py
"""
import csv
import json
import os

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


def load(label):
    rows = []
    with open(f"{OUT}/{label}-req.csv") as f:
        for r in csv.DictReader(f):
            if r["ms"].lstrip("-").isdigit():
                rows.append((int(r["ms"]), r["status"]))
    ms = sorted(v for v, _ in rows)
    ok = sum(1 for _, s in rows if s == "ok")
    fail = len(rows) - ok
    slow = [v for v in ms if v > 1000]
    with open(f"{OUT}/{label}-final.json") as f:
        fin = json.load(f)
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
    d = {k: load(k) for k, _ in CONDS}
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
        ax.text(max(v, 0.05) * 1.25, i, f"{v:,.1f}", va="center", fontsize=9, color=T)
    ax.set_xscale("log")
    ax.set_xlim(0.1, max(vals) * 12)
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
        ax.text(max(v, 0) + max(vals) * 0.02, i, f"{v:.1f}%  ({d[keys[i]]['fail']}건)",
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
        ax.text(max(v, 0) + 2, i, f"{v:.1f}%  ({d[keys[i]]['slow_n']}건)",
                va="center", fontsize=9, color=T)
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

    fig.suptitle(f"동시 요청 {WORKERS}, 각 {DURATION}초 · MySQL 8.4.3 · Spring Boot 3.4.1 (Hibernate 6)",
                 color=M, fontsize=9.5, x=0.13, ha="left", y=0.93)
    p = f"{OUT}/chart-pool.png"
    fig.savefig(p, dpi=160, facecolor=S)
    print("wrote", p)

    for k, _ in CONDS:
        v = d[k]
        print(f"  {k:8} tps={v['tps']:8.1f} 실패={v['fail']:3}/{v['total']:5} "
              f"p50={v['p50']:6}ms p95={v['p95']:6}ms 최대={v['max']:6}ms "
              f"1초초과={v['slow_n']:3}건({v['slow_share']:.1f}%) 풀={v['pool']} DB커넥션={v['db']}")


if __name__ == "__main__":
    main()
