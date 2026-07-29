#!/usr/bin/env python3
"""bench.csv와 insert-counters.txt로 표와 차트를 만든다.

패널마다 근거 파일과 측정 조건이 다르므로 한 곳에서 섞지 않는다.

  1·2번 패널  results/bench.csv          bench.sh의 bench(), 워밍업 3회 후 5회 중앙값
  3번 패널    results/insert-counters.txt bench.sh의 insert(), POST 1회 단일 측정

예전 판은 3번 패널도 bench.csv에서 읽었는데, bench.csv의 삽입 행은 쿼리 수를
남기지 않은 다른 실행분(4896 / 4804 / 124)이라 바로 아래 표(4620 / 4555 / 141)와
어긋났다. 본문 기준을 쿼리 수가 함께 남은 insert-counters.txt로 통일한다.
"""
import csv
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "results")
S, T, M, G = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
BAD, MID, GOOD = "#d03b3b", "#eda100", "#1baf7a"


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


def style(ax, xl, title):
    ax.set_facecolor(S)
    ax.set_xlabel(xl, color=M, fontsize=9)
    ax.set_title(title, color=T, fontsize=11, fontweight="bold", loc="left", pad=10)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color(G)
    ax.tick_params(colors=M, labelsize=8.5, length=0)
    ax.xaxis.grid(True, color=G, lw=0.8)
    ax.set_axisbelow(True)


def insert_counters():
    """삽입 구간의 라벨과 수치를 결과 파일에서 그대로 읽는다. 손으로 적지 않는다."""
    path = os.path.join(OUT, "insert-counters.txt")
    pat = re.compile(r"^(\S.*?)\s{2,}(\d+)ms\s+(\d+)\s+(\d+)")
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = pat.match(line)
            if m:
                out.append((m.group(1).strip(), int(m.group(2)),
                            int(m.group(3)), int(m.group(4))))
    if len(out) != 3:
        raise SystemExit(f"insert-counters.txt 파싱 실패: {len(out)}행만 읽혔다")
    return out


def main():
    rows = list(csv.DictReader(open(os.path.join(OUT, "bench.csv"))))
    d = {r["label"]: (int(r["elapsed_ms"]), int(r["select_count"])) for r in rows}
    ins = insert_counters()
    plt = font()

    fig, axes = plt.subplots(1, 3, figsize=(14.5, 4.3), facecolor=S)
    fig.subplots_adjust(wspace=0.52, left=0.13, right=0.98, top=0.78, bottom=0.26)

    # 1) N+1
    ax = axes[0]
    keys = ["N+1 지연로딩", "fetch join(EntityGraph)", "집계 프로젝션"]
    vals = [d[k][0] for k in keys][::-1]
    qs = [d[k][1] for k in keys][::-1]
    bars = ax.barh(keys[::-1], vals, color=[GOOD, MID, BAD], height=0.55)
    for b, v, q in zip(bars, vals, qs):
        ax.text(v + max(vals) * 0.03, b.get_y() + b.get_height() / 2,
                f"{v}ms · 쿼리 {q}개", va="center", fontsize=8.5, color=T)
    ax.set_xlim(0, max(vals) * 2.0)
    style(ax, "응답 시간 (ms)", "목록 20건 + 후원 합계")

    # 2) 페이지네이션
    ax = axes[1]
    offs = [0, 10000, 100000, 199980]
    for name, pre, color in (("OFFSET", "OFFSET ", BAD),
                             ("커서(행값)", "커서(행값) ", MID),
                             ("커서(풀어씀)", "커서(풀어씀) ", GOOD)):
        ys = [d[f"{pre}{o}"][0] for o in offs]
        ax.plot(range(len(offs)), ys, marker="o", ms=5, lw=1.8, color=color, label=name)
    ax.set_xticks(range(len(offs)))
    ax.set_xticklabels([f"{o:,}" for o in offs], fontsize=8)
    style(ax, "건너뛴 행 수", "페이지네이션 깊이별")
    ax.yaxis.grid(True, color=G, lw=0.8)
    ax.set_ylabel("응답 시간 (ms)", color=M, fontsize=9)
    leg = ax.legend(fontsize=8.5, frameon=False, loc="upper left")
    for t in leg.get_texts():
        t.set_color(T)

    # 3) 대량 삽입. bench.csv가 아니라 insert-counters.txt를 쓴다.
    ax = axes[2]
    short = [lab.replace("(", "\n(") for lab, _, _, _ in ins][::-1]
    vals3 = [ms for _, ms, _, _ in ins][::-1]
    inserts = [n for _, _, _, n in ins][::-1]
    bars = ax.barh(short, vals3, color=[GOOD, BAD, BAD], height=0.55)
    for b, v, n in zip(bars, vals3, inserts):
        ax.text(v + max(vals3) * 0.03, b.get_y() + b.get_height() / 2,
                f"{v:,}ms · INSERT {n:,}", va="center", fontsize=8.5, color=T)
    ax.set_xlim(0, max(vals3) * 1.8)
    style(ax, "1만 건 삽입 (ms) · POST 1회", "대량 삽입")

    fig.suptitle("JPA 목록 API의 세 함정  ·  MySQL 8.4.3, 방송 20만 · 후원 200만",
                 color=T, fontsize=12.5, fontweight="bold", x=0.012, ha="left", y=0.955)
    fig.text(0.012, 0.075,
             "1·2번 패널: 워밍업 3회 후 5회 중앙값 (results/bench.csv)   ·   "
             "3번 패널: 워밍업도 반복도 없이 POST 1회 (results/insert-counters.txt). "
             "두 묶음은 서로 다른 실행분이다.",
             color=M, fontsize=8.5, ha="left")
    fig.text(0.012, 0.028,
             "삽입 세 방식은 대상 테이블이 다르다. saveAll(IDENTITY)와 JDBC batchUpdate는 "
             "200만 행이 든 sponsor에, saveAll(직접ID)는 빈 sponsor_assigned에 넣는다. "
             "나란히 비교되는 것은 INSERT 수까지이고 소요 시간은 아니다.",
             color=M, fontsize=8.5, ha="left")
    out = os.path.join(OUT, "chart-jpa.png")
    fig.savefig(out, dpi=160, facecolor=S)
    print("저장:", out)

    for r in rows:
        print(f"{r['label']:<30}{r['elapsed_ms']:>7}ms  쿼리 {r['select_count']}")
    print("\n삽입(insert-counters.txt, POST 1회)")
    for lab, ms, sel, n in ins:
        print(f"{lab:<24}{ms:>7}ms  SELECT {sel:>6}  INSERT {n:>6}")


if __name__ == "__main__":
    main()
