#!/usr/bin/env python3
"""bench.json에서 차트와 증거 카드를 만든다. 손으로 만든 이미지를 두지 않기 위해 스크립트로 고정한다."""
import json
import os
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "results")
S, T, M, G = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
BAD, GOOD = "#d03b3b", "#1baf7a"


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


def chart(d):
    plt = font()
    labels = [c["ko"] for c in d][::-1]
    bad = [c["bad"]["med_ms"] for c in d][::-1]
    good = [c["good"]["med_ms"] for c in d][::-1]
    bs = [max(c["bad"]["rows_scanned"], 1) for c in d][::-1]
    gs = [max(c["good"]["rows_scanned"], 1) for c in d][::-1]
    y = np.arange(len(labels))

    fig, axes = plt.subplots(1, 2, figsize=(13, 4.3), facecolor=S)
    fig.subplots_adjust(wspace=0.42, left=0.17, right=0.97, top=0.74, bottom=0.15)
    for ax, hi, lo, xl, title, fmt in (
        (axes[0], bad, good, "응답 시간 중앙값 (ms) · 로그 축", "응답 시간", "ms"),
        (axes[1], bs, gs, "실제로 읽은 행 수 · 로그 축 (Handler_read)", "읽은 행 수", "rows"),
    ):
        ax.barh(y + 0.19, hi, height=0.36, color=BAD)
        ax.barh(y - 0.19, lo, height=0.36, color=GOOD)
        ax.set_yticks(y)
        ax.set_yticklabels(labels if ax is axes[0] else [])
        ax.set_xscale("log")
        for i, (h, l) in enumerate(zip(hi, lo)):
            fh = f"{h:,.0f}ms" if fmt == "ms" else f"{h:,.0f}"
            fl = (f"{l:.2f}ms" if l < 10 else f"{l:,.0f}ms") if fmt == "ms" else (f"{l:,.0f}" if l > 1 else "0")
            ax.text(h * 1.2, i + 0.19, fh, va="center", fontsize=8.5, color=T)
            ax.text(l * 1.2, i - 0.19, fl, va="center", fontsize=8.5, color=T)
        ax.set_xlim(min(min(lo), 0.3) * 0.5, max(hi) * (14 if fmt == "ms" else 40))
        ax.set_xlabel(xl, color=M, fontsize=9)
        ax.set_title(title, color=T, fontsize=11, fontweight="bold", loc="left", pad=10)
        ax.set_facecolor(S)
        for s in ("top", "right", "left"):
            ax.spines[s].set_visible(False)
        ax.spines["bottom"].set_color(G)
        ax.tick_params(colors=M, labelsize=9, length=0)
        ax.xaxis.grid(True, color=G, lw=0.8)
        ax.set_axisbelow(True)

    # 범례는 축 밖 상단에 둔다. 안에 두면 마지막 막대 라벨과 겹친다.
    from matplotlib.patches import Patch
    leg = fig.legend(handles=[Patch(color=BAD, label="인덱스를 못 탈 때"),
                              Patch(color=GOOD, label="탈 때")],
                     fontsize=9, frameon=False, ncols=2, loc="upper right",
                     bbox_to_anchor=(0.97, 0.995))
    for t in leg.get_texts():
        t.set_color(T)
    fig.suptitle("인덱스는 그대로 두고 쿼리만 고쳤을 때  ·  주문 300만 행, 워밍업 후 10회 중앙값",
                 color=T, fontsize=12.5, fontweight="bold", x=0.014, ha="left", y=0.95)
    out = os.path.join(OUT, "chart-index.png")
    fig.savefig(out, dpi=160, facecolor=S)
    return out


def card(d):
    sys.path.insert(0, os.path.join(ROOT, "..", "R13-slotted-counter", "scripts"))
    from termshot import render
    lines = []
    for c in d:
        b, g = c["bad"], c["good"]
        lines.append(f"### {c['ko']}")
        for side, tag in ((b, "못 탐"), (g, "탐  ")):
            lines.append(f"$ EXPLAIN {side['sql'][:86]}")
            lines.append(f"    type={side['type']:<8} key={str(side['key']):<15} "
                         f"rows={side['est_rows']:<9} {str(side['extra'])[:38]}")
            lines.append(f"    [{tag}] {side['med_ms']:.2f}ms · 실제로 읽은 행 {side['rows_scanned']:,}")
        lines.append(f"    → {c['speedup']:.0f}배")
        lines.append("")
    out = os.path.join(OUT, "fig-explain.png")
    render(out, "EXPLAIN 전후: 같은 질문, 다른 실행계획", "\n".join(lines).rstrip(),
           ["ALL", "배", "실제로 읽은 행"])
    return out


if __name__ == "__main__":
    d = json.load(open(os.path.join(OUT, "bench.json")))
    print(f"{'케이스':<18}{'못 탈 때':>12}{'탈 때':>12}{'배수':>8}{'읽은 행(전)':>14}{'읽은 행(후)':>13}")
    print("-" * 78)
    for c in d:
        print(f"{c['ko']:<18}{c['bad']['med_ms']:>10.1f}ms{c['good']['med_ms']:>10.2f}ms"
              f"{c['speedup']:>7.0f}배{c['bad']['rows_scanned']:>14,}{c['good']['rows_scanned']:>13,}")
    print("저장:", chart(d))
    print("저장:", card(d))
