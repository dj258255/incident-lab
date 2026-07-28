#!/usr/bin/env python3
"""읽기 비용, 다중 인스턴스, 장애 복구 결과를 표와 그래프로 정리한다.

본 측정(report.py)과 형식이 달라 따로 둔다. 읽기 결과에는 정합성 검증이 없고,
다중 인스턴스 결과는 인스턴스 수가 축이 되기 때문이다.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

C_SERIES = "#2a78d6"
C_CRIT = "#d03b3b"
C_TEXT = "#0b0b0b"
C_MUTED = "#52514e"
C_GRID = "#e4e3df"
C_SURFACE = "#fcfcfb"


def k6(path):
    with open(path) as f:
        return json.load(f)["metrics"]


def font():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import font_manager
    for cand in ["AppleSDGothicNeo", "Apple SD Gothic Neo", "NanumGothic", "Malgun Gothic"]:
        if any(cand in f.name for f in font_manager.fontManager.ttflist):
            plt.rcParams["font.family"] = cand
            break
    plt.rcParams["axes.unicode_minus"] = False
    return plt


READ = [("single-row", "단일 행 조회"), ("slot16", "슬롯 16 합계"), ("slot64", "슬롯 64 합계")]


def read_rows():
    rows = []
    for label, ko in READ:
        p = f"{ROOT}/results/read/{label}.k6.json"
        if not os.path.exists(p):
            continue
        m = k6(p)
        counter_rows = None
        rp = f"{ROOT}/results/read/{label}.rows.txt"
        if os.path.exists(rp):
            for line in open(rp):
                parts = line.split()
                if len(parts) == 2 and parts[0] == "방송1_카운터행수":
                    counter_rows = int(parts[1])
        rows.append({
            "label": label, "ko": ko,
            "rps": m["http_reqs"]["rate"],
            "med": m["http_req_duration"]["med"],
            "p95": m["http_req_duration"]["p(95)"],
            "p99": m["http_req_duration"]["p(99)"],
            "fail": m["http_req_failed"]["value"] * 100,
            "rows": counter_rows,
        })
    return rows


def print_read(rows):
    print("\n[읽기 비용] 방송 1번의 총액을 조회 (VU 50 / 30초)")
    print(f"{'조회 방식':<16}{'훑는 행':>8}{'req/s':>10}{'중앙값ms':>10}{'p95(ms)':>10}{'p99(ms)':>10}")
    print("-" * 66)
    for r in rows:
        rw = f"{r['rows']:,}" if r["rows"] is not None else "1"
        print(f"{r['ko']:<16}{rw:>8}{r['rps']:>10,.0f}{r['med']:>10.2f}{r['p95']:>10.2f}{r['p99']:>10.2f}")


def draw_read(rows):
    plt = font()
    rows_ = rows
    labels = [r["ko"] for r in rows][::-1]
    rps = [r["rps"] for r in rows][::-1]
    p95 = [r["p95"] for r in rows][::-1]

    fig, axes = plt.subplots(1, 2, figsize=(11.5, 3.4), facecolor=C_SURFACE)
    fig.subplots_adjust(wspace=0.4, left=0.16, right=0.97, top=0.72, bottom=0.2)
    for ax, vals, title, unit in ((axes[0], rps, "조회 처리량", "req/s (높을수록 좋음)"),
                                  (axes[1], p95, "조회 p95", "ms (낮을수록 좋음)")):
        ax.set_facecolor(C_SURFACE)
        bars = ax.barh(labels, vals, color=C_SERIES, height=0.55)
        ax.set_title(title, color=C_TEXT, fontsize=11, fontweight="bold", loc="left", pad=10)
        ax.set_xlabel(unit, color=C_MUTED, fontsize=9)
        for s in ("top", "right", "left"):
            ax.spines[s].set_visible(False)
        ax.spines["bottom"].set_color(C_GRID)
        ax.tick_params(colors=C_MUTED, labelsize=9, length=0)
        ax.xaxis.grid(True, color=C_GRID, lw=0.8)
        ax.set_axisbelow(True)
        ax.set_xlim(0, max(vals) * 1.3)
        for b, v in zip(bars, vals):
            ax.text(v + max(vals) * 0.02, b.get_y() + b.get_height() / 2,
                    f"{v:,.0f}" if v >= 100 else f"{v:.2f}",
                    va="center", fontsize=9, color=C_TEXT)

    # 제목은 실측에서 뽑는다. 실험 전 예상은 "슬롯의 대가는 조회"였지만
    # 이 규모에서는 그 대가가 거의 잡히지 않았다. 예상을 제목에 못 박으면 데이터와 어긋난다.
    base = next((r for r in rows_ if r["label"] == "single-row"), rows_[0])
    worst = max(rows_, key=lambda r: r["p95"])
    fig.suptitle(f"조회 비용: 단일 행 p95 {base['p95']:.1f}ms, 슬롯 64 합계 {worst['p95']:.1f}ms  ·  VU 50 / 30초 / 방송 1번",
                 color=C_TEXT, fontsize=12, fontweight="bold", x=0.016, ha="left", y=0.96)
    out = f"{ROOT}/results/chart-read.png"
    fig.savefig(out, dpi=160, facecolor=C_SURFACE)
    plt.close(fig)
    return out


MULTI = [
    ("jvm-lock-x1", "JVM 락 · 인스턴스 1대"),
    ("jvm-lock-x2", "JVM 락 · 인스턴스 2대"),
    ("jpa-naive-x2", "락 없음 · 인스턴스 2대"),
    ("atomic-x2", "원자적 UPDATE · 인스턴스 2대"),
]


def multi_rows():
    rows = []
    for label, ko in MULTI:
        kp = f"{ROOT}/results/multi/{label}.k6.json"
        vp = f"{ROOT}/results/multi/{label}.verify.json"
        if not (os.path.exists(kp) and os.path.exists(vp)):
            continue
        m, v = k6(kp), json.load(open(vp))
        rows.append({
            "label": label, "ko": ko,
            "rps": m["http_reqs"]["rate"],
            "p95": m["http_req_duration"]["p(95)"],
            "ledger": v["ledger_count"], "lost": v["lost_count"],
            "lost_amt": v["lost_amount"], "match": v["match"],
        })
    return rows


def print_multi(rows):
    print("\n[다중 인스턴스] 같은 부하를 인스턴스 수만 바꿔 보냄 (VU 100 / 60초)")
    print(f"{'구성':<26}{'req/s':>10}{'p95(ms)':>10}{'원장건수':>12}{'유실건수':>10}{'유실률':>9}{'정합':>6}")
    print("-" * 84)
    for r in rows:
        pct = r["lost"] / r["ledger"] * 100 if r["ledger"] else 0
        print(f"{r['ko']:<26}{r['rps']:>10,.0f}{r['p95']:>10.1f}{r['ledger']:>12,}"
              f"{r['lost']:>10,}{pct:>8.1f}%{'OK' if r['match'] else 'X':>6}")
        if r["lost"]:
            print(f"{'':26}└ 유실 금액 {r['lost_amt']:,}원")


def draw_multi(rows):
    plt = font()
    labels = [r["ko"] for r in rows][::-1]
    pct = [(r["lost"] / r["ledger"] * 100 if r["ledger"] else 0) for r in rows][::-1]
    broken = [not r["match"] for r in rows][::-1]

    fig, ax = plt.subplots(figsize=(8.6, 3.4), facecolor=C_SURFACE)
    fig.subplots_adjust(left=0.32, right=0.95, top=0.74, bottom=0.2)
    ax.set_facecolor(C_SURFACE)
    bars = ax.barh(labels, pct, color=[C_CRIT if b else C_SERIES for b in broken], height=0.55)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color(C_GRID)
    ax.tick_params(colors=C_MUTED, labelsize=9, length=0)
    ax.xaxis.grid(True, color=C_GRID, lw=0.8)
    ax.set_axisbelow(True)
    ax.set_xlabel("후원 유실률 (%)", color=C_MUTED, fontsize=9)
    ax.set_xlim(0, max(max(pct) * 1.4, 1))
    for b, v, bad in zip(bars, pct, broken):
        ax.text(v + max(max(pct), 1) * 0.02, b.get_y() + b.get_height() / 2,
                (f"{v:.1f}%  집계 불일치" if bad else "0%  정합"),
                va="center", fontsize=9, color=C_CRIT if bad else C_TEXT,
                fontweight="bold" if bad else "normal")

    fig.suptitle("JVM 안의 자물쇠는 인스턴스가 늘어나면 지키지 못합니다",
                 color=C_TEXT, fontsize=12, fontweight="bold", x=0.02, ha="left", y=0.95)
    out = f"{ROOT}/results/chart-multi.png"
    fig.savefig(out, dpi=160, facecolor=C_SURFACE)
    plt.close(fig)
    return out


def print_failure():
    base = f"{ROOT}/results/failure"
    bp, ap, rp = f"{base}/redis-kill.before.json", f"{base}/redis-kill.after.json", f"{base}/redis-kill.rebuild.json"
    if not os.path.exists(bp):
        return
    before, after = json.load(open(bp)), json.load(open(ap))
    rebuild = json.load(open(rp)) if os.path.exists(rp) else {}
    print("\n[Redis 장애] 부하 도중 Redis를 죽였다가 되살린 뒤 원장에서 복구")
    print(f"{'시점':<12}{'원장건수':>12}{'카운터건수':>12}{'유실건수':>10}{'유실금액':>14}{'정합':>6}")
    print("-" * 68)
    for name, d in (("복구 전", before), ("복구 후", after)):
        print(f"{name:<12}{d['ledger_count']:>12,}{d['counter_count']:>12,}"
              f"{d['lost_count']:>10,}{d['lost_amount']:>14,}{'OK' if d['match'] else 'X':>6}")
    if rebuild:
        print(f"\n재구성 대상 테이블 {rebuild.get('rebuilt_table')} · 소요 {rebuild.get('elapsed_ms')}ms")
    tl = f"{base}/redis-kill.timeline.txt"
    if os.path.exists(tl):
        print("\n타임라인")
        for line in open(tl):
            print("  " + line.rstrip())


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what in ("all", "read"):
        rows = read_rows()
        if rows:
            print_read(rows)
            try:
                print("저장:", draw_read(rows))
            except ImportError:
                pass
    if what in ("all", "multi"):
        rows = multi_rows()
        if rows:
            print_multi(rows)
            try:
                print("저장:", draw_multi(rows))
            except ImportError:
                pass
    if what in ("all", "failure"):
        print_failure()
