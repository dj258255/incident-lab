#!/usr/bin/env python3
"""전환 중 쓰기 지연을 시계열로 그린다. 실패 0건이라도 지연이 어떻게 갈리는지가 판단 기준이다.

그림에 박히는 수치는 손으로 쓰지 않고 실행 로그 results/exp2.txt에서 읽는다.
예전 판은 소요 시간을 상수로 적어 두고 건수를 이 스크립트가 다시 셌는데, 창의 시작점을
writer 첫 기록 시각 + 5초로 잡는 바람에 방법 A의 건수가 로그의 11건이 아니라 12건으로
나왔다. 그림이 로그를 반박하는 상태였다.

exp2-migrate.sh는 전환 시작·종료 시각(S, E)을 파일로 남기지 않는다. writer 프로세스가
기동하는 데 걸린 시간만큼 "첫 기록 시각 + 5초"는 실제 S보다 늦다. 그래서 그 지점에서
1ms씩 앞으로 당기며 로그에 적힌 건수와 처음 일치하는 곳을 창의 시작으로 삼는다.
방법 B는 0ms에서 바로 맞고, 방법 A는 74ms 앞에서 맞는다. 기준은 언제나 실행 로그다.

건수만으로는 두 방법을 비교할 수 없다. 관측 창이 12.8초와 119.4초로 다르기 때문이다.
그래서 창 안 초당 통과량과, 전환이 시작되기 전 워밍업 5초의 초당 통과량을 함께 낸다.
앞엣것이 전환 중 처리량이고 뒤엣것이 같은 writer가 평시에 내던 기준선이다. 두 방법의
기준선이 비슷해야 "같은 부하를 받았다"가 성립하므로 기준선도 그림과 콘솔에 남긴다.
"""
import csv
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "results")
S, T, M, G = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
CASES = [("writer-a", "한 방 ALTER (COPY)", "#d03b3b"),
         ("writer-b", "expand-contract", "#1baf7a")]


def read_log(path):
    """exp2.txt에서 방법별 소요·건수·실패·p95·최대를 읽는다. 라벨의 유일한 출처다."""
    text = open(path, encoding="utf-8").read()
    rows_total = re.search(r"\((\d+)행\)", text)
    blocks = re.split(r"^방법 ", text, flags=re.M)[1:]
    if len(blocks) != len(CASES):
        raise SystemExit(f"exp2.txt에서 방법 블록 {len(CASES)}개를 찾지 못했습니다: {len(blocks)}개")
    out = []
    for b in blocks:
        whole = re.search(r"전체 소요 ([\d.]+)초", b)
        dur = whole or re.search(r"^\s*소요 ([\d.]+)초", b, flags=re.M)
        n = re.search(r"전환 중 쓰기 ([\d,]+)건 · 성공 ([\d,]+) · 실패 ([\d,]+)", b)
        q = re.search(r"p95 ([\d.]+)ms · 최대 ([\d.]+)ms", b)
        if not (dur and n and q):
            raise SystemExit("exp2.txt의 요약 줄을 읽지 못했습니다. 로그 형식이 바뀌었는지 확인하세요.")
        out.append({
            "dur": float(dur.group(1)),
            "n": int(n.group(1).replace(",", "")),
            "fail": int(n.group(3).replace(",", "")),
            "p95": float(q.group(1)),
            "max": float(q.group(2)),
        })
    return int(rows_total.group(1)) if rows_total else 0, out


def window(rows, dur, n_log):
    """로그의 건수와 일치하는 관측 창을 되찾는다. 못 찾으면 조용히 넘어가지 않고 멈춘다."""
    ts = [float(r["ts"]) for r in rows]
    base = ts[0] + 5
    for k in range(0, 2001):
        s = base - k / 1000
        if sum(1 for t in ts if s <= t <= s + dur) == n_log:
            return s, s + dur, k / 1000
    raise SystemExit(f"실행 로그의 {n_log}건과 맞는 창을 찾지 못했습니다. CSV와 로그가 다른 실행분인지 확인하세요.")


