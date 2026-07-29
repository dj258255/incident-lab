#!/usr/bin/env python3
"""조건별 결과를 표로 내고 results/render.json을 만든다. 표준 라이브러리만 쓴다."""
import json
import os

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(HERE, "results")

ORDER = ["control", "ddl-alone", "ddl-timeout", "ddl-default"]
KO = {"control": "롱 트랜잭션만 (DDL 없음)",
      "ddl-alone": "DDL만 (롱 트랜잭션 없음)",
      "ddl-timeout": "겹침 + lock_wait_timeout 2초",
      "ddl-default": "겹침 + 기본 타임아웃"}
SHORT = {"control": "롱txn만", "ddl-alone": "DDL만",
         "ddl-timeout": "겹침+2초", "ddl-default": "겹침+기본"}

cases = {}
for c in ORDER:
    p = os.path.join(RES, f"case-{c}.json")
    if os.path.exists(p):
        with open(p) as f:
            cases[c] = json.load(f)
arms = [c for c in ORDER if c in cases]
if not arms:
    raise SystemExit("results/case-*.json 이 없습니다")

one = cases[arms[0]]
print("=" * 80)
print(f"A02 메타데이터 락 폭풍   (MySQL {one['mysql_version']}, {one['rows']:,}행, "
      f"조회 프로세스 {one['procs']}개, {one['duration_s']}초)")
print(f"일정: {one['schedule']['long_at']}초 롱 트랜잭션 시작, "
      f"{one['schedule']['ddl_at']}초 DDL 실행, {one['schedule']['long_end']}초 롱 트랜잭션 커밋")
print("=" * 80)
print(f"\n{'조건':>26}{'DDL 전 초당':>12}{'전면 정지':>10}{'0건인 초':>10}{'최대 지연':>12}{'DDL 결과':>22}")
print("-" * 92)

stall_bars, ddl_bars, lat_bars = [], [], []
zeros = {}
for c in arms:
    d = cases[c]
    mx = max((t["max_ms"] or 0) for t in d["timeline"])
    # 완료 건수가 정확히 0인 초. "정지"(기준선의 10% 미만)와 같지 않다.
    # 마지막 초는 측정 창 경계라 mdl.py의 정지 판정에서 빠지므로 여기서도 뺀다.
    zsecs = [t["sec"] for t in d["timeline"]
             if t["count"] == 0 and t["sec"] < d["duration_s"] - 1]
    zeros[c] = zsecs
    ddl = d.get("ddl")
    if not ddl:
        dtxt = "실행 안 함"
        dval = 0
    elif ddl["ok"]:
        dtxt = f"성공, {ddl['elapsed_s']}초"
        dval = ddl["elapsed_s"]
    else:
        code = ddl["error"].split(",")[0].strip("( ")
        dtxt = f"실패({code}), {ddl['elapsed_s']}초"
        dval = ddl["elapsed_s"]
    print(f"{KO[c]:>26}{d['median_qps']:>11,}건{d['stall_len_s']:>9}초{len(zsecs):>9}초"
          f"{mx:>10,.0f}ms{dtxt:>22}")
    bad = d["stall_len_s"] > 5
    stall_bars.append({"label": SHORT[c], "value": d["stall_len_s"],
                       "color": "red" if bad else ("yellow" if d["stall_len_s"] else "green")})
    lat_bars.append({"label": SHORT[c], "value": round(mx),
                     "color": "red" if mx > 5000 else "green"})
    if ddl:
        ddl_bars.append({"label": SHORT[c], "value": dval,
                         "color": "green" if ddl["ok"] and dval < 1 else
                                  ("yellow" if not ddl["ok"] else "red")})

