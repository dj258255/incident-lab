#!/usr/bin/env python3
"""results/timeline.txt와 burn.csv에서 증거 이미지를 만든다.

손으로 만든 이미지는 다시 만들 수 없고, 다시 만들 수 없는 이미지는 증거가 아니다.
그래서 임계값과 관측값을 전부 실행 기록에서 읽는다.

  사용법: python3 scripts/report.py
"""
import os
import re

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "results")
S, T, M, G = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
BAD, GOOD, WARN = "#d03b3b", "#1baf7a", "#c98a1e"


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


def parse():
    tl = open(f"{OUT}/timeline.txt").read()
    m = re.search(r"경고임계=(\d+)\s+정지임계=(\d+)\s+랩임계=(\d+)", tl)
    warn, stop, wrap = (int(x) for x in m.groups())

    # 경고와 정지가 실제로 관측된 XID
    warn_at = int(re.search(r"경고 구간 진입: nextXid=(\d+)", tl).group(1))
    stop_at = int(re.search(r"쓰기 거부: nextXid=(\d+)", tl).group(1))

    # 서버가 보고한 "남은 트랜잭션 수"
    reported = int(re.search(r"must be vacuumed within (\d+) transactions", tl).group(1))

    # 복구 구간 샘플: "+20초: template0=... postgres=0 ..."
    recov = []
    for t, body in re.findall(r"\+(\d+)초: (.+)", tl):
        ages = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", body)}
        recov.append((int(t), ages))

    # 원인을 제거한 직후(복구 전) 데이터베이스별 나이
    pre = {}
    blk = re.search(r"임계를 붙잡고 있는 것은 다른 데이터베이스다:\n((?:\s+\w+ age=\d+\n)+)", tl)
    if blk:
        pre = {k: int(v) for k, v in re.findall(r"(\w+) age=(\d+)", blk.group(1))}
    return dict(warn=warn, stop=stop, wrap=wrap, warn_at=warn_at, stop_at=stop_at,
                reported=reported, recov=recov, pre=pre)