def baseline(rows, s):
    """전환 시작 전 워밍업 구간의 초당 통과량. 같은 writer가 평시에 내던 값이다."""
    ts = [float(r["ts"]) for r in rows if float(r["ts"]) < s]
    if len(ts) < 2:
        raise SystemExit("워밍업 구간이 비어 있습니다. CSV가 전환 시작 이후만 담고 있는지 확인하세요.")
    return len(ts) / (ts[-1] - ts[0])


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

    seeded, logs = read_log(os.path.join(OUT, "exp2.txt"))

    fig, axes = plt.subplots(1, 2, figsize=(13, 4.0), facecolor=S)
    fig.subplots_adjust(wspace=0.24, left=0.08, right=0.97, top=0.76, bottom=0.16)

    bases = []
    print(f"{'방법':<22}{'소요':>9}{'통과한 쓰기':>12}{'초당':>9}{'실패':>7}{'p95':>11}{'최대':>11}")
    print("-" * 83)
    for ax, (name, ko, color), lg in zip(axes, CASES, logs):
        rows = list(csv.DictReader(open(f"{OUT}/{name}.csv")))
        s, e, shift = window(rows, lg["dur"], lg["n"])
        during = [r for r in rows if s <= float(r["ts"]) <= e]
        xs = [float(r["ts"]) - s for r in during]
        ys = [float(r["ms"]) for r in during]
        rate = lg["n"] / lg["dur"]
        base = baseline(rows, s)
        bases.append(base)
        print(f"{ko:<22}{lg['dur']:>8.1f}초{lg['n']:>12,}{rate:>8.1f}건{lg['fail']:>7}"
              f"{lg['p95']:>9.1f}ms{lg['max']:>9.0f}ms", file=sys.stdout)

        ax.plot(xs, ys, marker="o", ms=3, lw=0.8, color=color)
        ax.set_yscale("log")
        ax.set_facecolor(S)
        ax.set_title(f"{ko}  ·  {lg['dur']:.1f}초", color=T, fontsize=11, fontweight="bold", loc="left", pad=10)
        ax.set_xlabel("전환 시작 이후(초)", color=M, fontsize=9)
        if ax is axes[0]:
            ax.set_ylabel("INSERT 응답 시간 (ms) · 로그 축", color=M, fontsize=9)
        for sp in ("top", "right"):
            ax.spines[sp].set_visible(False)
        for sp in ("bottom", "left"):
            ax.spines[sp].set_color(G)
        ax.tick_params(colors=M, labelsize=8.5, length=0)
        ax.grid(True, color=G, lw=0.7)
        ax.set_axisbelow(True)
        ax.set_ylim(0.5, 30000)
        ax.text(0.98, 0.95,
                f"통과 {lg['n']:,}건 · 실패 {lg['fail']}건\n"
                f"초당 {rate:.1f}건 (전환 직전 {base:.1f}건)",
                transform=ax.transAxes, ha="right", va="top", fontsize=9, color=T,
                linespacing=1.5,
                bbox=dict(facecolor=S, edgecolor="none", pad=2.5))

    lo, hi = min(bases), max(bases)
    fig.suptitle(f"전환 중에도 쓰기가 들어온다  ·  {seeded:,}행, "
                 f"전환 직전 5초 실측 초당 {lo:.0f}~{hi:.0f}건의 후원 INSERT",
                 color=T, fontsize=12.5, fontweight="bold", x=0.012, ha="left", y=0.95)
    out = os.path.join(OUT, "chart-migration.png")
    fig.savefig(out, dpi=160, facecolor=S)
    print("-" * 83)
    print(f"전환 직전 5초 기준선: " + " · ".join(
        f"{ko} {b:.1f}건/초" for (_, ko, _), b in zip(CASES, bases)))
    print("표본이 20건 미만이면 exp2-migrate.sh가 p95 대신 최댓값을 씁니다. 방법 A의 p95는 최댓값입니다.")
    print("저장:", out)


if __name__ == "__main__":
    main()
