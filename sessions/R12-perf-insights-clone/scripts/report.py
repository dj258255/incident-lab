#!/usr/bin/env python3
"""샘플러 출력으로 PI풍 대시보드(누적 영역 그래프)를 그린다.

세로축이 AAS(평균 활성 세션)이고, 색이 대기 분류다. PI 화면의 핵심이 이 한 장이다.
vCPU 수(4)를 가로선으로 긋는다. AAS가 이 선을 넘으면 세션들이 CPU를 기다리며 줄을 선 상태다.
"""
import csv
import os
import statistics as st

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "results")

CATS = ["cpu", "io_file", "io_table", "lock", "synch", "other"]
KO = {"cpu": "CPU", "io_file": "IO (파일)", "io_table": "IO (테이블)",
      "lock": "락", "synch": "내부 동기화", "other": "기타"}
# 카테고리 팔레트 순서대로
COLOR = {"cpu": "#1baf7a", "io_file": "#2a78d6", "io_table": "#86b6ef",
         "lock": "#e34948", "synch": "#eda100", "other": "#898781"}
C_TEXT = "#0b0b0b"
C_MUTED = "#52514e"
C_GRID = "#e4e3df"
C_SURFACE = "#fcfcfb"
VCPU = 4


def load(name):
    with open(os.path.join(OUT, name)) as f:
        return list(csv.DictReader(f))


def draw(name, title, out_png, bucket=1):
    rows = load(name)
    t0 = float(rows[0]["ts"])
    xs, series = [], {c: [] for c in CATS}
    if bucket > 1:
        grouped = {}
        for r in rows:
            b = int((float(r["ts"]) - t0) // 1)
            grouped.setdefault(b, []).append(r)
        for b in sorted(grouped):
            xs.append(b)
            for c in CATS:
                series[c].append(st.mean(int(r[c]) for r in grouped[b]))
    else:
        for r in rows:
            xs.append(float(r["ts"]) - t0)
            for c in CATS:
                series[c].append(int(r[c]))

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import font_manager
    for cand in ["AppleSDGothicNeo", "Apple SD Gothic Neo", "NanumGothic"]:
        if any(cand in f.name for f in font_manager.fontManager.ttflist):
            plt.rcParams["font.family"] = cand
            break
    plt.rcParams["axes.unicode_minus"] = False

    fig, ax = plt.subplots(figsize=(11.5, 4.2), facecolor=C_SURFACE)
    fig.subplots_adjust(left=0.07, right=0.97, top=0.80, bottom=0.14)
    ax.set_facecolor(C_SURFACE)
    used = [c for c in CATS if any(v > 0 for v in series[c])]
    ax.stackplot(xs, [series[c] for c in used],
                 colors=[COLOR[c] for c in used],
                 labels=[KO[c] for c in used], alpha=0.92, lw=0)
    ax.axhline(VCPU, color=C_TEXT, lw=1.1, ls=(0, (4, 3)))
    ax.text(xs[-1], VCPU + 0.15, f"vCPU {VCPU}  ", ha="right", fontsize=8.5, color=C_TEXT)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("bottom", "left"):
        ax.spines[s].set_color(C_GRID)
    ax.tick_params(colors=C_MUTED, labelsize=8.5, length=0)
    ax.grid(True, color=C_GRID, lw=0.7)
    ax.set_axisbelow(True)
    ax.set_xlabel("경과 시간(초)", color=C_MUTED, fontsize=9)
    ax.set_ylabel("활성 세션 수 (대기 분류별)", color=C_MUTED, fontsize=9)
    leg = ax.legend(fontsize=8.5, frameon=False, loc="upper left", ncols=len(used))
    for t in leg.get_texts():
        t.set_color(C_TEXT)
    fig.suptitle(title, color=C_TEXT, fontsize=12.5, fontweight="bold", x=0.014, ha="left", y=0.95)
    fig.savefig(out_png, dpi=160, facecolor=C_SURFACE)
    plt.close(fig)
    return out_png


def phase_table(name):
    rows = load(name)
    t0 = float(rows[0]["ts"])
    print(f"\n[{name}] 구간별 평균 활성 세션 (AAS) 분해")
    print(f"{'구간':<26}" + "".join(f"{KO[c]:>10}" for c in CATS))
    for lo, hi, label in ((0, 60, "1: CPU 점조회"), (60, 120, "2: 핫 로우 UPDATE"), (120, 180, "3: 콜드 IO 조회")):
        seg = [r for r in rows if lo <= float(r["ts"]) - t0 < hi]
        if not seg:
            continue
        means = {c: st.mean(int(r[c]) for r in seg) for c in CATS}
        print(f"{label:<26}" + "".join(f"{means[c]:>10.2f}" for c in CATS))


if __name__ == "__main__":
    print("저장:", draw("pi-1s.csv", "미니 Performance Insights  ·  1초 샘플링, 대기 분류별 활성 세션",
                      os.path.join(OUT, "chart-pi-1s.png")))
    print("저장:", draw("pi-100ms.csv", "같은 구간을 0.1초 샘플링으로  ·  1초 단위로 평균",
                      os.path.join(OUT, "chart-pi-100ms.png"), bucket=10))
    phase_table("pi-1s.csv")
    phase_table("pi-100ms.csv")