print("-" * 92)
print("'DDL 전 초당'은 0초부터 ddl_at(25초) 직전까지 초당 완료 건수의 중앙값이다.")
print("네 조건 모두 개입이 들어가기 전 구간이므로 조건 사이의 차이는 설정의 효과가 아니라")
print("실행 간 편차다. 처리량 비교에 쓰지 말 것.")
print("'전면 정지'는 완료 건수가 그 기준선의 10% 아래인 초, '0건인 초'는 완료가 정확히 0인 초다.")
for c in arms:
    z = zeros[c]
    span = ("없음" if not z else
            f"{z[0]}초" if z[0] == z[-1] else f"{z[0]}~{z[-1]}초")
    print(f"  {KO[c]:>26}  정지 {cases[c]['stall_len_s']}초 / 0건 {len(z)}초 ({span})")

# 대기 큐 증거: 정지 구간의 메타데이터 락 스냅샷
print("\n메타데이터 락 (performance_schema.metadata_locks, 정지 구간)")
print("-" * 80)
for c in arms:
    d = cases[c]
    # DDL 실행 이후의 스냅샷만 본다. 그 앞에도 조회끼리 순간 대기가 잡힐 때가 있는데
    # 그건 이 세션이 보려는 대기가 아니다.
    hit = [s for s in d["lock_snapshots"]
           if s["pending"] > 0 and s["at_s"] >= d["schedule"]["ddl_at"]]
    if hit:
        s = hit[0]
        print(f"{KO[c]:>26}  {s['at_s']}초  granted {s['granted']} / pending {s['pending']}")
        for t in s["types"]:
            print(f"{'':28}  {t}")
    else:
        print(f"{KO[c]:>26}  대기 중인 락 없음")

# 정지 구간을 콘솔 카드로. 완료 건수가 0인 초가 표에 남아 있어야 정지가 보인다.
d = cases.get("ddl-default")
lines = []
if d:
    lines.append("$ 초당 완료 건수와 지연 (겹침 + 기본 타임아웃)")
    lines.append("")
    lines.append(" 초   완료건수      p50       최대")
    for t in d["timeline"]:
        if not (22 <= t["sec"] <= 46):
            continue
        if t["count"] == 0:
            lines.append([[f"{t['sec']:3d}        0        -          - ", "red"],
                          ["  <- 완료된 조회 없음", "red"]])
        else:
            seg = f"{t['sec']:3d} {t['count']:8,d} {t['p50_ms']:8.2f}ms {t['max_ms']:9.1f}ms"
            color = "yellow" if t["max_ms"] > 5000 else "fg"
            lines.append([[seg, color]])
    lines.append("")
    ev = [e for e in d["events"]]
    for e in ev:
        lines.append([[f"  {e['at_s']:5.1f}초  {e['kind']}: {e['msg']}", "dim"]])

images = [
    {"type": "bar", "out": "01-stall.png",
     "title": "완료 건수가 DDL 이전 중앙값의 10% 아래로 떨어진 시간 (초)",
     "bars": stall_bars,
     "note": ("네 조건 모두 같은 부하, 같은 일정. 25초에 ALTER TABLE ADD COLUMN 실행. "
              "완료가 정확히 0건인 초는 겹침+기본 19개(26~44초), 겹침+2초 1개(26초)")},
    {"type": "bar", "out": "02-latency.png",
     "title": "조회 한 건이 기다린 최대 시간 (밀리초)",
     "bars": lat_bars,
     "note": "막힌 조회는 롱 트랜잭션이 커밋될 때까지 기다렸다가 돌아온다"},
]
if ddl_bars:
    images.append({"type": "bar", "out": "03-ddl.png",
                   "title": "ALTER TABLE 문장이 반환되기까지 걸린 시간 (초)",
                   "bars": ddl_bars,
                   "note": "DDL 자체는 0.09초짜리다. 나머지는 전부 락을 기다린 시간이다"})
if lines:
    images.insert(0, {"type": "term", "out": "00-timeline.png",
                      "title": "MDL 폭풍 구간", "lines": lines})

with open(os.path.join(RES, "render.json"), "w") as f:
    json.dump({"images": images}, f, ensure_ascii=False, indent=2)
print(f"\nrender.json 작성: 이미지 {len(images)}장")
