#!/usr/bin/env python3
"""측정 결과를 표로 출력하고 results/render.json을 만든다.

이미지는 손으로 그리지 않는다. 여기서 만든 render.json을 tools/render가 읽어 PNG를 낸다.
표준 라이브러리만 쓰므로 호스트에서 그냥 돌아간다.

  사용법: python3 scripts/report.py
"""
import glob
import json
import os

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(HERE, "results")


def load(pattern):
    out = []
    for p in sorted(glob.glob(os.path.join(RES, pattern))):
        with open(p) as f:
            out.append(json.load(f))
    return out


def mb(v):
    return f"{v//1024}G" if v >= 1024 and v % 1024 == 0 else f"{v}M"


def peak(rows, lo=None, hi=None):
    """구간(없으면 전체)에서 관측된 최대 지연. 초당 p99로 보면 한 건짜리 정지가 묻힌다."""
    v = [float(r["max_ms"]) for r in rows
         if (lo is None or lo <= int(r["sec"]) < hi)]
    return max(v) if v else 0.0


sweep = sorted(load("sweep-*.json"), key=lambda r: (r["dist"], r["buffer_pool_mb"]))
uni = [r for r in sweep if r["dist"] == "uniform"]
hot = [r for r in sweep if r["dist"] == "hot"]
images = []

if sweep:
    data_mb = None
    env = os.path.join(RES, "00-env.txt")
    if os.path.exists(env):
        for line in open(env):
            if line.startswith("데이터 크기"):
                data_mb = int(line.split()[-1].rstrip("MB"))

    print("=" * 78)
    print("실험 1  크기축 스윕" + (f"   (데이터 {data_mb}MB)" if data_mb else ""))
    print("=" * 78)
    for name, rows in (("균등 분포 (워킹셋 = 테이블 전체)", uni), (None, hot)):
        if not rows:
            continue
        if name is None:
            s = rows[0]
            name = (f"핫셋 분포 (조회 {s['hot_prob']*100:.0f}%가 id 하위 "
                    f"{s['hot_frac']*100:.0f}%, 워킹셋 약 {round(1424*s['hot_frac'])}MB)")
        print(f"\n{name}")
        print(f"{'버퍼 풀':>8}{'히트율':>10}{'조회당읽기':>12}{'q/s':>9}"
              f"{'p50':>10}{'p95':>10}{'p99':>10}")
        print("-" * 78)
        for r in rows:
            # 히트율은 페이지 접근 기준이라 B-Tree 상위 페이지 적중이 섞여 바닥이 높다.
            # 조회 하나가 디스크를 몇 페이지 건드렸는지가 체감에 훨씬 가깝다.
            per_q = r["disk_reads"] / r["queries"] if r["queries"] else 0
            print(f"{mb(r['buffer_pool_mb']):>8}{r['hit_rate_pct']:>9.2f}%{per_q:>12.3f}"
                  f"{r['qps']:>9,.0f}{r['p50_ms']:>8.2f}ms{r['p95_ms']:>8.2f}ms"
                  f"{r['p99_ms']:>8.2f}ms")

    for tag, rows, ko in (("uniform", uni, "균등 분포"), ("hot", hot, "핫셋 분포")):
        if not rows:
            continue
        best = min(r["p95_ms"] for r in rows)
        worst = max(r["p95_ms"] for r in rows)
        images.append({
            "type": "bar", "out": f"0{2 if tag=='uniform' else 3}-p95-{tag}.png",
            "title": f"버퍼 풀 크기별 조회 지연 P95 · {ko}",
            "bars": [{"label": mb(r["buffer_pool_mb"]), "value": round(r["p95_ms"], 2),
                      "color": "red" if r["p95_ms"] == worst else
                               ("green" if r["p95_ms"] == best else "fg")} for r in rows],
            # 각주는 실행 조건을 결과 JSON에서 그대로 읽어 쓴다. 손으로 적으면 조건이
            # 바뀌었을 때 그림 안의 문구만 옛것으로 남는다(실제로 "6스레드"가 그랬다).
            "note": (f"MySQL {rows[0]['mysql_version']}, 부하 프로세스 {rows[0]['procs']}개로 "
                     f"PK 점조회, 워밍업 {rows[0]['warmup_s']}초 뒤 "
                     f"{rows[0]['duration_s']}초 측정. 값은 밀리초")})
        images.append({
            "type": "bar", "out": f"0{4 if tag=='uniform' else 5}-hitrate-{tag}.png",
            "title": f"버퍼 풀 크기별 히트율 · {ko}",
            "bars": [{"label": mb(r["buffer_pool_mb"]), "value": round(r["hit_rate_pct"], 2),
                      "color": "green" if r["hit_rate_pct"] >= 99.9 else
                               ("red" if r["hit_rate_pct"] < 90 else "yellow")} for r in rows],
            "note": "누적 카운터 차이로 계산. (1 - Innodb_buffer_pool_reads / read_requests) x 100"})
        images.append({
            "type": "bar", "out": f"0{8 if tag=='uniform' else 9}-perquery-{tag}.png",
            "title": f"조회 한 건이 디스크에서 읽은 페이지 수 · {ko}",
            "bars": [{"label": mb(r["buffer_pool_mb"]),
                      "value": round(r["disk_reads"] / r["queries"], 3) if r["queries"] else 0,
                      "color": "green" if r["disk_reads"] / max(r["queries"], 1) < 0.01 else
                               ("red" if r["disk_reads"] / max(r["queries"], 1) > 0.5 else "yellow")}
                     for r in rows],
            "note": "같은 데이터의 히트율 그래프와 나란히 볼 것. 히트율은 B-Tree 상위 페이지 적중이 섞여 바닥이 높다"})

