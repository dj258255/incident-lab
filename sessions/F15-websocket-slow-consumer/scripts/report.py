#!/usr/bin/env python3
"""results/summary.csv에서 모드별 중앙값을 뽑고 results/render.json을 만든다.

회차가 3회씩이므로 표에는 중앙값을 쓴다. 평균을 쓰면 terminate 조건처럼 회차 간 편차가
큰 모드에서 한 회차가 값을 끌고 간다. 편차 자체는 README에서 따로 적는다.

표준 라이브러리만 쓴다.
"""
import csv
import json
import os
import statistics

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(HERE, "results")

ORDER = ["baseline", "direct", "direct-stalled", "unbounded", "bounded", "conflate",
         "terminate", "terminate-tight", "decorator", "combo", "combo-stalled"]
KO = {
    "baseline": "대조군 (느린 구독자 없음)",
    "direct": "직접 전송 (느린 구독자 1)",
    "direct-stalled": "직접 전송 (완전 정지 구독자)",
    "unbounded": "무제한 큐",
    "bounded": "바운디드 큐 1000건",
    "conflate": "conflation (종목별 최신만)",
    "terminate": "절단 1MB/3초",
    "terminate-tight": "절단 512KB/1초",
    "decorator": "Spring 데코레이터 512KB",
    "combo": "conflation + 절단",
    "combo-stalled": "conflation + 절단 (완전 정지)",
}
# 막대 라벨은 한 줄이어야 한다. 렌더러가 폭을 재는 Pillow가 여러 줄 문자열의 길이를
# 재지 못해서 줄바꿈을 넣으면 렌더가 죽는다.
SHORT = {
    "baseline": "대조군", "direct": "직접전송", "direct-stalled": "직접전송 정지",
    "unbounded": "무제한큐", "bounded": "바운디드", "conflate": "conflation",
    "terminate": "절단1M/3s", "terminate-tight": "절단512K/1s",
    "decorator": "Spring데코", "combo": "combo", "combo-stalled": "combo 정지",
}

rows = list(csv.DictReader(open(os.path.join(RES, "summary.csv"))))
by = {}
for r in rows:
    by.setdefault(r["mode"], []).append(r)


def med(mode, key):
    vals = [float(x[key]) for x in by[mode] if x[key] not in ("", "n/a")]
    return statistics.median(vals) if vals else 0.0


def closed_at(mode):
    v = [x["slow_closed_at_s"] for x in by[mode]]
    real = [float(x) for x in v if x not in ("", "n/a", "none")]
    if not real:
        return "끊지 않음"
    return f"{statistics.median(real):.1f}초"


arms = [m for m in ORDER if m in by]
runs = len(by[arms[0]])
print("=" * 96)
print(f"F15 슬로우 컨슈머   (정상 구독자 5 + 느린 구독자 1, 초당 3,000틱, 힙 128MB, "
      f"모드마다 {runs}회 중앙값)")
print("=" * 96)
print(f"\n{'조건':>28}{'발행/초':>9}{'힙 최대':>9}{'느린큐':>9}"
      f"{'생산자 정지':>12}{'GC':>8}{'정상 p95':>10}{'OOM':>5}{'느린구독자':>11}")
print("-" * 96)

pub_bars, heap_bars, blocked_bars = [], [], []
for m in arms:
    pub, heap = med(m, "publish_per_s"), med(m, "heap_peak_mb")
    q, blocked = med(m, "slow_queue_peak_mb"), med(m, "broadcast_blocked_ms") / 1000
    gc, p95 = med(m, "gc_ms") / 1000, med(m, "lat_p95_ms")
    oom = med(m, "oom")
    print(f"{KO[m]:>28}{pub:>9,.0f}{heap:>8.1f}M{q:>8.2f}M{blocked:>11.1f}초"
          f"{gc:>7.1f}초{p95:>9.0f}ms{oom:>5.0f}{closed_at(m):>11}")

    healthy = pub > 2500 and oom == 0
    pub_bars.append({"label": SHORT[m], "value": round(pub),
                     "color": "green" if healthy else "red"})
    heap_bars.append({"label": SHORT[m], "value": round(heap, 1),
                      "color": "red" if oom > 0 else "green"})
    blocked_bars.append({"label": SHORT[m], "value": round(blocked, 1),
                         "color": "red" if blocked > 5 else "green"})

