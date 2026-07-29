#!/usr/bin/env python3
"""슬롯 지연과 WAL 크기를 한 그림에 겹쳐, 컨슈머가 죽은 뒤 무엇이 쌓이는지 보인다."""
import csv
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "results")
S, T, M, G = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"


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

    rows = list(csv.DictReader(open(f"{OUT}/metrics.csv")))
    t0 = float(rows[0]["ts"])
    xs = [float(r["ts"]) - t0 for r in rows]
    wal = [int(r["wal_bytes"]) / 2**20 for r in rows]
    lag = [int(r["slot_lag_bytes"]) / 2**20 for r in rows]
    act = [r["slot_active"] == "t" for r in rows]

    fig, ax = plt.subplots(figsize=(11.5, 4.2), facecolor=S)
    fig.subplots_adjust(left=0.09, right=0.97, top=0.76, bottom=0.15)
    ax.set_facecolor(S)

    # 컨슈머가 살아 있던 구간을 옅게 칠한다
    alive = [x for x, a in zip(xs, act) if a]
    if alive:
        ax.axvspan(min(alive), max(alive), color="#1baf7a", alpha=0.10, lw=0)
        ax.text(min(alive) + 1, max(wal) * 0.97, " 컨슈머 살아 있음", color="#1baf7a", fontsize=9, va="top")
        ax.axvline(max(alive), color="#d03b3b", lw=1.2, ls=(0, (3, 2)))
        ax.text(max(alive) + 1, max(wal) * 0.97, " 컨슈머 죽음", color="#d03b3b", fontsize=9, va="top")

    ax.plot(xs, wal, lw=1.9, color="#2a78d6", label="pg_wal 디렉터리 크기")
    ax.plot(xs, lag, lw=1.9, color="#d03b3b", label="슬롯 지연 (붙잡고 있는 WAL)")
    ax.set_xlabel("경과 시간(초)", color=M, fontsize=9)
    ax.set_ylabel("MB", color=M, fontsize=9)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("bottom", "left"):
        ax.spines[s].set_color(G)
    ax.tick_params(colors=M, labelsize=8.5, length=0)
    ax.grid(True, color=G, lw=0.7)
    ax.set_axisbelow(True)
    leg = ax.legend(fontsize=9, frameon=False, loc="upper left")
    for t in leg.get_texts():
        t.set_color(T)
    peak = max(lag)
    fig.suptitle(f"컨슈머가 죽어도 슬롯은 남는다  ·  120초 만에 슬롯이 붙잡은 WAL {peak:.0f}MB",
                 color=T, fontsize=12.5, fontweight="bold", x=0.012, ha="left", y=0.95)
    out = f"{OUT}/chart-wal.png"
    fig.savefig(out, dpi=160, facecolor=S)
    print("저장:", out)
    print(f"슬롯 지연 최대 {peak:.0f}MB, WAL 최대 {max(wal):.0f}MB, 종료 시 WAL {wal[-1]:.0f}MB")


if __name__ == "__main__":
    main()
