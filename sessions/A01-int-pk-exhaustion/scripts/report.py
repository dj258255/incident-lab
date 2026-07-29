#!/usr/bin/env python3
"""전환 중 쓰기 지연을 시계열로 그린다. 실패 0건이라도 지연이 어떻게 갈리는지가 판단 기준이다."""
import csv
import os
import statistics as st

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "results")
S, T, M, G = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
CASES = [("writer-a", "한 방 ALTER (COPY)", "#d03b3b", 12.77),
         ("writer-b", "expand-contract", "#1baf7a", 119.42)]


def main():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import font_manager
    for c in ["AppleSDGothicNeo", "Apple SD Gothic Neo", "NanumGothic"]:
        if any(c in f.name for f in font_manager.fontManager.ttflist):
            plt.rcParams["font.family"] = c
            break
    plt.rcParams["axes.unicode_minus"] = False

    fig, axes = plt.subplots(1, 2, figsize=(13, 4.0), facecolor=S)
    fig.subplots_adjust(wspace=0.24, left=0.08, right=0.97, top=0.76, bottom=0.16)

    print(f"{'방법':<22}{'소요':>9}{'통과한 쓰기':>12}{'실패':>7}{'p95':>11}{'최대':>11}")
    print("-" * 74)
    for ax, (name, ko, color, dur) in zip(axes, CASES):
        rows = list(csv.DictReader(open(f"{OUT}/{name}.csv")))
        t0 = float(rows[0]["ts"])
        s, e = t0 + 5, t0 + 5 + dur
        during = [r for r in rows if s <= float(r["ts"]) <= e]
        xs = [float(r["ts"]) - s for r in during]
        ys = [float(r["ms"]) for r in during]
        ok = [float(r["ms"]) for r in during if r["status"] == "ok"]
        fail = sum(1 for r in during if r["status"] != "ok")
        p95 = st.quantiles(ok, n=20)[18] if len(ok) >= 20 else (max(ok) if ok else 0)
        print(f"{ko:<22}{dur:>8.1f}초{len(during):>12,}{fail:>7}{p95:>9.1f}ms{max(ok) if ok else 0:>9.0f}ms")

        ax.plot(xs, ys, marker="o", ms=3, lw=0.8, color=color)
        ax.set_yscale("log")
        ax.set_facecolor(S)
        ax.set_title(f"{ko}  ·  {dur:.1f}초", color=T, fontsize=11, fontweight="bold", loc="left", pad=10)
        ax.set_xlabel("전환 시작 이후(초)", color=M, fontsize=9)
        if ax is axes[0]:
            ax.set_ylabel("INSERT 응답 시간 (ms) · 로그 축", color=M, fontsize=9)
        for sp in ("top", "right"):
            ax.spines[sp].set_visible(False)
        for sp in ("bottom", "left"):
            ax.spines[sp].set_color(G)
        ax.tick_params(colors=M, labelsize=8.5, length=0)
        ax.grid(True, color=G, lw=0.7)
        ax.set_axisbelow(True)
        ax.set_ylim(0.5, 30000)
        ax.text(0.98, 0.95, f"통과 {len(during):,}건 · 실패 {fail}건",
                transform=ax.transAxes, ha="right", va="top", fontsize=9, color=T)

    fig.suptitle("전환 중에도 쓰기가 들어온다  ·  300만 행, 초당 약 100건의 후원 INSERT",
                 color=T, fontsize=12.5, fontweight="bold", x=0.012, ha="left", y=0.95)
    out = os.path.join(OUT, "chart-migration.png")
    fig.savefig(out, dpi=160, facecolor=S)
    print("저장:", out)


if __name__ == "__main__":
    main()
