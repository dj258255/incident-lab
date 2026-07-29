#!/usr/bin/env python3
"""슬롯 지연과 WAL 크기를 한 그림에 겹쳐, 컨슈머가 죽은 뒤 무엇이 쌓이는지 보인다."""
import csv
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "results")
S, T, M, G = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"


def host_line():
    """측정 조건 각주에 쓸 호스트 문자열을 results/env.txt에서 읽는다.

    손으로 쓰지 않는다. 기록이 없으면 그렇게 적는다.
    """
    path = f"{OUT}/env.txt"
    if not os.path.exists(path):
        return "호스트 기록하지 않았습니다"
    txt = open(path, encoding="utf-8").read()
    ver = "macOS " + txt.split("ProductVersion:")[1].split()[0] if "ProductVersion:" in txt else "호스트 불명"
    chip = next((ln.strip() for ln in txt.splitlines() if ln.startswith("Apple")), "")
    spec = next((ln.strip() for ln in txt.splitlines() if ln.startswith("코어")), "")
    return " ".join(x for x in (ver, chip, spec) if x)


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

    rows = list(csv.DictReader(open(f"{OUT}/metrics.csv")))
    t0 = float(rows[0]["ts"])
    xs = [float(r["ts"]) - t0 for r in rows]
    wal = [int(r["wal_bytes"]) / 2**20 for r in rows]
    lag = [int(r["slot_lag_bytes"]) / 2**20 for r in rows]
    act = [r["slot_active"] == "t" for r in rows]

    fig, ax = plt.subplots(figsize=(11.5, 4.6), facecolor=S)
    fig.subplots_adjust(left=0.09, right=0.97, top=0.78, bottom=0.24)
    ax.set_facecolor(S)

    # 컨슈머가 살아 있던 구간을 옅게 칠한다
    alive = [x for x, a in zip(xs, act) if a]
    if alive:
        ax.axvspan(min(alive), max(alive), color="#1baf7a", alpha=0.10, lw=0)
        ax.text(min(alive) + 1, max(wal) * 0.97, " 컨슈머 살아 있음", color="#1baf7a", fontsize=9, va="top")
        ax.axvline(max(alive), color="#d03b3b", lw=1.2, ls=(0, (3, 2)))
        ax.text(max(alive) + 1, max(wal) * 0.97, " 컨슈머 죽음", color="#d03b3b", fontsize=9, va="top")

    ax.plot(xs, wal, lw=1.9, color="#2a78d6", label="pg_wal 디렉터리 크기")
    ax.plot(xs, lag, lw=1.9, color="#d03b3b", label="슬롯 지연 (붙잡고 있는 WAL)")
    ax.set_xlabel("경과 시간(초)", color=M, fontsize=9)
    ax.set_ylabel("MB", color=M, fontsize=9)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("bottom", "left"):
        ax.spines[s].set_color(G)
    ax.tick_params(colors=M, labelsize=8.5, length=0)
    ax.grid(True, color=G, lw=0.7)
    ax.set_axisbelow(True)
    leg = ax.legend(fontsize=9, frameon=False, loc="upper left")
    for t in leg.get_texts():
        t.set_color(T)
    peak = max(lag)
    ipeak = lag.index(peak)
    idead = max(i for i, a in enumerate(act) if a) + 1
    grow = xs[ipeak] - xs[idead]
    fig.suptitle(f"컨슈머가 죽어도 슬롯은 남는다  ·  {grow:.0f}초 만에 슬롯이 붙잡은 WAL {peak:.0f}MB",
                 color=T, fontsize=12.5, fontweight="bold", x=0.012, ha="left", y=0.95)

    # 각주는 손으로 쓰지 않고 결과 파일에서 계산한다.
    # 쓰기 루프는 측정이 끝나기 전에 죽인다. 행이 늘지 않는 꼬리를 빼고 속도를 잰다.
    rows_n = [int(r["rows"]) for r in rows]
    last = max(i for i in range(1, len(rows_n)) if rows_n[i] > rows_n[i - 1])
    rate = (rows_n[last] - rows_n[0]) / (xs[last] - xs[0])
    step = sorted((rows_n[i] - rows_n[i - 1]) / (xs[i] - xs[i - 1]) for i in range(1, last + 1))
    slope = (lag[ipeak] - lag[idead]) / grow
    alive_lag = [l for l, a in zip(lag, act) if a]
    # 관측 간격은 sleep(1)이 아니라 psql 왕복이 붙은 실제 간격이다. 목표치를 라벨에 쓰지 않는다.
    gap = (xs[-1] - xs[0]) / (len(xs) - 1)
    note = (f"{host_line()} · PostgreSQL 17.5 컨테이너 cpus 4 / mem_limit 2g · "
            f"wal_level=logical, max_wal_size=256MB, checkpoint_timeout=30s\n"
            f"실측 쓰기 {rate:.0f}행/초(구간별 {step[0]:.0f}~{step[-1]:.0f}, 행당 payload 1,024B) · "
            f"평균 {gap:.2f}초 간격 {len(rows)}회 관측, 1회 실행 · "
            f"컨슈머 생존 구간 슬롯 지연 {min(alive_lag):.1f}~{max(alive_lag):.1f}MB(톱니) · "
            f"사망 후 증가 기울기 {slope:.2f}MB/초")
    fig.text(0.012, 0.055, note, color=M, fontsize=8, ha="left", va="bottom", linespacing=1.6)

    out = f"{OUT}/chart-wal.png"
    fig.savefig(out, dpi=160, facecolor=S)
    print("저장:", out)
    print(f"슬롯 지연 최대 {peak:.2f}MB(t={xs[ipeak]:.1f}s), WAL 최대 {max(wal):.0f}MB, 종료 시 WAL {wal[-1]:.0f}MB")
    print(f"컨슈머 사망 t={xs[idead]:.1f}s, 이후 {grow:.1f}초 동안 {lag[idead]:.1f}MB -> {peak:.2f}MB ({slope:.3f}MB/s)")
    print(f"생존 구간 슬롯 지연 {min(alive_lag):.2f}~{max(alive_lag):.2f}MB, "
          f"실측 쓰기 {rate:.1f}행/초(구간별 {step[0]:.0f}~{step[-1]:.0f}, 중앙값 {step[len(step)//2]:.0f})")
    # 80MB 고원 구간과 그 사이에 들어간 행수도 본문이 쓰는 값이므로 여기서 계산해 찍는다.
    plateau = [i for i, w in enumerate(wal) if w == 80]
    print(f"pg_wal 80MB 고원 t={xs[plateau[0]]:.1f}~{xs[plateau[-1]]:.1f}s "
          f"({xs[plateau[-1]] - xs[plateau[0]]:.1f}초), 다음 관측 t={xs[plateau[-1]+1]:.1f}s에서 {wal[plateau[-1]+1]:.0f}MB")
    print(f"사망~최대 구간 삽입 행수 {rows_n[ipeak] - rows_n[idead]:,}행 "
          f"(payload 1,024B 기준 약 {(rows_n[ipeak] - rows_n[idead]) * 1024 / 2**20:.0f}MB), "
          f"평균 관측 간격 {gap:.2f}초")


if __name__ == "__main__":
    main()
