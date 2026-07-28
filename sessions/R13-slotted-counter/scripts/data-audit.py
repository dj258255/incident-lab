#!/usr/bin/env python3
"""적재된 원장이 부하 스크립트의 의도대로 분포하는지 검증한다.

검증 세 가지.
  1. 방송 쏠림: 순위-점유율이 Zipf(s=1.2) 이론 곡선을 따라가는가
  2. 금액 구성: 소액(100~1,000원)과 고액(10,000원 이상)의 비중이 95:5에 가까운가
  3. 유입 안정성: 초당 유입 건수가 측정 구간 내내 고른가

의도와 실측이 어긋나면 어긋난 대로 표와 그림에 남긴다.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "results", "data-audit")

C_SERIES = "#2a78d6"
C_ACCENT = "#1baf7a"
C_TEXT = "#0b0b0b"
C_MUTED = "#52514e"
C_GRID = "#e4e3df"
C_SURFACE = "#fcfcfb"

ZIPF_S = 1.2


def tsv(name):
    path = os.path.join(OUT, name)
    rows = []
    for line in open(path):
        parts = line.rstrip("\n").split("\t")
        if parts and parts[0]:
            rows.append(parts)
    return rows


def main():
    per_live = [(int(r[0]), int(r[1]), int(r[2])) for r in tsv("per-live.tsv")]
    per_amount = [(int(r[0]), int(r[1])) for r in tsv("per-amount.tsv")]
    per_second = [(r[0], int(r[1])) for r in tsv("per-second.tsv")]
    total, lives, users, amt_sum, amt_min, amt_max = [int(x) for x in tsv("summary.tsv")[0]]

    # 1. 방송 쏠림
    counts = [c for _, c, _ in per_live]           # 이미 내림차순
    shares = [c / total for c in counts]
    n = len(counts)
    w = [1 / (i + 1) ** ZIPF_S for i in range(n)]
    z = sum(w)
    theo = [x / z for x in w]

    top1, top10 = shares[0], sum(shares[:10])
    theo1, theo10 = theo[0], sum(theo[:10])

    print(f"\n[데이터 감사] 원장 {total:,}건 · 방송 {lives:,}개 · 후원자 {users:,}명 · 총액 {amt_sum:,}원")
    print("\n1. 방송 쏠림 (실측 vs Zipf 1.2 이론값)")
    print(f"{'구간':<14}{'실측':>10}{'이론':>10}")
    print("-" * 34)
    print(f"{'1위 방송':<14}{top1:>9.1%}{theo1:>9.1%}")
    print(f"{'상위 10개':<14}{top10:>9.1%}{theo10:>9.1%}")
    print(f"{'상위 1%':<14}{sum(shares[:n//100]):>9.1%}{sum(theo[:n//100]):>9.1%}")
    print(f"{'하위 50%':<14}{sum(shares[n//2:]):>9.1%}{sum(theo[n//2:]):>9.1%}")

    # 2. 금액 구성
    small = sum(c for a, c in per_amount if a <= 1000)
    large = sum(c for a, c in per_amount if a >= 10000)
    small_amt = sum(a * c for a, c in per_amount if a <= 1000)
    large_amt = sum(a * c for a, c in per_amount if a >= 10000)
    print("\n2. 금액 구성 (의도: 건수 기준 소액 95% / 고액 5%)")
    print(f"{'구간':<22}{'건수':>12}{'비중':>8}{'금액':>16}{'금액비중':>9}")
    print("-" * 68)
    print(f"{'소액 100~1,000원':<22}{small:>12,}{small/total:>7.1%}{small_amt:>16,}{small_amt/amt_sum:>8.1%}")
    print(f"{'고액 10,000원 이상':<22}{large:>12,}{large/total:>7.1%}{large_amt:>16,}{large_amt/amt_sum:>8.1%}")

    # 3. 유입 안정성. 처음과 끝 초는 부분 초라 제외한다.
    body = [c for _, c in per_second[1:-1]]
    import statistics as st
    mean, stdev = st.mean(body), st.stdev(body)
    print("\n3. 유입 안정성 (부분 초 제외)")
    print(f"초당 평균 {mean:,.0f}건 · 표준편차 {stdev:,.0f} · 변동계수 {stdev/mean:.1%} · 구간 {len(body)}초")

    draw(shares, theo, per_amount, total, body)


def draw(shares, theo, per_amount, total, per_sec):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import font_manager
    for cand in ["AppleSDGothicNeo", "Apple SD Gothic Neo", "NanumGothic", "Malgun Gothic"]:
        if any(cand in f.name for f in font_manager.fontManager.ttflist):
            plt.rcParams["font.family"] = cand
            break
    plt.rcParams["axes.unicode_minus"] = False

    fig, axes = plt.subplots(1, 3, figsize=(14.5, 4.0), facecolor=C_SURFACE)
    fig.subplots_adjust(wspace=0.34, left=0.06, right=0.98, top=0.78, bottom=0.17)

    def style(ax, title, xl, yl):
        ax.set_facecolor(C_SURFACE)
        ax.set_title(title, color=C_TEXT, fontsize=11, fontweight="bold", loc="left", pad=10)
        ax.set_xlabel(xl, color=C_MUTED, fontsize=9)
        ax.set_ylabel(yl, color=C_MUTED, fontsize=9)
        for s in ("top", "right"):
            ax.spines[s].set_visible(False)
        for s in ("bottom", "left"):
            ax.spines[s].set_color(C_GRID)
        ax.tick_params(colors=C_MUTED, labelsize=8.5, length=0)
        ax.grid(True, color=C_GRID, lw=0.7)
        ax.set_axisbelow(True)

    # 1. 순위-점유율 로그-로그. 실측을 먼저 두껍게, 이론 점선을 위에 그린다.
    # 반대로 그리면 두 선이 거의 겹쳐서 이론선이 통째로 가려진다.
    ax = axes[0]
    ranks = range(1, len(shares) + 1)
    ax.plot(ranks, shares, lw=2.2, color=C_SERIES, label="실측")
    ax.plot(ranks, theo, ls=(0, (4, 3)), lw=1.2, color="#0b0b0b", label=f"Zipf s={ZIPF_S} 이론")
    ax.set_xscale("log")
    ax.set_yscale("log")
    # 기본 로그 라벨(10^-1)은 유니코드 마이너스를 써서 한글 폰트에서 글리프가 깨진다.
    # 점유율이니 퍼센트 눈금을 직접 박는다.
    yticks = [0.1, 0.01, 0.001, 0.0001, 0.00001]
    ax.set_yticks(yticks)
    ax.set_yticklabels(["10%", "1%", "0.1%", "0.01%", "0.001%"])
    ax.minorticks_off()
    style(ax, "방송별 후원 점유율", "방송 순위 · 로그 축", "점유율 · 로그 축")
    leg = ax.legend(fontsize=8.5, frameon=False, loc="lower left")
    for t in leg.get_texts():
        t.set_color(C_TEXT)

    # 2. 금액별 건수. 소액과 고액이 자릿수가 달라 로그 축을 쓴다.
    ax = axes[1]
    amounts = [a for a, _ in per_amount]
    cnts = [c for _, c in per_amount]
    ax.bar(range(len(amounts)), cnts, color=C_SERIES, width=0.8)
    # 1,000과 10,000은 값으로는 자릿수가 다르지만 위치 축에서는 이웃 칸이라 라벨이 겹친다.
    # 1,000을 빼고 소액·고액 경계는 우상단 주석에 맡긴다.
    ticks = [i for i, a in enumerate(amounts) if a in (100, 10000, 30000, 59000)]
    ax.set_xticks(ticks)
    ax.set_xticklabels([f"{amounts[i]:,}" for i in ticks])
    ax.set_yscale("log")
    ax.set_yticks([100, 1000, 10000])
    ax.set_yticklabels(["100", "1,000", "10,000"])
    ax.minorticks_off()
    style(ax, "금액별 후원 건수", "후원 금액(원)", "건수 · 로그 축")
    small = sum(c for a, c in per_amount if a <= 1000)
    ax.text(0.98, 0.92, f"소액 {small/total:.1%} · 고액 {1 - small/total:.1%}",
            transform=ax.transAxes, ha="right", fontsize=9, color=C_TEXT)

    # 3. 초당 유입. 수평선에 가까울수록 부하가 고르다.
    ax = axes[2]
    ax.plot(range(len(per_sec)), per_sec, lw=1.4, color=C_ACCENT)
    ax.set_ylim(0, max(per_sec) * 1.25)
    style(ax, "초당 유입 건수", "경과 시간(초)", "건수")

    fig.suptitle("적재 데이터 감사  ·  원장 전건 집계  ·  VU 100 / 60초",
                 color=C_TEXT, fontsize=12.5, fontweight="bold", x=0.012, ha="left", y=0.97)
    out = os.path.join(ROOT, "results", "chart-data-audit.png")
    fig.savefig(out, dpi=160, facecolor=C_SURFACE)
    plt.close(fig)
    print("\n저장:", out)


if __name__ == "__main__":
    if not os.path.isdir(OUT):
        sys.exit("먼저 scripts/data-audit.sh 를 실행해 덤프를 만들어라.")
    main()
