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
    # 로그 축이라 0을 그릴 수 없어 막대 길이만 1로 올린다. 라벨은 실측값을 그대로 쓴다.
    # (예전에는 라벨도 1로 눌러서, 실제로 1행을 읽은 것을 "0"으로 적었다)
    bs_raw = [c["bad"]["rows_scanned"] for c in d][::-1]
    gs_raw = [c["good"]["rows_scanned"] for c in d][::-1]
    bs = [max(v, 1) for v in bs_raw]
    gs = [max(v, 1) for v in gs_raw]
    y = np.arange(len(labels))

    fig, axes = plt.subplots(1, 2, figsize=(13, 4.3), facecolor=S)
    fig.subplots_adjust(wspace=0.42, left=0.17, right=0.97, top=0.74, bottom=0.15)
    for ax, hi, lo, hi_raw, lo_raw, xl, title, fmt in (
        (axes[0], bad, good, bad, good, "응답 시간 중앙값 (ms) · 로그 축", "응답 시간", "ms"),
        (axes[1], bs, gs, bs_raw, gs_raw,
         "실제로 읽은 행 수 · 로그 축 (Handler_read)", "읽은 행 수", "rows"),
    ):
        ax.barh(y + 0.19, hi, height=0.36, color=BAD)
        ax.barh(y - 0.19, lo, height=0.36, color=GOOD)
        ax.set_yticks(y)
        ax.set_yticklabels(labels if ax is axes[0] else [])
        ax.set_xscale("log")
        for i, (h, l, hr, lr) in enumerate(zip(hi, lo, hi_raw, lo_raw)):
            fh = f"{hr:,.0f}ms" if fmt == "ms" else f"{hr:,.0f}"
            fl = (f"{lr:.2f}ms" if lr < 10 else f"{lr:,.0f}ms") if fmt == "ms" else f"{lr:,.0f}"
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
    # 예전 제목은 "인덱스는 그대로 두고 쿼리만 고쳤을 때"였는데, 다섯 중 셋은 스키마도 바꿨다.
    # 그림이 본문을 반박하지 않도록 제목을 실제로 한 일에 맞춘다.
    fig.suptitle("같은 질문을 인덱스를 못 타는 쿼리와 타는 쿼리로  ·  주문 300만 행, 워밍업 후 10회 중앙값",
                 color=T, fontsize=12.5, fontweight="bold", x=0.014, ha="left", y=0.95)
    out = os.path.join(OUT, "chart-index.png")
    fig.savefig(out, dpi=160, facecolor=S)
    return out


def sql_line(sql, width=104):
    return f"$ EXPLAIN {sql[:width]}" + ("…" if len(sql) > width else "")


def answer(side):
    """그 쿼리가 실제로 몇 건을 돌려줬는지. 이 줄이 없으면 빈 결과끼리의 비교를 못 알아본다."""
    if side.get("count") is not None:
        return f"결과 {side['count']:,}건"
    return f"결과 {side.get('rows_returned', 0):,}행"


def card(d):
    """증거 카드를 tools/render의 터미널 렌더러로 만든다.

    예전에는 macOS 크롬 헤드리스로 HTML을 찍었다(R13의 termshot.py). 크롬 경로가
    /Applications/... 로 박혀 있어 리눅스에서는 조용히 실패한다. 저장소가 이미 가진
    Pillow 렌더러로 바꿔 어느 호스트에서든 같은 그림이 나오게 했다.
    """
    sys.path.insert(0, os.path.join(ROOT, "..", "..", "tools", "render"))
    from render import render_term

    lines = []
    for c in d:
        lines.append([[f"### {c['ko']}", "yellow"]])
        for side, tag, color in ((c["bad"], "못 탐", "red"), (c["good"], "탐  ", "green")):
            lines.append(sql_line(side["sql"]))
            lines.append([[f"    type={side['type']:<8} key={str(side['key']):<15} "
                           f"rows={side['est_rows']:<9} {str(side['extra'])[:38]}", "dim"]])
            lines.append([[f"    [{tag}] ", color],
                          [f"{side['med_ms']:.2f}ms · 실제로 읽은 행 {side['rows_scanned']:,} · "
                           f"{answer(side)}", "fg"]])
        lines.append([[f"    → {c['speedup']:.1f}배", "yellow"]])
        lines.append("")
    out = os.path.join(OUT, "fig-explain.png")
    render_term({"title": "EXPLAIN 전후: 같은 질문, 다른 실행계획",
                 "font": 22, "lines": lines[:-1]}, out)
    return out


if __name__ == "__main__":
    d = json.load(open(os.path.join(OUT, "bench.json")))
    print(f"{'케이스':<18}{'못 탈 때':>12}{'탈 때':>12}{'배수':>9}"
          f"{'읽은 행(전)':>14}{'읽은 행(후)':>13}{'결과(전/후)':>20}")
    print("-" * 96)
    for c in d:
        ans = (f"{c['bad']['count']:,} / {c['good']['count']:,}"
               if c["bad"].get("count") is not None
               else f"{c['bad'].get('rows_returned', 0)}행 / {c['good'].get('rows_returned', 0)}행")
        print(f"{c['ko']:<18}{c['bad']['med_ms']:>10.1f}ms{c['good']['med_ms']:>10.2f}ms"
              f"{c['speedup']:>8.1f}배{c['bad']['rows_scanned']:>14,}{c['good']['rows_scanned']:>13,}"
              f"{ans:>20}")
    print("저장:", chart(d))
    print("저장:", card(d))
