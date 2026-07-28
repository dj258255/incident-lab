#!/usr/bin/env python3
"""R16 결과 정리.

그림 1: 세 조건의 OLTP p95 시계열. 배치 시작 지점을 표시한다.
그림 2: 버퍼 풀 히트율 시계열.
표: 배치 전/중/후 p95와 히트율 최저점.
"""
import csv
import os
import statistics as st

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "results")

C = {"defense-off": "#e34948", "default": "#2a78d6", "no-batch": "#1baf7a",
     "sustained-off": "#eb6834", "sustained-default": "#4a3aa7"}
KO = {"defense-off": "방어 꺼짐 · 단발 스캔",
      "default": "기본값 · 단발 스캔",
      "no-batch": "배치 없음 (대조군)",
      "sustained-off": "방어 꺼짐 · 60초 지속 스캔",
      "sustained-default": "기본값 · 60초 지속 스캔"}
C_TEXT = "#0b0b0b"
C_MUTED = "#52514e"
C_GRID = "#e4e3df"
C_SURFACE = "#fcfcfb"


def rd(name):
    with open(os.path.join(OUT, name)) as f:
        return list(csv.DictReader(f))


def ts(name):
    with open(os.path.join(OUT, name)) as f:
        return float(f.read().strip())


def q95(v):
    return st.quantiles(v, n=20)[18] if len(v) >= 20 else (max(v) if v else 0)


def p95_series(rows, bucket=3):
    t0 = float(rows[0]["ts"])
    b = {}
    for r in rows:
        k = int((float(r["ts"]) - t0) // bucket) * bucket
        b.setdefault(k, []).append(float(r["latency_ms"]))
    xs = sorted(b)
    return t0, xs, [q95(b[x]) for x in xs]


def font():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import font_manager
    for cand in ["AppleSDGothicNeo", "Apple SD Gothic Neo", "NanumGothic"]:
        if any(cand in f.name for f in font_manager.fontManager.ttflist):
            plt.rcParams["font.family"] = cand
            break
    plt.rcParams["axes.unicode_minus"] = False
    return plt


def style(ax, xl, yl):
    ax.set_facecolor(C_SURFACE)
    ax.set_xlabel(xl, color=C_MUTED, fontsize=9)
    ax.set_ylabel(yl, color=C_MUTED, fontsize=9)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("bottom", "left"):
        ax.spines[s].set_color(C_GRID)
    ax.tick_params(colors=C_MUTED, labelsize=8.5, length=0)
    ax.grid(True, color=C_GRID, lw=0.7)
    ax.set_axisbelow(True)


def main():
    plt = font()
    cases = ["defense-off", "default", "no-batch"]
    for extra in ("sustained-off", "sustained-default"):
        if os.path.exists(os.path.join(OUT, f"{extra}-lat.csv")):
            cases.append(extra)

    # 그림 1: p95 시계열
    fig, ax = plt.subplots(figsize=(11, 4.2), facecolor=C_SURFACE)
    fig.subplots_adjust(left=0.09, right=0.97, top=0.78, bottom=0.14)
    batch_marked = False
    for case in cases:
        rows = rd(f"{case}-lat.csv")
        t0, xs, ys = p95_series(rows)
        ax.plot(xs, ys, lw=1.7, color=C[case], label=KO[case])
        if not batch_marked and os.path.exists(os.path.join(OUT, f"{case}-batch-start.txt")):
            s = ts(f"{case}-batch-start.txt") - t0
            d = ts(f"{case}-batch-done.txt") - t0
            ax.axvspan(s, d, color="#52514e", alpha=0.08, lw=0)
            ax.text(s + 1, ax.get_ylim()[1], " 배치 스캔 구간", color=C_MUTED, fontsize=8.5, va="top")
            batch_marked = True
    ax.set_yscale("log")
    style(ax, "경과 시간(초)", "점조회 p95 (ms) · 로그 축")
    leg = ax.legend(fontsize=8.5, frameon=False, loc="upper right")
    for t in leg.get_texts():
        t.set_color(C_TEXT)
    fig.suptitle("정산 배치가 실시간 점조회에 주는 피해  ·  스레드 8, 3초 구간 p95",
                 color=C_TEXT, fontsize=12.5, fontweight="bold", x=0.014, ha="left", y=0.95)
    fig.savefig(os.path.join(OUT, "chart-oltp.png"), dpi=160, facecolor=C_SURFACE)
    plt.close(fig)

    # 그림 2: 히트율
    fig, ax = plt.subplots(figsize=(11, 3.6), facecolor=C_SURFACE)
    fig.subplots_adjust(left=0.09, right=0.97, top=0.76, bottom=0.16)
    for case in cases:
        rows = rd(f"{case}-bp.csv")
        t0 = float(rows[0]["ts"])
        xs = [float(r["ts"]) - t0 for r in rows]
        ys = [int(r["hit_rate"]) / 10 for r in rows]   # 1000분율 → %
        ax.plot(xs, ys, lw=1.6, color=C[case], label=KO[case])
    style(ax, "경과 시간(초)", "버퍼 풀 히트율 (%)")
    ax.set_ylim(bottom=None, top=100.5)
    leg = ax.legend(fontsize=8.5, frameon=False, loc="lower left")
    for t in leg.get_texts():
        t.set_color(C_TEXT)
    fig.suptitle("버퍼 풀 히트율  ·  INNODB_BUFFER_POOL_STATS.HIT_RATE, 1초 간격",
                 color=C_TEXT, fontsize=12.5, fontweight="bold", x=0.014, ha="left", y=0.95)
    fig.savefig(os.path.join(OUT, "chart-hitrate.png"), dpi=160, facecolor=C_SURFACE)
    plt.close(fig)

    # 표
    print(f"{'조건':<34}{'배치 전 p95':>12}{'배치 중 p95':>12}{'배치 후 p95':>12}{'히트율 최저':>11}")
    print("-" * 84)
    for case in cases:
        rows = rd(f"{case}-lat.csv")
        bs = ts(f"{case}-batch-start.txt") if os.path.exists(os.path.join(OUT, f"{case}-batch-start.txt")) else None
        bd = ts(f"{case}-batch-done.txt") if bs else None
        lat = [(float(r["ts"]), float(r["latency_ms"])) for r in rows]
        if bs:
            before = [v for t, v in lat if t < bs]
            during = [v for t, v in lat if bs <= t <= bd]
            after = [v for t, v in lat if t > bd]
        else:
            n = len(lat)
            before, during, after = [v for _, v in lat[:n // 4]], [v for _, v in lat[n // 4:3 * n // 4]], [v for _, v in lat[3 * n // 4:]]
        hit_min = min(int(r["hit_rate"]) for r in rd(f"{case}-bp.csv")) / 10
        print(f"{KO[case]:<34}{q95(before):>10.2f}ms{q95(during):>10.2f}ms{q95(after):>10.2f}ms{hit_min:>10.1f}%")
        if bs:
            print(f"{'':34}└ 배치 스캔 소요 {bd - bs:.1f}초")
    print("\n저장: chart-oltp.png, chart-hitrate.png")


if __name__ == "__main__":
    main()
