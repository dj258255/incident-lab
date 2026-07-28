#!/usr/bin/env python3
"""측정 결과를 표와 그래프로 정리한다.

반복 측정분(*-r1, *-r2 …)이 있으면 중앙값과 최소·최대를 함께 낸다.
한 번만 재고 끝내면 변형 간 차이가 실제 차이인지 실행 편차인지 구분할 수 없기 때문이다.
"""
import csv
import glob
import json
import os
import re
import statistics as st
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 순서는 이야기의 순서다. 틀린 구현 → 느린 정답 → 빠른 정답 순으로 둔다.
ORDER = [
    ("jpa-naive", "JPA 조회 후 증가"),
    ("jvm-lock", "JVM 락 + 조회 후 증가"),
    ("jpa-optimistic", "낙관적 락 + 재시도"),
    ("jpa-pessimistic", "비관적 락"),
    ("atomic", "원자적 UPDATE"),
    ("slot16", "슬롯 16"),
    ("slot64", "슬롯 64"),
    ("redis", "Redis 카운터"),
    ("redis-pipe", "Redis 파이프라인"),
]

# dataviz 검증 팔레트에서 가져온 값
C_SERIES = "#2a78d6"   # 카테고리 슬롯 1 (blue)
C_ACCENT = "#1baf7a"   # 카테고리 슬롯 3 (aqua)
C_CRIT = "#d03b3b"     # status: critical
C_TEXT = "#0b0b0b"
C_MUTED = "#52514e"
C_GRID = "#e4e3df"
C_SURFACE = "#fcfcfb"


def lock_delta(base, label):
    """측정 구간 동안 늘어난 행 락 대기 수. 경합이 실제로 락에서 왔는지 보여주는 지표다."""
    def read(path):
        if not os.path.exists(path):
            return {}
        out = {}
        for line in open(path):
            parts = line.split()
            if len(parts) == 2:
                out[parts[0]] = int(parts[1])
        return out
    b = read(os.path.join(base, f"{label}.lock.before.txt"))
    a = read(os.path.join(base, f"{label}.lock.after.txt"))
    if not b or not a:
        return None, None
    waits = a.get("Innodb_row_lock_waits", 0) - b.get("Innodb_row_lock_waits", 0)
    time_ms = a.get("Innodb_row_lock_time", 0) - b.get("Innodb_row_lock_time", 0)
    return waits, time_ms


def load(scenario):
    """레이블별로 반복 측정분을 모은다."""
    base = os.path.join(ROOT, "results", scenario)
    runs = {}
    for kf in sorted(glob.glob(os.path.join(base, "*.k6.json"))):
        label = os.path.basename(kf)[: -len(".k6.json")]
        vf = kf.replace(".k6.json", ".verify.json")
        if not os.path.exists(vf):
            continue
        base_label = re.sub(r"-r\d+$", "", label)
        try:
            k = json.load(open(kf))["metrics"]
            v = json.load(open(vf))
        except (json.JSONDecodeError, KeyError):
            continue
        waits, lock_ms = lock_delta(base, label)
        runs.setdefault(base_label, []).append({
            "lock_waits": waits, "lock_ms": lock_ms,
            "rps": k["http_reqs"]["rate"],
            "p95": k["http_req_duration"]["p(95)"],
            "p99": k["http_req_duration"]["p(99)"],
            "fail": k["http_req_failed"]["value"] * 100,
            "ledger": v["ledger_count"],
            "counter": v["counter_count"],
            "lost": v["lost_count"],
            "lost_amt": v["lost_amount"],
            "match": v["match"],
            "retries": v["optimistic_retries"],
        })
    return runs


def summarize(runs):
    rows = []
    for label, ko in ORDER:
        rs = runs.get(label)
        if not rs:
            continue
        med = lambda key: st.median([r[key] for r in rs])
        rng = lambda key: (min(r[key] for r in rs), max(r[key] for r in rs))
        worst = max(rs, key=lambda r: r["lost"])
        lw = [r["lock_waits"] for r in rs if r["lock_waits"] is not None]
        lm = [r["lock_ms"] for r in rs if r["lock_ms"] is not None]
        rows.append({
            "label": label, "ko": ko, "n": len(rs),
            "rps": med("rps"), "rps_min": rng("rps")[0], "rps_max": rng("rps")[1],
            "p95": med("p95"), "p99": med("p99"), "fail": med("fail"),
            "lost": worst["lost"], "lost_amt": worst["lost_amt"],
            "ledger": worst["ledger"],
            "match": all(r["match"] for r in rs),
            "retries": worst["retries"],
            "lock_waits": st.median(lw) if lw else 0,
            "lock_ms": st.median(lm) if lm else 0,
            # 대기 횟수보다 한 번의 대기가 얼마나 길었는지가 본질이다.
            # 슬롯은 대기 횟수를 줄이는 게 아니라 대기 줄을 짧게 만든다.
            "lock_avg": (st.median(lm) / st.median(lw)) if lw and st.median(lw) else 0,
        })
    return rows


