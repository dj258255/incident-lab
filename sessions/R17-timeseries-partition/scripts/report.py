#!/usr/bin/env python3
"""R17 실험 결과를 표와 그래프로 정리한다.

그림 1: 삭제 작업 중 실시간 INSERT p95의 시계열 (DELETE vs DROP PARTITION)
그림 2: 히스토리 리스트 길이 시계열 (문장이 끝난 뒤에도 남는 퍼지 부채)
그림 3: 테이블 파일 크기 변화 (DELETE는 안 줄고 DROP은 준다)
"""
import csv
import os
import statistics as st

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "results")

C_SERIES = "#2a78d6"
C_ACCENT = "#1baf7a"
C_CRIT = "#d03b3b"
C_TEXT = "#0b0b0b"
C_MUTED = "#52514e"
C_GRID = "#e4e3df"
C_SURFACE = "#fcfcfb"


def read_csv(name):
    with open(os.path.join(OUT, name)) as f:
        return list(csv.DictReader(f))


def read_ts(name):
    with open(os.path.join(OUT, name)) as f:
        return float(f.read().strip())


def p95_series(rows, bucket=2):
    """bucket초 단위로 INSERT 지연 p95를 묶는다."""
    t0 = float(rows[0]["ts"])
    buckets = {}
    for r in rows:
        if not r["status"].startswith("ok"):
            continue
        b = int((float(r["ts"]) - t0) // bucket) * bucket
        buckets.setdefault(b, []).append(float(r["latency_ms"]))
    xs = sorted(buckets)
    ys = [st.quantiles(buckets[x], n=20)[18] if len(buckets[x]) >= 20 else max(buckets[x])
          for x in xs]
    return t0, xs, ys


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


def shade(ax, t0, start_file, done_file, label):
    s = read_ts(start_file) - t0
    d = read_ts(done_file) - t0
    ax.axvspan(s, d, color=C_CRIT, alpha=0.10, lw=0)
    ax.axvline(s, color=C_CRIT, lw=1, ls=(0, (3, 2)))
    ax.axvline(d, color=C_CRIT, lw=1, ls=(0, (3, 2)))
    ax.text(s, ax.get_ylim()[1] * 0.95, f" {label}", color=C_CRIT, fontsize=8.5, va="top")
    return s, d


def main():
    plt = font()

    # 그림 1: INSERT p95 시계열
    fig, axes = plt.subplots(1, 2, figsize=(13, 4.0), facecolor=C_SURFACE, sharey=True)
    fig.subplots_adjust(wspace=0.12, left=0.07, right=0.98, top=0.78, bottom=0.16)

    for ax, oltp, sfile, dfile, label in (
        (axes[0], "delete-oltp.csv", "delete-start-ts.txt", "delete-done-ts.txt", "DELETE 7일치"),
        (axes[1], "drop-oltp.csv", "drop-start-ts.txt", "drop-done-ts.txt", "DROP PARTITION 7일치"),
    ):
        rows = read_csv(oltp)
        t0, xs, ys = p95_series(rows)
        ax.plot(xs, ys, lw=1.6, color=C_SERIES)
        ax.set_yscale("log")
        style(ax, label, "경과 시간(초)", "INSERT p95 (ms) · 로그 축" if ax is axes[0] else "")
        shade(ax, t0, sfile, dfile, "삭제 구간")

    fig.suptitle("삭제 작업이 실시간 INSERT에 주는 피해  ·  스레드 8, 2초 구간 p95",
                 color=C_TEXT, fontsize=12.5, fontweight="bold", x=0.014, ha="left", y=0.96)
    fig.savefig(os.path.join(OUT, "chart-oltp-impact.png"), dpi=160, facecolor=C_SURFACE)
    plt.close(fig)

    # 그림 2: 히스토리 리스트 길이
    fig, ax = plt.subplots(figsize=(9.5, 3.8), facecolor=C_SURFACE)
    fig.subplots_adjust(left=0.11, right=0.97, top=0.76, bottom=0.16)
    rows = read_csv("delete-poll.csv")
    t0 = float(rows[0]["ts"])
    xs = [float(r["ts"]) - t0 for r in rows]
    ys = [int(r["history_list_len"]) for r in rows]
    ax.plot(xs, ys, lw=1.6, color=C_ACCENT)
    style(ax, "", "경과 시간(초)", "히스토리 리스트 길이")
    s, d = shade(ax, t0, "delete-start-ts.txt", "delete-done-ts.txt", "DELETE 실행 구간")
    peak = max(ys)
    # 제목은 실측이 정한다. 부채가 쌓였을 것이라는 예상을 제목에 박으면 최대 3이라는 실측과 모순된다.
    fig.suptitle(f"히스토리 리스트 길이  ·  350만 행 DELETE 중 최대 {peak:,}",
                 color=C_TEXT, fontsize=12.5, fontweight="bold", x=0.014, ha="left", y=0.95)
    fig.text(0.014, 0.85, "innodb_purge_threads=1 (8.4 기본값, 논리 코어 16 이하). 이 환경에서는 퍼지가 밀리지 않았다.",
             color=C_MUTED, fontsize=8.5)
    fig.savefig(os.path.join(OUT, "chart-purge-debt.png"), dpi=160, facecolor=C_SURFACE)
    plt.close(fig)

    # 그림 3: 파일 크기
    d_rows = read_csv("delete-poll.csv")
    p_rows = read_csv("drop-poll.csv")
    plain_before = int(d_rows[0]["plain_ibd_bytes"])
    plain_after = int(d_rows[-1]["plain_ibd_bytes"])
    part_before = int(p_rows[0]["part_ibd_bytes"])
    part_after = int(p_rows[-1]["part_ibd_bytes"])

    fig, ax = plt.subplots(figsize=(8.6, 3.4), facecolor=C_SURFACE)
    fig.subplots_adjust(left=0.30, right=0.94, top=0.78, bottom=0.18)
    labels = ["DELETE 후 (plain)", "DELETE 전 (plain)", "DROP 후 (part)", "DROP 전 (part)"]
    vals = [plain_after / 2**30, plain_before / 2**30, part_after / 2**30, part_before / 2**30]
    colors = [C_CRIT, C_MUTED, C_ACCENT, C_MUTED]
    bars = ax.barh(labels, vals, color=colors, height=0.55)
    style(ax, "", "테이블 파일 크기 (GB)", "")
    for b, v in zip(bars, vals):
        ax.text(v + max(vals) * 0.015, b.get_y() + b.get_height() / 2, f"{v:.2f}GB",
                va="center", fontsize=9, color=C_TEXT)
    ax.set_xlim(0, max(vals) * 1.22)
    fig.suptitle("행의 절반을 지웠는데 DELETE 쪽 파일은 줄지 않는다",
                 color=C_TEXT, fontsize=12, fontweight="bold", x=0.02, ha="left", y=0.94)
    fig.savefig(os.path.join(OUT, "chart-disk.png"), dpi=160, facecolor=C_SURFACE)
    plt.close(fig)

    # 표 요약
    for name, oltp, sfile, dfile in (
        ("DELETE", "delete-oltp.csv", "delete-start-ts.txt", "delete-done-ts.txt"),
        ("DROP", "drop-oltp.csv", "drop-start-ts.txt", "drop-done-ts.txt"),
    ):
        rows = [r for r in read_csv(oltp) if r["status"].startswith("ok")]
        s, d = read_ts(sfile), read_ts(dfile)
        before = [float(r["latency_ms"]) for r in rows if float(r["ts"]) < s]
        during = [float(r["latency_ms"]) for r in rows if s <= float(r["ts"]) <= d]
        after = [float(r["latency_ms"]) for r in rows if float(r["ts"]) > d]
        def q95(v):
            return st.quantiles(v, n=20)[18] if len(v) >= 20 else (max(v) if v else 0)
        print(f"[{name}] 삭제 소요 {d - s:.2f}초")
        print(f"  INSERT p95  삭제 전 {q95(before):.1f}ms → 삭제 중 {q95(during):.1f}ms → 삭제 후 {q95(after):.1f}ms")
        print(f"  구간 건수   전 {len(before):,} / 중 {len(during):,} / 후 {len(after):,}")
    print(f"\n파일 크기  plain {plain_before/2**30:.2f} → {plain_after/2**30:.2f}GB, "
          f"part {part_before/2**30:.2f} → {part_after/2**30:.2f}GB")
    print("저장: chart-oltp-impact.png, chart-purge-debt.png, chart-disk.png")


if __name__ == "__main__":
    main()
