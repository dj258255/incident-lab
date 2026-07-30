#!/usr/bin/env python3
"""README 의 "못 한 것" 두 항목을 잰다.

  1) COLLATE 명시로 문자셋 불일치를 임시로 넘길 수 있는가
  2) 결과 집합 크기를 바꿔 가며 배수 곡선을 그린다

1번은 실무에서 자주 나오는 임시 처방이다. 두 테이블의 콜레이션이 다를 때 스키마를
바꾸지 않고 조인 조건에 COLLATE 를 붙여 비교를 성립시킨다. 그것이 인덱스를 살리는지,
아니면 문법만 통과하고 여전히 못 타는지를 본다.

2번은 이 세션의 배수(3924배, 75배, 2배, 5배, 22배)가 결과 집합 크기에 크게 좌우된다는
의심에서 나왔다. 같은 조건에서 LIMIT 만 바꿔 곡선을 그린다.
"""
import argparse
import json
import statistics
import time

import pymysql

p = argparse.ArgumentParser()
p.add_argument("--out", required=True)
p.add_argument("--repeat", type=int, default=5)
args = p.parse_args()

c = pymysql.connect(host="127.0.0.1", port=13313, user="root", password="lab",
                    database="spoon", autocommit=True)
cur = c.cursor()
out = {}
cur.execute("SELECT VERSION()")
out["mysql"] = cur.fetchone()[0]


def timed(sql, n=None):
    """n회 실행해 중앙값 ms 를 돌려준다. 첫 회는 워밍업으로 버린다."""
    n = n or args.repeat
    lat = []
    for i in range(n + 1):
        t0 = time.perf_counter()
        cur.execute(sql)
        cur.fetchall()
        ms = (time.perf_counter() - t0) * 1000
        if i:
            lat.append(ms)
    return round(statistics.median(lat), 1), round(min(lat), 1), round(max(lat), 1)


def plan(sql):
    cur.execute("EXPLAIN " + sql)
    r = cur.fetchall()
    # EXPLAIN 컬럼 순서: id, select_type, table, partitions, type,
    #   possible_keys, key, key_len, ref, rows, filtered, Extra
    # 처음에 partitions 를 type 으로, possible_keys 를 key 로 읽어 전부 None 이 나왔다.
    return [{"table": x[2], "type": x[4], "key": x[6], "rows": x[9], "extra": x[11]} for x in r]


# ── 1) COLLATE 명시 ─────────────────────────────────────────────────────
WIN = ("o.created_at >= '2026-01-02 00:00:00' AND o.created_at < '2026-01-02 00:10:00'")
Q_BAD = f"SELECT COUNT(*) FROM orders o JOIN order_legacy l ON o.order_no = l.order_no WHERE {WIN}"
Q_FIX = f"SELECT COUNT(*) FROM orders o JOIN order_legacy_fixed l ON o.order_no = l.order_no WHERE {WIN}"
# 임시 처방 둘. 어느 쪽에 COLLATE 를 붙이느냐로 결과가 갈릴 수 있어 둘 다 잰다.
Q_COL_L = (f"SELECT COUNT(*) FROM orders o JOIN order_legacy l "
           f"ON o.order_no = l.order_no COLLATE utf8mb4_0900_ai_ci WHERE {WIN}")
Q_COL_O = (f"SELECT COUNT(*) FROM orders o JOIN order_legacy l "
           f"ON o.order_no COLLATE latin1_swedish_ci = l.order_no WHERE {WIN}")
# COLLATE 가 문자셋을 못 바꾸므로 실무에서 다음으로 잡는 것이 CONVERT 다.
# 이쪽은 문법은 통과한다. 인덱스를 타는지가 이 실험의 답이다.
Q_CONV = (f"SELECT COUNT(*) FROM orders o JOIN order_legacy l "
          f"ON CONVERT(l.order_no USING utf8mb4) = o.order_no WHERE {WIN}")

out["collate"] = {}
for name, q in [("불일치 그대로", Q_BAD), ("스키마를 맞춤", Q_FIX),
                ("COLLATE 를 legacy 쪽에", Q_COL_L), ("COLLATE 를 orders 쪽에", Q_COL_O),
                ("CONVERT USING utf8mb4", Q_CONV)]:
    try:
        med, lo, hi = timed(q)
        out["collate"][name] = {"ms_median": med, "ms_min": lo, "ms_max": hi, "plan": plan(q)}
    except pymysql.Error as e:
        out["collate"][name] = {"error": f"{e.args[0]} {e.args[1][:80]}"}

# ── 2) 결과 집합 크기별 배수 곡선 ───────────────────────────────────────
# 인덱스를 타는 조건과 못 타는 조건을 같은 결과 집합 크기에서 나란히 잰다.
# 못 타는 쪽은 함수 적용(DATE), 타는 쪽은 범위로 고쳐 쓴 것이다.
# LIMIT 로 결과 집합만 바꾸고 나머지는 고정한다.
out["curve"] = []
for lim in (1, 10, 100, 1000, 10000, 100000, 500000):
    bad = f"SELECT id FROM orders WHERE DATE(created_at) = '2026-01-02' LIMIT {lim}"
    good = (f"SELECT id FROM orders WHERE created_at >= '2026-01-02' "
            f"AND created_at < '2026-01-03' LIMIT {lim}")
    b, _, _ = timed(bad, 3)
    g, _, _ = timed(good, 3)
    out["curve"].append({
        "limit": lim, "bad_ms": b, "good_ms": g,
        "ratio": round(b / g, 1) if g else None,
        "bad_type": plan(bad)[0]["type"], "good_type": plan(good)[0]["type"],
    })

with open(args.out, "w") as f:
    json.dump(out, f, ensure_ascii=False, indent=1)

print(f"# MySQL {out['mysql']}\n")
print("## 1) COLLATE 명시로 문자셋 불일치를 넘길 수 있는가")
for k, v in out["collate"].items():
    if "error" in v:
        print(f"  {k:24} 에러 {v['error']}")
    else:
        pl = v["plan"][-1]
        print(f"  {k:24} {v['ms_median']:>9.1f}ms  "
              f"(범위 {v['ms_min']}~{v['ms_max']})  type={pl['type']} key={pl['key']}")
print()
print("## 2) 결과 집합 크기별 배수 곡선")
print(f"  {'LIMIT':>8} {'함수적용(ms)':>13} {'범위(ms)':>11} {'배수':>7}  타입")
for r in out["curve"]:
    print(f"  {r['limit']:>8} {r['bad_ms']:>13.1f} {r['good_ms']:>11.1f} {r['ratio']:>7}  "
          f"{r['bad_type']} / {r['good_type']}")