def write_csv(rows, scenario):
    path = os.path.join(ROOT, "results", f"summary-{scenario}.csv")
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    return path


def print_table(rows, scenario):
    print(f"\n[{scenario}] 변형별 요약 (반복 측정 중앙값)")
    print(f"{'변형':<20}{'n':>3}{'req/s':>10}{'범위':>16}{'p95(ms)':>10}{'p99(ms)':>10}"
          f"{'실패%':>8}{'락대기':>10}{'평균대기ms':>11}{'유실':>10}{'정합':>6}")
    print("-" * 120)
    for r in rows:
        rng = f"{r['rps_min']:.0f}~{r['rps_max']:.0f}"
        lost = f"{r['lost']:,}" if r["lost"] else "0"
        print(f"{r['ko']:<20}{r['n']:>3}{r['rps']:>10.0f}{rng:>16}"
              f"{r['p95']:>10.1f}{r['p99']:>10.1f}{r['fail']:>8.2f}"
              f"{r['lock_waits']:>10,.0f}{r['lock_avg']:>11.1f}{lost:>10}{'OK' if r['match'] else 'X':>6}")
        if r["lost"]:
            pct = r["lost"] / r["ledger"] * 100
            print(f"{'':20}└ 유실률 {pct:.1f}% · 유실 금액 {r['lost_amt']:,}원")
        if r["retries"]:
            print(f"{'':20}└ 낙관적 락 재시도 {r['retries']:,}회")


def draw(rows, scenario):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import font_manager

    for cand in ["AppleSDGothicNeo", "Apple SD Gothic Neo", "NanumGothic", "Malgun Gothic"]:
        if any(cand in f.name for f in font_manager.fontManager.ttflist):
            plt.rcParams["font.family"] = cand
            break
    plt.rcParams["axes.unicode_minus"] = False

    labels = [r["ko"] for r in rows][::-1]
    rps = [r["rps"] for r in rows][::-1]
    p95 = [r["p95"] for r in rows][::-1]
    broken = [not r["match"] for r in rows][::-1]

    fig, axes = plt.subplots(1, 2, figsize=(13, 4.6), facecolor=C_SURFACE)
    fig.subplots_adjust(wspace=0.42, left=0.16, right=0.97, top=0.84, bottom=0.14)

    def style(ax, title, unit):
        ax.set_facecolor(C_SURFACE)
        ax.set_title(title, color=C_TEXT, fontsize=12, fontweight="bold", loc="left", pad=12)
        ax.set_xlabel(unit, color=C_MUTED, fontsize=9)
        for s in ("top", "right", "left"):
            ax.spines[s].set_visible(False)
        ax.spines["bottom"].set_color(C_GRID)
        ax.tick_params(colors=C_MUTED, labelsize=9, length=0)
        ax.xaxis.grid(True, color=C_GRID, lw=0.8)
        ax.set_axisbelow(True)

    # 왼쪽: 처리량. 정합성이 깨진 변형은 상태색으로 칠하고 라벨을 붙여, 색만으로 뜻이 전달되지 않게 한다.
    ax = axes[0]
    colors = [C_CRIT if b else C_SERIES for b in broken]
    bars = ax.barh(labels, rps, color=colors, height=0.6)
    style(ax, "처리량", "req/s (높을수록 좋음)")
    for b, v, bad in zip(bars, rps, broken):
        ax.text(v + max(rps) * 0.015, b.get_y() + b.get_height() / 2,
                f"{v:,.0f}" + ("  집계 불일치" if bad else ""),
                va="center", fontsize=9, color=C_CRIT if bad else C_TEXT,
                fontweight="bold" if bad else "normal")
    ax.set_xlim(0, max(rps) * 1.35)

    # 오른쪽: p95. 낙관적 락이 자릿수가 달라 로그 축을 쓴다.
    # 여기서도 상태색 옆에 같은 문구를 붙인다. 색만으로 뜻이 전달되면 색을 못 보는 독자는 읽을 수 없다.
    ax = axes[1]
    bars = ax.barh(labels, p95, color=[C_CRIT if b else C_ACCENT for b in broken], height=0.6)
    ax.set_xscale("log")
    style(ax, "응답 p95", "ms · 로그 축 (낮을수록 좋음)")
    for b, v, bad in zip(bars, p95, broken):
        ax.text(v * 1.12, b.get_y() + b.get_height() / 2,
                f"{v:,.0f}" + ("  집계 불일치" if bad else ""),
                va="center", fontsize=9, color=C_CRIT if bad else C_TEXT,
                fontweight="bold" if bad else "normal")
    ax.set_xlim(min(p95) * 0.6, max(p95) * 6)

    # 변형마다 반복 횟수가 다르면 그 사실을 제목에 드러낸다. 하나로 뭉뚱그리면 중앙값의 근거가 흐려진다.
    ns = {r["n"] for r in rows}
    n = f"{min(ns)}~{max(ns)}" if len(ns) > 1 else str(ns.pop())
    fig.suptitle(f"라이브 후원 카운터 변형별 비교  ·  {scenario} 시나리오  ·  VU 100 / 60초 / {n}회 반복 중앙값",
                 color=C_TEXT, fontsize=13, fontweight="bold", x=0.016, ha="left", y=0.965)

    out = os.path.join(ROOT, "results", f"chart-{scenario}.png")
    fig.savefig(out, dpi=160, facecolor=C_SURFACE)
    plt.close(fig)
    return out


