#!/usr/bin/env python3
"""해소책 세 가지와 강도 조건을 한 그림에 놓는다.

results/ 아래 실측 파일만 읽는다. 채번 방식이 이 세션의 결론을 어떻게 가르는지가
한 장에 보여야 하므로, 원 사례 재현(jpa-10)과 강도 조건(seq1-10)과
해소책(idn-10, jpa-24, one-10)을 같은 축에 둔다.
"""
import csv, json, os, re, statistics
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "results")
S, T, M, G = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
BAD, GOOD, WARN = "#d03b3b", "#1baf7a", "#c98a1e"
DUR = 40

CONDS = [
    ("two-10",  "커넥션 2개를 직접 잡음\n풀 10"),
    ("seq1-10", "AUTO, allocationSize=1\n풀 10"),
    ("jpa-10",  "AUTO, allocationSize=50\n풀 10 (원 사례)"),
    ("jpa-24",  "같은 코드, 풀 24\n(해소 1)"),
    ("one-10",  "동시 보유 1개, 풀 10\n(해소 2)"),
    ("idn-10",  "IDENTITY, 풀 10\n(해소 3)"),
]


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


def load(label):
    rows = [(int(r["ms"]), r["status"])
            for r in csv.DictReader(open(f"{OUT}/{label}-req.csv"))
            if r["ms"].lstrip("-").isdigit()]
    ms = sorted(v for v, _ in rows)
    ok = sum(1 for _, s in rows if s == "ok")
    return dict(tps=ok / DUR, fail=len(rows) - ok, total=len(rows),
                fail_pct=(len(rows) - ok) / len(rows) * 100, p50=ms[len(ms) // 2])


def batch():
    """배치 INSERT 손익. 워밍업 뒤 3회씩 잰 값의 중앙값을 쓴다."""
    got = {}
    for line in open(f"{OUT}/evidence-batch.txt"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        d = json.loads(line)
        got.setdefault((d["rows"], d["mode"]), []).append(d["ms"])
    return {k: statistics.median(v) for k, v in got.items()}


def main():
    plt = font()
    d = {k: load(k) for k, _ in CONDS}
    keys = [k for k, _ in CONDS]
    labels = [l for _, l in CONDS]
    y = np.arange(len(keys))

    fig, axes = plt.subplots(1, 3, figsize=(15.5, 4.6), facecolor=S)
    fig.subplots_adjust(wspace=0.5, left=0.16, right=0.98, top=0.7, bottom=0.16)

    # 1) 처리량. 로그 축이 아니면 0.3과 180이 한 그림에 안 들어간다.
    ax = axes[0]
    v = [d[k]["tps"] for k in keys]
    ax.barh(y, [max(x, 0.05) for x in v], height=0.6,
            color=[BAD if d[k]["fail"] else GOOD for k in keys])
    for i, x in enumerate(v):
        ax.text(max(x, 0.05) * 1.3, i, f"{x:,.1f}", va="center", fontsize=9, color=T)
    ax.set_xscale("log"); ax.set_xlim(0.1, max(v) * 14)
    ax.set_xticks([0.1, 1, 10, 100]); ax.set_xticklabels(["0.1", "1", "10", "100"])
    ax.set_yticks(y); ax.set_yticklabels(labels, fontsize=8.5)
    ax.set_xlabel("성공 요청 초당 처리량 · 로그 축", color=M, fontsize=9)
    ax.set_title("처리량", color=T, fontsize=11, fontweight="bold", loc="left", pad=10)

    # 2) 실패율. 채번 방식이 이것을 가른다.
    ax = axes[1]
    v = [d[k]["fail_pct"] for k in keys]
    ax.barh(y, v, height=0.6, color=[BAD if x else GOOD for x in v])
    for i, x in enumerate(v):
        ax.text(x + 2, i, f"{x:.1f}%  ({d[keys[i]]['fail']}건)", va="center", fontsize=9, color=T)
    ax.set_xlim(0, 100)
    ax.set_xticks([0, 25, 50, 75, 100]); ax.set_xticklabels(["0", "25%", "50%", "75%", "100%"])
    ax.set_yticks(y); ax.set_yticklabels([])
    ax.set_xlabel("요청 실패율", color=M, fontsize=9)
    ax.set_title("채번 방식이 실패율을 가른다", color=T, fontsize=11,
                 fontweight="bold", loc="left", pad=10)

    # 3) IDENTITY의 대가. 배치 INSERT를 잃는다.
    ax = axes[2]
    b = batch()
    ns = sorted({k[0] for k in b})
    w = 0.36
    x = np.arange(len(ns))
    a_ms = [b[(n, "auto")] for n in ns]
    i_ms = [b[(n, "identity")] for n in ns]
    ax.bar(x - w / 2, a_ms, width=w, color=GOOD, label="AUTO (배치로 묶임)")
    ax.bar(x + w / 2, i_ms, width=w, color=BAD, label="IDENTITY (안 묶임)")
    for xi, (a, i2) in enumerate(zip(a_ms, i_ms)):
        ax.text(xi - w / 2, a + max(i_ms) * 0.02, f"{a:.0f}", ha="center", fontsize=8.5, color=T)
        ax.text(xi + w / 2, i2 + max(i_ms) * 0.02, f"{i2:.0f}", ha="center", fontsize=8.5, color=T)
        # 배수는 낮은 막대(AUTO) 바로 위에 둔다. 위쪽에 두면 범례와 겹치고 잘린다.
        ax.text(xi, a * 0.45, f"{i2 / a:.1f}배", ha="center", fontsize=10,
                color="#ffffff", fontweight="bold")
    ax.set_xticks(x); ax.set_xticklabels([f"{n:,}건" for n in ns], fontsize=9)
    ax.set_ylim(0, max(i_ms) * 1.2)
    ax.set_ylabel("saveAll 소요 시간 (ms)", color=M, fontsize=9)
    ax.set_title("해소 3의 대가: 배치 INSERT", color=T, fontsize=11,
                 fontweight="bold", loc="left", pad=10)
    ax.legend(fontsize=8, frameon=False, labelcolor=M, loc="upper center", ncol=1, bbox_to_anchor=(0.32, 1.0))
    ax.grid(axis="y", color=G, lw=0.7); ax.set_axisbelow(True)

    for a in axes[:2]:
        a.grid(axis="x", color=G, lw=0.7); a.set_axisbelow(True)
    for a in axes:
        a.set_facecolor(S)
        for sp in ("top", "right"):
            a.spines[sp].set_visible(False)
        for sp in ("bottom", "left"):
            a.spines[sp].set_color(G)
        a.tick_params(colors=M, labelsize=8.5, length=0)
    axes[0].spines["left"].set_visible(False)
    axes[1].spines["left"].set_visible(False)

    fig.suptitle("동시 요청 16, 각 40초 · MySQL 8.4.3 · Spring Boot 3.4.1 (Hibernate 6) · "
                 "배치는 워밍업 뒤 3회 중앙값",
                 color=M, fontsize=9.5, x=0.16, ha="left", y=0.93)
    p = f"{OUT}/chart-remedies.png"
    fig.savefig(p, dpi=160, facecolor=S)
    print("wrote", p)
    for k, _ in CONDS:
        print(f"  {k:9} tps={d[k]['tps']:7.1f} 실패 {d[k]['fail']:4}/{d[k]['total']:5} "
              f"({d[k]['fail_pct']:5.1f}%) p50={d[k]['p50']:6}ms")
    print("  배치:", {f"{n}-{m}": b[(n, m)] for n in ns for m in ("auto", "identity")})


if __name__ == "__main__":
    main()
