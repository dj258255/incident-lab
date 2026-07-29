#!/usr/bin/env python3
"""bench.csv로 표와 차트를 만든다."""
import csv
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "results")
S, T, M, G = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
BAD, MID, GOOD = "#d03b3b", "#eda100", "#1baf7a"


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


def style(ax, xl, title):
    ax.set_facecolor(S)
    ax.set_xlabel(xl, color=M, fontsize=9)
    ax.set_title(title, color=T, fontsize=11, fontweight="bold", loc="left", pad=10)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color(G)
    ax.tick_params(colors=M, labelsize=8.5, length=0)
    ax.xaxis.grid(True, color=G, lw=0.8)
    ax.set_axisbelow(True)


def main():
    rows = list(csv.DictReader(open(os.path.join(OUT, "bench.csv"))))
    d = {r["label"]: (int(r["elapsed_ms"]), int(r["select_count"])) for r in rows}
    plt = font()

    fig, axes = plt.subplots(1, 3, figsize=(14.5, 3.9), facecolor=S)
    fig.subplots_adjust(wspace=0.52, left=0.13, right=0.98, top=0.76, bottom=0.16)

    # 1) N+1
    ax = axes[0]
    keys = ["N+1 지연로딩", "fetch join(EntityGraph)", "집계 프로젝션"]
    vals = [d[k][0] for k in keys][::-1]
    qs = [d[k][1] for k in keys][::-1]
    bars = ax.barh(keys[::-1], vals, color=[GOOD, MID, BAD], height=0.55)
    for b, v, q in zip(bars, vals, qs):
        ax.text(v + max(vals) * 0.03, b.get_y() + b.get_height() / 2,
                f"{v}ms · 쿼리 {q}개", va="center", fontsize=8.5, color=T)
    ax.set_xlim(0, max(vals) * 2.0)
    style(ax, "응답 시간 (ms)", "목록 20건 + 후원 합계")

    # 2) 페이지네이션
    ax = axes[1]
    offs = [0, 10000, 100000, 199980]
    for name, pre, color in (("OFFSET", "OFFSET ", BAD),
                             ("커서(행값)", "커서(행값) ", MID),
                             ("커서(풀어씀)", "커서(풀어씀) ", GOOD)):
        ys = [d[f"{pre}{o}"][0] for o in offs]
        ax.plot(range(len(offs)), ys, marker="o", ms=5, lw=1.8, color=color, label=name)
    ax.set_xticks(range(len(offs)))
    ax.set_xticklabels([f"{o:,}" for o in offs], fontsize=8)
    style(ax, "건너뛴 행 수", "페이지네이션 깊이별")
    ax.yaxis.grid(True, color=G, lw=0.8)
    ax.set_ylabel("응답 시간 (ms)", color=M, fontsize=9)
    leg = ax.legend(fontsize=8.5, frameon=False, loc="upper left")
    for t in leg.get_texts():
        t.set_color(T)

    # 3) 대량 삽입
    ax = axes[2]
    keys3 = ["saveAll IDENTITY (배치 500)", "saveAll 직접ID (배치 500)", "JDBC batchUpdate (배치 500)"]
    short = ["saveAll\n(IDENTITY)", "saveAll\n(직접 ID)", "JDBC\nbatchUpdate"]
    vals3 = [d[k][0] for k in keys3][::-1]
    bars = ax.barh(short[::-1], vals3, color=[GOOD, BAD, BAD], height=0.55)
    for b, v in zip(bars, vals3):
        ax.text(v + max(vals3) * 0.03, b.get_y() + b.get_height() / 2, f"{v:,}ms",
                va="center", fontsize=9, color=T)
    ax.set_xlim(0, max(vals3) * 1.3)
    style(ax, "1만 건 삽입 (ms)", "대량 삽입")

    fig.suptitle("JPA 목록 API의 세 함정  ·  방송 20만 · 후원 200만, 워밍업 후 5회 중앙값",
                 color=T, fontsize=12.5, fontweight="bold", x=0.012, ha="left", y=0.95)
    out = os.path.join(OUT, "chart-jpa.png")
    fig.savefig(out, dpi=160, facecolor=S)
    print("저장:", out)

    for r in rows:
        print(f"{r['label']:<30}{r['elapsed_ms']:>7}ms  쿼리 {r['select_count']}")


if __name__ == "__main__":
    main()