def draw_lock(rows, scenario):
    """처리량은 결과고 락 대기는 원인이다. 원인은 따로 그린다.

    Redis 변형은 카운터를 DB에 두지 않아 이 지표가 0이다. 0을 막대로 그리면
    '락이 거의 없었다'로 읽히므로 아예 빼고 그 사실을 캡션으로 적는다.
    """
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    rows = [r for r in rows if r["lock_waits"]]
    if not rows:
        return None

    labels = [r["ko"] for r in rows][::-1]
    avg = [r["lock_avg"] for r in rows][::-1]

    fig, ax = plt.subplots(figsize=(7.6, 3.9), facecolor=C_SURFACE)
    fig.subplots_adjust(left=0.28, right=0.95, top=0.78, bottom=0.18)
    ax.set_facecolor(C_SURFACE)
    bars = ax.barh(labels, avg, color=C_SERIES, height=0.6)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color(C_GRID)
    ax.tick_params(colors=C_MUTED, labelsize=9, length=0)
    ax.xaxis.grid(True, color=C_GRID, lw=0.8)
    ax.set_axisbelow(True)
    ax.set_xlabel("행 락 한 번당 평균 대기 시간 (ms)", color=C_MUTED, fontsize=9)
    ax.set_xlim(0, max(avg) * 1.25)
    for b, v in zip(bars, avg):
        ax.text(v + max(avg) * 0.015, b.get_y() + b.get_height() / 2, f"{v:.1f}",
                va="center", fontsize=9, color=C_TEXT)

    # 제목은 데이터에서 뽑는다. 손으로 적은 문구는 수치가 바뀌어도 그대로 남아 거짓말이 된다.
    hi, lo = max(avg), min(avg)
    fig.suptitle(f"슬롯을 쓰면 락 한 번당 평균 대기가 {hi:.0f}ms에서 {lo:.1f}ms로 떨어집니다",
                 color=C_TEXT, fontsize=12, fontweight="bold", x=0.02, ha="left", y=0.955)
    fig.text(0.02, 0.87, "Redis 변형은 카운터를 DB에 두지 않아 이 지표가 잡히지 않으므로 뺐습니다.",
             color=C_MUTED, fontsize=8.5, ha="left")

    out = os.path.join(ROOT, "results", f"chart-lock-{scenario}.png")
    fig.savefig(out, dpi=160, facecolor=C_SURFACE)
    plt.close(fig)
    return out


if __name__ == "__main__":
    scenario = sys.argv[1] if len(sys.argv) > 1 else "zipf"
    runs = load(scenario)
    if not runs:
        sys.exit(f"결과 없음: results/{scenario}")
    rows = summarize(runs)
    print_table(rows, scenario)
    print("\n저장:", write_csv(rows, scenario))
    try:
        print("저장:", draw(rows, scenario))
        lock = draw_lock(rows, scenario)
        if lock:
            print("저장:", lock)
    except ImportError:
        print("matplotlib 없음. 표만 생성했다.")
