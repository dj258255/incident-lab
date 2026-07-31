#!/usr/bin/env python3
"""복제 대조 회차별 로그를 읽어 표로 만든다.

이걸 따로 둔 이유가 있다. 원래는 셸에서 이렇게 뽑았다.

    grep -oE "${m}[^0-9]*([0-9.]+)초" "$LOG"

`[^0-9]*` 가 "single" 과 시간 사이를 건너뛰게 한 것인데, 실제 로그의 그 사이에는
`(mode=atomic slots=0)` 이 있고 거기에 숫자 0 이 들어 있다. 그래서 한 건도 안 잡히고
"회차 값을 못 뽑았습니다" 만 남았다. 로그는 멀쩡히 있는데 표만 비었다.

로그를 절 단위로 갈라 읽는다. 이미 남아 있는 로그로 다시 돌릴 수 있다.

    python3 scripts/summarize-replica-repeat.py results/replica-run*.log
"""
import os
import re
import statistics
import sys

FIELDS = [
    ("rps", re.compile(r"원본 처리량 초당 ([\d.]+)건")),
    ("src_sum", re.compile(r"원본 합계 (\d+)")),
    ("behind", re.compile(r"뒤처진 양 (\d+)")),
    ("sbs", re.compile(r"Seconds_Behind_Source = (-?\d+)")),
    ("catchup", re.compile(r"따라잡기까지 ([\d.]+)초")),
]
SECTION = re.compile(r"^## (single|slot64)")


def parse(path):
    """한 회차 로그에서 조건별 값을 뽑는다."""
    out = {}
    cur = None
    for line in open(path, encoding="utf-8", errors="replace"):
        m = SECTION.match(line)
        if m:
            cur = m.group(1)
            out.setdefault(cur, {})
            continue
        if cur is None:
            continue
        for key, rx in FIELDS:
            mm = rx.search(line)
            if mm:
                out[cur][key] = float(mm.group(1))
    return out


paths = [p for p in sys.argv[1:] if os.path.exists(p)]
if not paths:
    sys.exit("로그 파일을 못 찾았습니다")

runs = [parse(p) for p in paths]
labels = []
for r in runs:
    for k in r:
        if k not in labels:
            labels.append(k)

print(f"  {'조건':<10} {'회차별 따라잡기':<26} {'중앙':>9} {'폭':>9} {'뒤처진 양 중앙':>16}")
med = {}
for lab in labels:
    xs = [r[lab]["catchup"] for r in runs if lab in r and "catchup" in r[lab]]
    bs = [r[lab]["behind"] for r in runs if lab in r and "behind" in r[lab]]
    if not xs:
        print(f"  {lab:<10} 값 없음")
        continue
    med[lab] = statistics.median(xs)
    print(f"  {lab:<10} {str([round(x, 2) for x in xs]):<26} "
          f"{statistics.median(xs):>8.2f}초 {max(xs) - min(xs):>8.2f}초 "
          f"{statistics.median(bs) if bs else 0:>15,.0f}")

if "single" in med and "slot64" in med and med["single"]:
    print()
    print(f"  따라잡기 배수 중앙 {med['slot64'] / med['single']:.2f}배")
    print("  슬롯을 쓰면 원본의 한 논리 갱신이 여러 행 갱신이 됩니다.")
    print("  복제본은 그 행들을 전부 다시 적용하므로 따라잡는 데 더 걸립니다.")
    print("  원본 처리량을 사는 대가가 복제 지연이라는 것이 이 표의 요지입니다.")

for lab in labels:
    xs = [r[lab].get("rps") for r in runs if lab in r and r[lab].get("rps")]
    if xs:
        print(f"  {lab} 원본 처리량 회차별 {[round(x) for x in xs]} 중앙 {statistics.median(xs):.0f}/s")
print()
print(f"  회차 {len(runs)}회입니다.")