if sweep:
    # 히트율의 바닥이 왜 높은지를 수치로 보인다. read_requests는 쿼리가 아니라 페이지 접근을
    # 세므로, 조회당 페이지 접근 수를 알아야 히트율을 읽을 수 있다. 데이터가 전부 캐시된
    # 조건에서 이 값이 곧 B-Tree 깊이다.
    print("\n" + "=" * 78)
    print("히트율의 바닥: 조회 한 건이 만지는 페이지 수")
    print("=" * 78)
    print(f"\n{'조건':>16}{'조회당 페이지접근':>18}{'조회당 디스크읽기':>18}"
          f"{'1 - 나눗셈':>12}{'측정 히트율':>12}")
    print("-" * 78)
    for r in sweep:
        acc = r["read_requests"] / r["queries"]
        rd = r["disk_reads"] / r["queries"]
        print(f"{r['label']:>16}{acc:>18.3f}{rd:>18.3f}"
              f"{(1 - rd / acc) * 100:>11.2f}%{r['hit_rate_pct']:>11.2f}%")
    full = [r for r in sweep if r["disk_reads"] == 0]
    if full:
        avg = sum(r["read_requests"] / r["queries"] for r in full) / len(full)
        print(f"\n디스크 읽기가 0인 조건 {len(full)}개의 평균 페이지 접근 {avg:.3f}회. "
              f"PK 조회가 타는 B-Tree 단계 수다.")

resize = {}
for name in ("control", "grow-128M-to-2G", "shrink-2G-to-128M"):
    p = os.path.join(RES, f"resize-{name}.json")
    if os.path.exists(p):
        with open(p) as f:
            resize[name] = json.load(f)
        tl = os.path.join(RES, f"resize-{name}-timeline.csv")
        if os.path.exists(tl):
            with open(tl) as f:
                hdr = f.readline().strip().split(",")
                resize[name]["timeline"] = [dict(zip(hdr, ln.strip().split(",")))
                                            for ln in f if ln.strip()]

if resize:
    print("\n" + "=" * 78)
    print("실험 2  부하 중 온라인 리사이즈")
    print("=" * 78)
    print(f"\n{'조건':>22}{'문장 반환':>10}{'상태 안정':>10}"
          f"{'리사이즈 직후 5초':>18}{'그 밖의 구간':>14}")
    print("-" * 78)
    bars = []
    for name, ko in (("control", "대조군 (리사이즈 없음)"),
                     ("grow-128M-to-2G", "128M -> 2G 확대"),
                     ("shrink-2G-to-128M", "2G -> 128M 축소")):
        r = resize.get(name)
        if not r:
            continue
        act = r.get("action") or {}
        tl = r.get("timeline", [])
        at = int(act.get("stmt_start_s", 30))
        # 리사이즈 창의 최대 지연을, 같은 실행의 나머지 구간 최대 지연과 나란히 본다.
        # 창 밖에서 더 큰 값이 나온다면 그 정지는 리사이즈 탓이라고 말할 수 없다.
        inside = peak(tl, at, at + 5) if tl else 0.0
        outside = max([float(x["max_ms"]) for x in tl
                       if not (at <= int(x["sec"]) < at + 5)] or [0.0]) if tl else 0.0
        stmt = f"{act['stmt_ms']:.0f}ms" if act else "-"
        settle = f"{act['settle_s']:.1f}초" if act else "-"
        print(f"{ko:>22}{stmt:>10}{settle:>10}{inside:>16.1f}ms{outside:>12.1f}ms")
        if act:
            short = "확대" if "grow" in name else "축소"
            bars.append({"label": f"{short} 직후", "value": round(inside, 1),
                         "color": "red" if inside > outside else "yellow"})
            bars.append({"label": f"{short} 그 밖", "value": round(outside, 1),
                         "color": "dim"})
    if bars:
        images.append({
            "type": "bar", "out": "06-resize-stall.png",
            "title": "리사이즈 직후 5초의 최대 지연 vs 같은 실행의 나머지 구간",
            "bars": bars,
            "note": "확대는 128M에서 2G로, 축소는 2G에서 128M로. 핫셋 부하를 건 채로 실행. 단위는 밀리초"})

