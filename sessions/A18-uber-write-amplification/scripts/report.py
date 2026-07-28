#!/usr/bin/env python3
"""A18 측정 결과 표와 차트.

가로축이 변형(인덱스 수 x fillfactor x 갱신 컬럼), 값은 WAL 증가량과 HOT 비율.
Uber 주장이 성립하는 조건(HOT 실패)과 무너지는 조건(HOT 성립)이 나란히 보이게 한다.
"""
import csv
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "results")

KO = {
    "ff100-idx0": "인덱스 0 · 꽉 찬 페이지",
    "ff100-idx3": "인덱스 3 · 꽉 찬 페이지",
    "ff100-idx6": "인덱스 6 · 꽉 찬 페이지",
    "ff100-idx10": "인덱스 10 · 꽉 찬 페이지",
    "ff70-idx0": "인덱스 0 · 여유 공간(ff70)",
    "ff70-idx10": "인덱스 10 · 여유 공간(ff70)",
    "ff70-idx10-indexedcol": "인덱스 10 · ff70 · 인덱스 컬럼 갱신",
    "ff70-idx0-2ndpass": "인덱스 0 · ff70 · 2차 갱신(정상 상태)",
    "ff70-idx10-2ndpass": "인덱스 10 · ff70 · 2차 갱신(정상 상태)",
}
C_SERIES = "#2a78d6"
C_ACCENT = "#1baf7a"
C_WARN = "#e34948"
C_TEXT = "#0b0b0b"
C_MUTED = "#52514e"
C_GRID = "#e4e3df"
C_SURFACE = "#fcfcfb"


def load():
    rows = []
    with open(os.path.join(OUT, "measure.csv")) as f:
        for r in csv.DictReader(f):
            upd = int(r["upd1"]) - int(r["upd0"])
            hot = int(r["hot1"]) - int(r["hot0"])
            rows.append({
                "label": r["label"], "ko": KO.get(r["label"], r["label"]),
                "wal_mb": int(r["wal_bytes"]) / 2**20,
                "elapsed": float(r["elapsed_s"]),
                "hot_pct": hot / upd * 100 if upd else 0,
            })
    return rows


def main():
    rows = load()
    print(f"{'변형':<34}{'WAL(MB)':>9}{'소요(초)':>9}{'HOT 비율':>9}")
    print("-" * 62)
    for r in rows:
        print(f"{r['ko']:<34}{r['wal_mb']:>9.0f}{r['elapsed']:>9.1f}{r['hot_pct']:>8.1f}%")

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import font_manager
    for cand in ["AppleSDGothicNeo", "Apple SD Gothic Neo", "NanumGothic"]:
        if any(cand in f.name for f in font_manager.fontManager.ttflist):
            plt.rcParams["font.family"] = cand
            break
    plt.rcParams["axes.unicode_minus"] = False

    fig, axes = plt.subplots(1, 2, figsize=(13, 4.4), facecolor=C_SURFACE)
    fig.subplots_adjust(wspace=0.5, left=0.22, right=0.97, top=0.80, bottom=0.14)

    labels = [r["ko"] for r in rows][::-1]
    wal = [r["wal_mb"] for r in rows][::-1]
    hot = [r["hot_pct"] for r in rows][::-1]
    colors = []
    for r in rows[::-1]:
        if "indexedcol" in r["label"]:
            colors.append(C_WARN)
        elif r["label"].startswith("ff70"):
            colors.append(C_ACCENT)
        else:
            colors.append(C_SERIES)

    def style(ax, title, unit):
        ax.set_facecolor(C_SURFACE)
        ax.set_title(title, color=C_TEXT, fontsize=11, fontweight="bold", loc="left", pad=10)
        ax.set_xlabel(unit, color=C_MUTED, fontsize=9)
        for s in ("top", "right", "left"):
            ax.spines[s].set_visible(False)
        ax.spines["bottom"].set_color(C_GRID)
        ax.tick_params(colors=C_MUTED, labelsize=8.5, length=0)
        ax.xaxis.grid(True, color=C_GRID, lw=0.8)
        ax.set_axisbelow(True)

    ax = axes[0]
    bars = ax.barh(labels, wal, color=colors, height=0.6)
    style(ax, "50만 행 UPDATE의 WAL 증가량", "MB (낮을수록 좋음)")
    for b, v in zip(bars, wal):
        ax.text(v + max(wal) * 0.015, b.get_y() + b.get_height() / 2, f"{v:,.0f}",
                va="center", fontsize=9, color=C_TEXT)
    ax.set_xlim(0, max(wal) * 1.2)

    ax = axes[1]
    bars = ax.barh(labels, hot, color=colors, height=0.6)
    style(ax, "HOT 업데이트 비율", "% (높을수록 인덱스 갱신 회피)")
    for b, v in zip(bars, hot):
        ax.text(v + 2.5, b.get_y() + b.get_height() / 2, f"{v:.0f}%", va="center",
                fontsize=9, color=C_TEXT)
    ax.set_xlim(0, 115)

    # 제목은 실측에서 뽑는다
    by = {r["label"]: r for r in rows}
    cold = by["ff100-idx10"]["wal_mb"] / by["ff100-idx0"]["wal_mb"]
    warm = by["ff70-idx10-2ndpass"]["wal_mb"] / by["ff70-idx0-2ndpass"]["wal_mb"]
    fig.suptitle(f"인덱스 10개의 WAL 비용: 꽉 찬 페이지에서 {cold:.1f}배, HOT이 도는 정상 상태에서 {warm:.1f}배  ·  50만 행 UPDATE",
                 color=C_TEXT, fontsize=12, fontweight="bold", x=0.014, ha="left", y=0.95)
    out = os.path.join(OUT, "chart-wal.png")
    fig.savefig(out, dpi=160, facecolor=C_SURFACE)
    plt.close(fig)
    print("저장:", out)


if __name__ == "__main__":
    main()
