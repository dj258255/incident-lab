#!/usr/bin/env python3
"""README 의 "못 한 것" 하나를 잰다.

  OR 조건과 index merge 는 다루지 않았습니다
  "다섯 가지로 좁혔고, OR 은 옵티마이저 버전에 따라 동작이 갈려 별도 세션이 낫습니다."

별도 세션이 낫다고 미뤄 뒀는데, 이 세션의 표에 넣을 수 있는 부분이 있다. 이 세션의
주제는 "인덱스가 있는데 안 탄다" 이고, OR 은 그 대표적인 자리다. 두 컬럼에 각각
인덱스가 있어도 OR 로 묶으면 옵티마이저가 index merge 를 고를 수도, 통째로 훑을 수도
있다. 어느 쪽을 고르는지와 그때의 대가를 잰다.

네 가지를 나란히 놓는다.
  1) OR 그대로
  2) UNION 으로 손으로 가른 것
  3) index merge 를 강제한 것
  4) index merge 를 끈 것

MySQL 은 optimizer_switch 로 index_merge 를 켜고 끌 수 있으므로, 옵티마이저가 그것을
쓸 때와 안 쓸 때를 같은 데이터에서 직접 비교할 수 있다.
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
import time

import pymysql

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="results/or-and-index-merge.json")
ap.add_argument("--repeat", type=int, default=5)
args = ap.parse_args()

conn = pymysql.connect(host="127.0.0.1", port=13313, user="root", password="lab",
                       database="spoon", autocommit=True)
cur = conn.cursor()


def scalar(sql):
    cur.execute(sql)
    r = cur.fetchone()
    return r[0] if r else None


def ensure_seeded():
    """러너가 단계마다 볼륨까지 지우므로 표는 있어도 비어 있다.

    처음에는 비면 그냥 멈추게 하고 적재는 exp-convert-side.py 에 맡겼는데,
    두 스크립트가 서로 다른 단계로 돌기 때문에 이 쪽이 먼저 오면 항상 멈춘다.
    실제로 그렇게 났다. 각자 자기 적재를 책임진다.
    """
    cur.execute("SELECT COUNT(*) FROM information_schema.TABLES "
                "WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='orders'")
    if cur.fetchone()[0] == 0:
        sys.exit("중단: orders 표가 없습니다. compose 의 initdb 가 돌지 않았습니다")
    cur.execute("SELECT COUNT(*) FROM orders")
    n = cur.fetchone()[0]
    if n:
        return n
    print("orders 가 비어 있습니다. seed.py 를 먼저 돌립니다.", flush=True)
    subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                 "seed.py")], check=True)
    cur.execute("SELECT COUNT(*) FROM orders")
    n = cur.fetchone()[0]
    if n == 0:
        sys.exit("중단: 적재 후에도 orders 가 비어 있습니다")
    print(f"적재 완료 {n:,}행", flush=True)
    return n


total = ensure_seeded()


def explain(sql):
    cur.execute("EXPLAIN " + sql)
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def timeit(sql, repeat=None):
    repeat = repeat or args.repeat
    cur.execute(sql)
    cur.fetchall()
    xs = []
    for _ in range(repeat):
        t0 = time.perf_counter()
        cur.execute(sql)
        rows = cur.fetchall()
        xs.append((time.perf_counter() - t0) * 1000)
    return round(statistics.median(xs), 2), rows[0][0] if rows else None


def plan_of(sql):
    rs = explain(sql)
    r = rs[0]
    return f"{r['type']} / {r.get('key') or '인덱스없음'}", int(r.get("rows") or 0)


out = {"total_rows": total}
print("# OR 조건과 index merge")
print(f"# MySQL {scalar('SELECT VERSION()')}, orders {total:,}행")
print(f"# 시간은 {args.repeat}회 중앙값입니다.")
print()

# 두 컬럼에 각각 인덱스가 있는 조건을 고른다.
# idx_created (created_at) 와 idx_buyer (buyer_name) 둘 다 있다.
CUT = scalar("SELECT DATE_ADD(MIN(created_at), INTERVAL 1 HOUR) FROM orders")
NAME = scalar("SELECT buyer_name FROM orders LIMIT 1")

OR_SQL = (f"SELECT COUNT(*) FROM orders "
          f"WHERE created_at < '{CUT}' OR buyer_name = '{NAME}'")
UNION_SQL = (
    f"SELECT COUNT(*) FROM ("
    f"  SELECT id FROM orders WHERE created_at < '{CUT}'"
    f"  UNION"
    f"  SELECT id FROM orders WHERE buyer_name = '{NAME}'"
    f") t")
LEFT_SQL = f"SELECT COUNT(*) FROM orders WHERE created_at < '{CUT}'"
RIGHT_SQL = f"SELECT COUNT(*) FROM orders WHERE buyer_name = '{NAME}'"

print("==================================================================")
print("## 1) 한쪽씩 걸면 인덱스를 탑니다")
print("==================================================================")
print(f"  {'조건':<26} {'중앙값':>10} {'계획':<28} {'훑는 행':>12} {'결과':>12}")
for label, sql in (("created_at 만", LEFT_SQL), ("buyer_name 만", RIGHT_SQL)):
    ms, cnt = timeit(sql)
    plan, rows = plan_of(sql)
    print(f"  {label:<26} {ms:>9.1f}ms {plan:<28} {rows:>12,} {cnt:>12,}")
    out[label] = {"ms": ms, "plan": plan, "rows": rows, "count": cnt}

print()
print("==================================================================")
print("## 2) OR 로 묶으면 무엇을 고르는가")
print("==================================================================")


def switch(index_merge_on):
    v = "on" if index_merge_on else "off"
    cur.execute(f"SET SESSION optimizer_switch='index_merge={v},"
                f"index_merge_union={v},index_merge_sort_union={v},"
                f"index_merge_intersection={v}'")


rows_out = []
for label, sql, im in (("OR (index_merge 켬)", OR_SQL, True),
                       ("OR (index_merge 끔)", OR_SQL, False),
                       ("UNION 으로 손으로 가름", UNION_SQL, True)):
    switch(im)
    ms, cnt = timeit(sql)
    rs = explain(sql)
    plan = " + ".join(f"{r['type']}/{r.get('key') or '없음'}" for r in rs)
    prod = 1
    for r in rs:
        prod *= max(1, int(r.get("rows") or 1))
    rows_out.append({"label": label, "ms": ms, "plan": plan, "rows": prod, "count": cnt})
    print(f"  {label:<26} {ms:>9.1f}ms  결과 {cnt:>10,}")
    print(f"    계획: {plan}")
    print(f"    EXPLAIN rows 곱 {prod:,}")
switch(True)
out["or_cases"] = rows_out

print()
counts = {r["count"] for r in rows_out}
if len(counts) == 1:
    print(f"  세 방식이 모두 {counts.pop():,}건을 돌려줍니다. 같은 질문입니다.")
else:
    print(f"  경고: 결과 건수가 다릅니다 {counts}. 같은 질문이 아니므로 시간 비교가 성립하지 않습니다.")

base = next((r for r in rows_out if r["label"] == "OR (index_merge 끔)"), None)
if base and base["ms"]:
    print()
    print(f"  {'방식':<26} {'index_merge 끔 대비':>20}")
    for r in rows_out:
        print(f"  {r['label']:<26} {base['ms'] / r['ms']:>19.2f}배")

print()
print("  index merge 는 두 인덱스를 각각 훑어 결과를 합칩니다. 합치는 비용이 있으므로")
print("  각 조건의 선택도가 낮을 때만 값을 합니다. 한쪽이 넓으면 통째로 훑는 것이 낫습니다.")
print("  UNION 으로 가르면 옵티마이저가 두 질의를 따로 계획하므로 각각 인덱스를 씁니다.")
print("  대신 중복 제거가 붙습니다.")

os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
with open(args.out, "w") as f:
    json.dump(out, f, ensure_ascii=False, indent=1)
print()
print(f"  각 조건 1회 실행이고 시간은 {args.repeat}회 중앙값입니다.")
print(f"원문: {args.out}")
