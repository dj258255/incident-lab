#!/usr/bin/env python3
"""README 의 "못 한 것" 세 개를 잰다.

  1) CONVERT 를 조인 반대쪽에 붙인 조건은 재지 않았습니다
     7절은 order_legacy 쪽에만 붙였다. 반대쪽에 붙이면 어느 인덱스가 죽는지 본다.
     이것이 실무에서 갈리는 자리다. CONVERT 를 어디에 붙이느냐로 살아남는 인덱스가
     바뀌고, 큰 테이블 쪽에 붙이면 그 테이블을 통째로 훑게 된다.

  2) 곡선을 함수 적용 조건 하나에서만 그렸습니다
     결과 집합 크기를 바꿔 가며 그린 배수 곡선이 함수 적용 조건에만 있다.
     형변환과 콜레이션 조건에서도 같은 모양인지 본다.

  3) 선행 와일드카드 케이스를 재설계하지 않았습니다
     원 케이스의 buyer_name 은 서로 다른 값이 다섯 개뿐이라 선택도가 40% 였다.
     어떤 인덱스로도 도울 수 없는 조건이라 배수가 인덱스 이야기가 아니었다.
     서로 다른 값이 많은 컬럼으로 다시 짠다.
"""
import json
import statistics
import sys
import time

import pymysql

OUT = sys.argv[1] if len(sys.argv) > 1 else "/results/convert-side.json"
REPEAT = 5

conn = pymysql.connect(host="127.0.0.1", port=13313, user="root", password="lab",
                       database="spoon", autocommit=True)
cur = conn.cursor()


def explain_row(sql):
    cur.execute("EXPLAIN " + sql)
    cols = [d[0] for d in cur.description]
    rows = [dict(zip(cols, r)) for r in cur.fetchall()]
    return rows


def timeit(sql, repeat=REPEAT):
    cur.execute(sql)
    cur.fetchall()                      # 워밍업 한 번
    xs = []
    for _ in range(repeat):
        t0 = time.perf_counter()
        cur.execute(sql)
        cur.fetchall()
        xs.append((time.perf_counter() - t0) * 1000)
    return round(statistics.median(xs), 3), round(min(xs), 3), round(max(xs), 3)


def rows_examined(sql):
    """EXPLAIN 의 rows 를 조인 순서대로 곱한다. 실제 훑은 행 수의 근사치다."""
    prod = 1
    for r in explain_row(sql):
        prod *= max(1, int(r.get("rows") or 1))
    return prod


out = {}

# ── 1) CONVERT 를 어느 쪽에 붙이는가 ────────────────────────────────────
WINDOW = ("WHERE o.created_at >= '2026-01-02 00:00:00' "
          "AND o.created_at < '2026-01-02 00:10:00'")
SIDES = [
    ("붙이지 않음(원래 조건)",
     f"SELECT COUNT(*) FROM orders o JOIN order_legacy l ON o.order_no = l.order_no {WINDOW}"),
    ("작은 쪽(order_legacy)에 붙임",
     "SELECT COUNT(*) FROM orders o JOIN order_legacy l "
     f"ON o.order_no = CONVERT(l.order_no USING utf8mb4) {WINDOW}"),
    ("큰 쪽(orders)에 붙임",
     "SELECT COUNT(*) FROM orders o JOIN order_legacy l "
     f"ON CONVERT(o.order_no USING latin1) = l.order_no {WINDOW}"),
    ("스키마를 고침(대조군)",
     "SELECT COUNT(*) FROM orders o JOIN order_legacy_fixed l "
     f"ON o.order_no = l.order_no {WINDOW}"),
]
print("## 1) CONVERT 를 조인 어느 쪽에 붙이는가")
print(f"  {'조건':<28} {'중앙값':>10} {'EXPLAIN rows 곱':>16}  계획")
conv = []
for label, sql in SIDES:
    try:
        med, lo, hi = timeit(sql)
        plan = explain_row(sql)
        desc = " / ".join(f"{r['table']}:{r['type']}"
                          + (f"({r['key']})" if r.get("key") else "(인덱스없음)")
                          for r in plan)
        rex = rows_examined(sql)
        print(f"  {label:<28} {med:>9.1f}ms {rex:>16,}  {desc}")
        conv.append({"label": label, "sql": sql, "median_ms": med,
                     "min_ms": lo, "max_ms": hi, "rows_product": rex, "plan": desc})
    except Exception as e:
        print(f"  {label:<28} 실패: {type(e).__name__}: {e}")
        conv.append({"label": label, "sql": sql, "error": f"{type(e).__name__}: {e}"})
out["convert_side"] = conv