pc = {}
for fm in ("O_DIRECT", "fsync"):
    p = os.path.join(RES, f"pagecache-{fm}.json")
    if os.path.exists(p):
        with open(p) as f:
            pc[fm] = json.load(f)

def to_mb(s):
    """docker stats의 '3.32GB / 34.9MB'에서 읽기 쪽을 MiB로.

    docker stats는 SI 접두어를 쓴다. GB는 10^9바이트이지 2^30이 아니다.
    비교 대상인 workload.py의 data_read_mb는 바이트를 1024로 두 번 나눈
    2진 MiB라, 같은 축에 놓으려면 SI 바이트를 2^20으로 나눠야 한다.
    구판은 GB에 1024를 곱해 약 7% 부풀렸고 그래서 2,427이라는 값이 나왔다.
    """
    v = s.split("/")[0].strip()
    MIB = 1024 * 1024
    for suf, si in (("GB", 10 ** 9), ("MB", 10 ** 6), ("kB", 10 ** 3), ("B", 1)):
        if v.endswith(suf):
            return float(v[:-len(suf)]) * si / MIB
    return 0.0


if pc:
    print("\n" + "=" * 78)
    print("실험 3  같은 히트율, 다른 지연 (flush_method, 버퍼 풀 256M 고정)")
    print("=" * 78)
    print(f"\n{'flush_method':>13}{'히트율':>9}{'q/s':>9}{'p50':>9}{'p95':>9}"
          f"{'InnoDB 읽기':>13}{'실제 블록읽기':>14}")
    print("-" * 78)
    blk_mb = {}
    for fm, r in pc.items():
        t0 = os.path.join(RES, f"pagecache-{fm}-blkio-t0.txt")
        t1 = os.path.join(RES, f"pagecache-{fm}-blkio-t1.txt")
        d = "-"
        if os.path.exists(t0) and os.path.exists(t1):
            blk_mb[fm] = to_mb(open(t1).read()) - to_mb(open(t0).read())
            d = f"{blk_mb[fm]:,.0f}MB"
        print(f"{fm:>13}{r['hit_rate_pct']:>8.2f}%{r['qps']:>9,.0f}{r['p50_ms']:>7.2f}ms"
              f"{r['p95_ms']:>7.2f}ms{r['data_read_mb']:>11,.0f}MB{d:>14}")
    if blk_mb:
        images.append({
            "type": "bar", "out": "10-blockio.png",
            "title": "측정 창 60초 동안 블록 디바이스에서 실제로 읽은 양",
            "bars": [{"label": fm, "value": round(v), "color": "red" if v > 100 else "green"}
                     for fm, v in blk_mb.items()],
            "note": "두 조건의 버퍼 풀 히트율은 79.09%와 79.15%로 같다. 단위는 MB"})
    images.append({
        "type": "bar", "out": "07-flush-method.png",
        "title": "같은 버퍼 풀 256M, flush_method만 다를 때 P95",
        "bars": [{"label": fm, "value": round(r["p95_ms"], 2),
                  "color": "red" if fm == "O_DIRECT" else "green"} for fm, r in pc.items()],
        "note": "히트율은 두 조건이 사실상 같다. 차이는 miss가 디스크로 가느냐 페이지 캐시로 가느냐다"})

if images:
    with open(os.path.join(RES, "render.json"), "w") as f:
        json.dump({"images": images}, f, ensure_ascii=False, indent=2)
    print(f"\nrender.json 작성: 이미지 {len(images)}장")
