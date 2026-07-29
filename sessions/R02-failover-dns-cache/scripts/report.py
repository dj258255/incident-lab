#!/usr/bin/env python3
"""세 조건의 페일오버 복구 곡선을 그린다.

세로축은 상태를 셋으로 접는다. 정상(새 인스턴스에 붙어 쓰기 가능),
옛 인스턴스에 붙어 있음, 아예 응답 없음.
가로축은 페일오버 시점을 0으로 둔 경과 시간이다.
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "results")
CASES = [("default", "기본값 (JVM 캐시 30초)", "#d03b3b"),
         ("ttl0", "sun.net.inetaddr.ttl=0", "#1baf7a"),
         ("ttl0-life", "ttl=0 + maxLifetime 10초", "#2a78d6")]
S, T, M, G = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"


def load(label):
    fo = float(open(f"{OUT}/{label}-failover-ts.txt").read())
    pts = []
    for line in open(f"{OUT}/{label}.jsonl"):
        ts, _, body = line.partition(" ")
        t = float(ts) - fo
        try:
            d = json.loads(body)
        except json.JSONDecodeError:
            d = {}
        if d.get("db") == "OK" and str(d.get("server_id")) == "2":
            state = 2      # 새 인스턴스로 정상 전환
        elif d.get("db") == "OK":
            state = 1      # 아직 옛 인스턴스
        else:
            state = 0      # 응답 없음
        pts.append((t, state, d.get("resolved")))
    return pts


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

    fig, ax = plt.subplots(figsize=(11.5, 4.0), facecolor=S)
    fig.subplots_adjust(left=0.16, right=0.97, top=0.76, bottom=0.16)
    print(f"{'조건':<26}{'복구까지':>10}")
    print("-" * 40)
    for label, ko, color in CASES:
        if not os.path.exists(f"{OUT}/{label}.jsonl"):
            continue
        pts = [p for p in load(label) if -5 <= p[0] <= 60]
        ax.step([p[0] for p in pts], [p[1] for p in pts], where="post", lw=1.9, color=color, label=ko)
        rec = next((t for t, s, _ in pts if t > 0 and s == 2), None)
        if rec:
            ax.plot([rec], [2], "o", ms=7, color=color)
            ax.annotate(f"{rec:.1f}초", (rec, 2), textcoords="offset points",
                        xytext=(6, 6), fontsize=9, color=color, fontweight="bold")
        print(f"{ko:<26}{(f'{rec:.1f}초' if rec else '미복구'):>10}")

    ax.axvline(0, color=M, lw=1, ls=(0, (3, 2)))
    ax.text(0.4, 2.28, "페일오버", color=M, fontsize=9)
    ax.set_yticks([0, 1, 2])
    ax.set_yticklabels(["응답 없음", "옛 인스턴스", "새 인스턴스"])
    ax.set_ylim(-0.3, 2.5)
    ax.set_xlabel("페일오버 이후 경과 시간(초)", color=M, fontsize=9)
    ax.set_facecolor(S)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("bottom", "left"):
        ax.spines[s].set_color(G)
    ax.tick_params(colors=M, labelsize=9, length=0)
    ax.grid(True, color=G, lw=0.7)
    ax.set_axisbelow(True)
    leg = ax.legend(fontsize=9, frameon=False, loc="lower right")
    for t in leg.get_texts():
        t.set_color(T)
    fig.suptitle("DB는 바로 살아 있는데 앱만 못 붙는 구간  ·  DNS TTL 5초, 앱 0.5초 간격 관측",
                 color=T, fontsize=12.5, fontweight="bold", x=0.014, ha="left", y=0.95)
    out = os.path.join(OUT, "chart-failover.png")
    fig.savefig(out, dpi=160, facecolor=S)
    print("저장:", out)


if __name__ == "__main__":
    main()