# ── 2) 곡선을 다른 조건에서도 그린다 ────────────────────────────────────
# 결과 집합 크기를 LIMIT 으로 바꿔 가며 못 타는 쪽과 타는 쪽의 배수를 본다.
print()
print("## 2) 결과 집합 크기별 배수를 세 조건에서")
CURVES = {
    "함수 적용": (
        "SELECT id FROM orders WHERE DATE(created_at) = '2026-01-02' LIMIT {n}",
        "SELECT id FROM orders WHERE created_at >= '2026-01-02' "
        "AND created_at < '2026-01-03' LIMIT {n}",
    ),
    "암묵적 형변환": (
        # 못 타는 쪽은 숫자와 비교해 전체를 훑는다. 결과가 0건이라 LIMIT 이 안 듣는다.
        # 그 자체가 이 조건의 성질이므로 그대로 잰다.
        "SELECT id FROM orders WHERE order_no > 1500000 LIMIT {n}",
        "SELECT id FROM orders WHERE order_no > '1500000' LIMIT {n}",
    ),
    "콜레이션": (
        "SELECT o.id FROM orders o JOIN order_legacy l ON o.order_no = l.order_no LIMIT {n}",
        "SELECT o.id FROM orders o JOIN order_legacy_fixed l ON o.order_no = l.order_no LIMIT {n}",
    ),
}
NS = [1, 100, 10000, 500000]
curves = {}
print(f"  {'조건':<14} {'LIMIT':>8} {'못 타는 쪽':>12} {'타는 쪽':>11} {'배수':>9}")
for name, (bad, good) in CURVES.items():
    pts = []
    for n in NS:
        try:
            mb, _, _ = timeit(bad.format(n=n), repeat=3)
            mg, _, _ = timeit(good.format(n=n), repeat=3)
            mult = round(mb / mg, 1) if mg else None
            print(f"  {name:<14} {n:>8,} {mb:>11.1f}ms {mg:>10.2f}ms {mult:>8}배")
            pts.append({"limit": n, "bad_ms": mb, "good_ms": mg, "multiplier": mult})
        except Exception as e:
            print(f"  {name:<14} {n:>8,} 실패: {type(e).__name__}: {e}")
    curves[name] = pts
out["curves"] = curves

# ── 3) 선행 와일드카드를 선택도 높은 컬럼으로 다시 ──────────────────────
print()
print("## 3) 선행 와일드카드를 선택도 높은 컬럼으로 다시 짠다")
# 원 케이스의 buyer_name 은 서로 다른 값이 다섯 개뿐이라 선택도가 40% 였다.
# 어떤 인덱스로도 도울 수 없는 조건이라 그 배수는 인덱스 이야기가 아니었다.
cur.execute("SELECT COUNT(DISTINCT buyer_name) FROM orders")
distinct_old = cur.fetchone()[0]
cur.execute("SELECT COUNT(*) FROM orders")
total = cur.fetchone()[0]
print(f"  원 컬럼 buyer_name: 서로 다른 값 {distinct_old}개 / {total:,}행")

cur.execute("SHOW COLUMNS FROM orders LIKE 'buyer_email'")
if not cur.fetchall():
    print("  선택도 높은 컬럼 buyer_email 을 만듭니다(주문번호를 섞어 값마다 다르게).")
    cur.execute("ALTER TABLE orders ADD COLUMN buyer_email VARCHAR(64) "
                "GENERATED ALWAYS AS (CONCAT(MD5(id), '@example.com')) STORED")
    cur.execute("ALTER TABLE orders ADD KEY idx_email (buyer_email)")
    cur.execute("ALTER TABLE orders ADD COLUMN buyer_email_rev VARCHAR(64) "
                "GENERATED ALWAYS AS (REVERSE(CONCAT(MD5(id), '@example.com'))) STORED")
    cur.execute("ALTER TABLE orders ADD KEY idx_email_rev (buyer_email_rev)")
cur.execute("SELECT COUNT(DISTINCT buyer_email) FROM orders")
distinct_new = cur.fetchone()[0]
print(f"  새 컬럼 buyer_email: 서로 다른 값 {distinct_new:,}개 / {total:,}행")

# 같은 질문("특정 문자열로 끝나는")을 두 방식으로 던진다.
SUFFIX = "0@example.com"
bad = f"SELECT COUNT(*) FROM orders WHERE buyer_email LIKE '%{SUFFIX}'"
good = ("SELECT COUNT(*) FROM orders WHERE buyer_email_rev LIKE "
        f"CONCAT(REVERSE('{SUFFIX}'),'%')")
wc = []
for label, sql in (("선행 와일드카드", bad), ("뒤집은 컬럼", good)):
    med, lo, hi = timeit(sql)
    plan = explain_row(sql)[0]
    cur.execute(sql)
    cnt = cur.fetchone()[0]
    print(f"  {label:<16} {med:>9.1f}ms  {plan['type']:<8} "
          f"{plan.get('key') or '인덱스없음':<16} rows {int(plan.get('rows') or 0):>10,}  결과 {cnt:,}건")
    wc.append({"label": label, "sql": sql, "median_ms": med, "type": plan["type"],
               "key": plan.get("key"), "rows": plan.get("rows"), "result_count": cnt})
if len(wc) == 2 and wc[1]["median_ms"]:
    print(f"  배수 {wc[0]['median_ms']/wc[1]['median_ms']:.1f}배  "
          f"(선택도 {100*wc[0]['result_count']/total:.4f}%)")
out["wildcard_redesign"] = {"distinct_old": distinct_old, "distinct_new": distinct_new,
                            "total_rows": total, "cases": wc}

with open(OUT, "w") as f:
    json.dump(out, f, ensure_ascii=False, indent=1)
print(f"\n원문: {OUT}")
print("각 조건 1회 실행이고, 시간은 중앙값 5회(곡선은 3회)입니다.")