print("\n발행/초는 서버가 실제로 만들어 내보낸 틱이다. 대조군 2,909가 정상값이다.")
print("다만 unbounded는 110초, direct-stalled는 세션이 끊기기 전후가 섞인 값이라")
print("다른 조건과 같은 잣대가 아니다. 자세한 것은 reproduce.md를 보라.")
print("생산자 정지는 브로드캐스트 스레드가 전송에 막혀 있던 누적 시간이다.")
print("느린큐는 느린 구독자에게 보내려고 큐에 걸어 둔 페이로드 바이트의 합계다.")
print("힙 점유량이 아니다. 메시지 객체와 큐 노드의 부가 비용은 빠져 있다.")
print("느린구독자 칸은 클라이언트 측정에서 뽑는다. 한 바이트도 안 읽는 클라이언트는")
print("서버가 세션을 닫아도 그것을 감지하지 못하므로 stalled 조건의 '끊지 않음'은")
print("믿으면 안 된다. results/raw/serverlog-*-stalled-*.txt 의 disconnect 줄을 볼 것.")

# 무제한 큐의 힙 증가 곡선
curve = []
p = os.path.join(RES, "raw", "server-unbounded-r1.csv")
if os.path.exists(p):
    src = [l for l in open(p) if not l.startswith("#")]
    for r in csv.DictReader(src):
        if not r["t_s"].isdigit():
            continue
        curve.append(r)

lines = ["$ 무제한 큐, 힙 128MB, 느린 구독자 1명 (unbounded-r1)", ""]
lines.append(" 초   힙(MB)   느린큐(MB)   발행/초    GC(ms)")
for r in curve:
    t = int(r["t_s"])
    if t % 10 and int(r["oom"]) == 0:
        continue
    seg = (f"{t:3d}   {float(r['heap_used_mb']):6.1f}   {float(r['slow_queue_mb']):9.2f}"
           f"   {int(r['published_per_s']):7,d}   {int(r['gc_ms']):7,d}")
    if int(r["oom"]) > 0:
        lines.append([[seg, "red"], ["   <- OutOfMemoryError", "red"]])
    elif float(r["heap_used_mb"]) > 100:
        lines.append([[seg, "yellow"]])
    else:
        lines.append([[seg, "fg"]])
    if int(r["oom"]) > 0:
        break
lines.append("")
lines.append([["  서버 로그: [OOM] thread publisher java.lang.OutOfMemoryError: Java heap space", "red"]])

images = [
    {"type": "term", "out": "00-oom.png", "title": "무제한 큐가 힙을 채우는 과정",
     "lines": lines},
    {"type": "bar", "out": "01-publish.png",
     "title": "서버가 초당 발행한 틱 (대조군 2,909가 정상)",
     "bars": pub_bars,
     "note": f"정상 구독자 5명 + 느린 구독자 1명, 초당 3,000틱 목표, 모드마다 {runs}회 중앙값"},
    {"type": "bar", "out": "02-blocked.png",
     "title": "브로드캐스트 스레드가 전송에 막혀 있던 누적 시간 (초)",
     "bars": blocked_bars,
     "note": "측정 구간은 45초다. 직접 전송은 그중 44초를 막혀 있었다"},
    {"type": "bar", "out": "03-heap.png",
     "title": "서버 힙 사용 최대치 (MB, 상한 128MB)",
     "bars": heap_bars,
     "note": "무제한 큐만 상한에 닿아 OutOfMemoryError로 끝났다"},
]

with open(os.path.join(RES, "render.json"), "w") as f:
    json.dump({"images": images}, f, ensure_ascii=False, indent=2)
print(f"\nrender.json 작성: 이미지 {len(images)}장")