def main():
    plt = font()
    d = parse()
    fig, axes = plt.subplots(1, 2, figsize=(14, 4.3), facecolor=S)
    fig.subplots_adjust(wspace=0.28, left=0.06, right=0.98, top=0.7, bottom=0.24)

    # 1) 마지막 5,000만 XID 구간을 확대해 경고와 정지의 위치를 그린다.
    #    두 구간의 폭 차이(3,700만 대 300만)가 이 그림의 요점이다.
    ax = axes[0]
    lo = d["wrap"] - 50_000_000
    for x0, x1, col, lab in (
        (lo, d["warn"], G, "정상"),
        (d["warn"], d["stop"], WARN, "경고 구간 3,700만"),
        (d["stop"], d["wrap"], BAD, "정지 구간 300만"),
    ):
        ax.barh([0], [x1 - x0], left=[x0], height=0.5, color=col, label=lab)
    ax.plot([d["warn_at"]], [0], "o", ms=9, color=T, zorder=5)
    ax.annotate(f"경고가 나온 지점\n{d['warn_at']:,}", (d["warn_at"], 0.27),
                ha="left", va="bottom", fontsize=8.5, color=T)
    ax.plot([d["stop_at"]], [0], "s", ms=9, color=T, zorder=5)
    ax.annotate(f"쓰기가 거부된 지점\n{d['stop_at']:,}", (d["stop_at"], -0.28),
                ha="right", va="top", fontsize=8.5, color=T)
    ax.set_xlim(lo - 2_000_000, d["wrap"] + 2_000_000)
    ax.set_ylim(-0.95, 0.95)
    ax.set_yticks([])
    ax.set_xticks([lo, d["warn"], d["stop"], d["wrap"]])
    ax.set_xticklabels(["5,000만", "4,000만", "300만", "0"], fontsize=8.5)
    ax.set_xlabel("데이터 손실 지점까지 남은 트랜잭션 수 (오른쪽이 바닥)", color=M, fontsize=9)
    ax.set_title("경고가 알리는 여유는 4,000만인데 멈추는 곳은 300만 지점이다",
                 color=T, fontsize=10.5, fontweight="bold", loc="left", pad=10)
    ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.22), ncol=3,
              fontsize=8.5, frameon=False, labelcolor=M)
    for sp in ("top", "right", "left"):
        ax.spines[sp].set_visible(False)
    ax.spines["bottom"].set_color(G)

    # 2) 복구. 원인 제거 직후와 그 뒤 자가 복구 샘플.
    ax = axes[1]
    dbs = ["postgres", "template1", "template0", "spoon"]
    stages = [("원인 제거 직후", d["pre"])] + [(f"+{t}초", a) for t, a in d["recov"]]
    x = np.arange(len(stages))
    w = 0.2
    for i, db in enumerate(dbs):
        vals = [s[1].get(db, 0) / 1e9 for s in stages]
        ax.bar(x + (i - 1.5) * w, vals, width=w * 0.9,
               color=[BAD if v > 0.1 else GOOD for v in vals])
    for xi, (_, ages) in zip(x, stages):
        blocked = [db for db in dbs if ages.get(db, 0) > 100_000_000]
        if blocked:
            ax.text(xi, 2.24, f"{len(blocked)}개 막힘", ha="center", fontsize=8.5, color=BAD)
        else:
            ax.text(xi, 0.06, "전부 0", ha="center", fontsize=8.5, color=GOOD)
    ax.set_xticks(x); ax.set_xticklabels([s[0] for s in stages], fontsize=9)
    ax.set_ylim(0, 2.62)
    ax.set_yticks([0, 0.5, 1.0, 1.5, 2.0])
    ax.set_yticklabels(["0", "5억", "10억", "15억", "20억"], fontsize=8.5)
    ax.set_ylabel("age(datfrozenxid)", color=M, fontsize=9)
    ax.axhline(2.147483648, color=BAD, lw=0.9, ls=":")
    ax.text(len(stages) - 0.45, 2.19, "랩 지점 21.4억", ha="right", fontsize=8, color=BAD)
    ax.set_title("prepared transaction만 제거하고 40초 기다리면 스스로 복구된다",
                 color=T, fontsize=10.5, fontweight="bold", loc="left", pad=10)
    # 설명은 막대가 없는 구간에 둔다.
    ax.text(1.32, 1.55, "각 묶음의 막대 4개는 왼쪽부터\npostgres, template1, template0, spoon",
            ha="left", va="top", fontsize=8, color=M)
    ax.grid(axis="y", color=G, lw=0.7)
    ax.set_axisbelow(True)
    for sp in ("top", "right"):
        ax.spines[sp].set_visible(False)
    for sp in ("bottom", "left"):
        ax.spines[sp].set_color(G)

    for a in axes:
        a.set_facecolor(S)
        a.tick_params(colors=M, labelsize=8.5, length=0)

    fig.suptitle("PostgreSQL 17.5 · 버려진 prepared transaction이 동결을 막은 상태",
                 color=M, fontsize=9.5, x=0.06, ha="left", y=0.93)
    p = f"{OUT}/chart-wraparound.png"
    fig.savefig(p, dpi=160, facecolor=S)
    print("wrote", p)
    print(f"  경고임계={d['warn']:,} 정지임계={d['stop']:,} 랩임계={d['wrap']:,}")
    print(f"  실측 경고={d['warn_at']:,}  실측 거부={d['stop_at']:,}  서버 보고 여유={d['reported']:,}")
    print(f"  경고와 정지 사이 거리={d['stop'] - d['warn']:,}")
    print(f"  복구 전 나이: {d['pre']}")
    for t, a in d["recov"]:
        print(f"  +{t}초: {a}")


if __name__ == "__main__":
    main()
