#!/usr/bin/env python3
"""풀 안 커넥션이 세 인스턴스에 어떻게 나뉘는지 시간에 따라 그린다."""
import collections
import csv
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "results")
S, T, M, G = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
COLORS = {"1": "#2a78d6", "2": "#eb6834", "3": "#1baf7a"}
CASES = [("cached", "JVM 캐시 기본값"), ("ttl0", "sun.net.inetaddr.ttl=0")]


def load(label):
    pts = []
    for line in open(f"{OUT}/{label}.jsonl"):
        ts, _, body = line.partition(" ")
        try:
            d = json.loads(body)
        except json.JSONDecodeError:
            continue
        pts.append((float(ts), d["by_server"], d["max_share_pct"], d["pool_size"]))
    return pts


def main():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import font_manager
    import numpy as np
    for c in ["AppleSDGothicNeo", "Apple SD Gothic Neo", "NanumGothic"]:
        if any(c in f.name for f in font_manager.fontManager.ttflist):
            plt.rcParams["font.family"] = c
            break
    plt.rcParams["axes.unicode_minus"] = False

    fig, axes = plt.subplots(1, 2, figsize=(13, 4.0), facecolor=S, sharey=True)
    fig.subplots_adjust(wspace=0.10, left=0.07, right=0.85, top=0.76, bottom=0.15)

    print(f"{'조건':<26}{'최대점유 평균':>13}{'범위':>16}{'마지막 분포':>18}")
    print("-" * 76)
    for ax, (label, ko) in zip(axes, CASES):
        pts = load(label)
        t0 = pts[0][0]
        xs = [p[0] - t0 for p in pts]
        size = pts[0][3]
        series = {sid: [p[1].get(sid, 0) for p in pts] for sid in ("1", "2", "3")}
        ax.stackplot(xs, [series[s] for s in ("1", "2", "3")],
                     colors=[COLORS[s] for s in ("1", "2", "3")],
                     labels=[f"인스턴스 {s}" for s in ("1", "2", "3")], alpha=0.92, lw=0)
        ax.axhline(size / 3, color=T, lw=1.1, ls=(0, (4, 3)))
        shares = [p[2] for p in pts]
        ax.set_title(f"{ko}  ·  최대 점유 평균 {sum(shares)/len(shares):.1f}%",
                     color=T, fontsize=11, fontweight="bold", loc="left", pad=10)
        ax.set_xlabel("경과 시간(초)", color=M, fontsize=9)
        ax.set_facecolor(S)
        for sp in ("top", "right"):
            ax.spines[sp].set_visible(False)
        for sp in ("bottom", "left"):
            ax.spines[sp].set_color(G)
        ax.tick_params(colors=M, labelsize=8.5, length=0)
        ax.grid(True, color=G, lw=0.7, axis="y")
        ax.set_axisbelow(True)
        ax.set_ylim(0, size)
        if ax is axes[0]:
            ax.set_ylabel("커넥션 수 (풀 12개)", color=M, fontsize=9)
        print(f"{ko:<26}{sum(shares)/len(shares):>12.1f}%{f'{min(shares)}~{max(shares)}%':>16}"
              f"{str(pts[-1][1]):>18}")

    h, l = axes[0].get_legend_handles_labels()
    leg = fig.legend(h, l, fontsize=9, frameon=False, loc="center right", bbox_to_anchor=(1.0, 0.5))
    for t in leg.get_texts():
        t.set_color(T)
    axes[1].text(axes[1].get_xlim()[1], 4.3, "균등선 (12/3)  ", ha="right", fontsize=8.5, color=T)
    fig.suptitle("리더 엔드포인트가 돌려줘도 JVM이 붙잡으면 한 대로 몰린다  ·  풀 12, maxLifetime 30초, 3초 간격 관측",
                 color=T, fontsize=12.5, fontweight="bold", x=0.012, ha="left", y=0.95)
    out = f"{OUT}/chart-skew.png"
    fig.savefig(out, dpi=160, facecolor=S)
    print("저장:", out)


if __name__ == "__main__":
    main()
