#!/usr/bin/env python3
"""쿼리 쌍(못 타는 것 / 타는 것)을 같은 조건에서 재고 실행계획을 함께 남긴다.

측정 방법
  - 매 쿼리 전 CHECKPOINT 대신 버퍼 풀 예열을 맞춘다. 워밍업 3회 후 본 측정 10회.
  - 시간은 중앙값과 p95를 같이 낸다. 한 번 재고 끝내면 GC나 다른 프로세스에 흔들린다.
  - "실제로 몇 행을 읽었나"는 EXPLAIN의 rows 추정이 아니라 Handler_read_* 세션 상태로 센다.
    추정치는 옵티마이저의 생각이고, 핸들러 카운터는 실제 결과다.
"""
import json
import statistics as st
import sys
import time

import pymysql

REPEAT = 10
WARMUP = 3

# 벤치 전에 한 번 거는 스키마 변경. 선행 와일드카드 해소는 쿼리 재작성만으로 안 되고
# 역순 생성 컬럼과 인덱스가 있어야 한다. 손으로 치던 것을 스크립트에 넣어
# compose up 부터 bench 까지 한 번에 재현되게 한다.
PRE_DDL = [
    "ALTER TABLE orders ADD COLUMN buyer_name_rev VARCHAR(64) "
    "AS (REVERSE(buyer_name)) STORED",
    "ALTER TABLE orders ADD KEY idx_buyer_rev (buyer_name_rev)",
]

# 조회 대상은 반드시 seed.py가 실제로 넣은 값이어야 한다.
#   order_no  = f"ORD{j+1:012d}"  → 150만 번째 주문은 'ORD000001500000' (ORD + 12자리)
#   created_at = 2026-01-01 00:00:00 부터 초당 10건, 300만 행이면 2026-01-04 11:19:59 까지
# 없는 값을 조회하면 양쪽 다 0건이 나와 배수가 무의미해진다. 실제로 한 번 그렇게 냈다.
ORDER_NO = "ORD000001500000"
DAY, NEXT_DAY = "2026-01-02", "2026-01-03"

CASES = [
    {
        "key": "implicit-cast",
        "ko": "암묵적 형변환",
        "why": "문자열 컬럼을 숫자와 비교하면 인덱스를 쓸 수 없다. "
               "'1', ' 1', '1a'가 모두 1로 변환되므로 인덱스 순서로 찾아갈 수 없기 때문이다.",
        # 양쪽 모두 '주문번호 1500000번 한 행'을 찾는 쿼리다. 못 타는 쪽은 300만 행을 훑고도
        # 0건을 돌려준다. 느린 것이 아니라 틀린 답을 주는 것이 이 케이스의 핵심이다.
        "bad": "SELECT id, amount FROM orders WHERE order_no = 1500000",
        "good": f"SELECT id, amount FROM orders WHERE order_no = '{ORDER_NO}'",
        "note": "레거시 주문번호가 VARCHAR인데 애플리케이션이 Long으로 바인딩하면 이 상황이 된다.",
    },
    {
        "key": "collation",
        "ko": "문자셋 불일치 조인",
        "why": "utf8mb4 컬럼과 latin1 컬럼 비교는 인덱스 사용을 배제한다고 공식 문서가 명시한다.",
        "bad": "SELECT COUNT(*) FROM orders o JOIN order_legacy l ON o.order_no = l.order_no "
               "WHERE o.created_at >= '2026-01-02 00:00:00' AND o.created_at < '2026-01-02 00:10:00'",
        "good": "SELECT COUNT(*) FROM orders o JOIN order_legacy_fixed l ON o.order_no = l.order_no "
                "WHERE o.created_at >= '2026-01-02 00:00:00' AND o.created_at < '2026-01-02 00:10:00'",
        "note": "테이블을 물려받거나 마이그레이션이 절반만 끝나면 생긴다.",
    },
    {
        "key": "function-wrap",
        "ko": "인덱스 컬럼에 함수 적용",
        "why": "컬럼을 함수로 감싸면 인덱스에 저장된 값과 비교 대상이 달라진다.",
        # 적재 구간(2026-01-01 ~ 01-04) 안에 온전히 들어가는 하루를 고른다.
        # 양쪽이 같은 결과 집합을 돌려줘야 배수가 의미를 가진다.
        "bad": f"SELECT COUNT(*) FROM orders WHERE DATE(created_at) = '{DAY}'",
        "good": f"SELECT COUNT(*) FROM orders WHERE created_at >= '{DAY}' "
                f"AND created_at < '{NEXT_DAY}'",
        "note": "날짜 비교에서 가장 흔하다. 범위 조건으로 펴면 같은 의미로 인덱스를 탄다.",
    },
    {
        "key": "leading-wildcard",
        "ko": "선행 와일드카드 LIKE",
        "why": "인덱스는 앞에서부터 정렬돼 있어, 앞이 열려 있으면 시작점을 못 찾는다. "
               "공식 문서도 와일드카드로 시작하지 않는 상수일 때만 인덱스를 쓴다고 적는다.",
        "bad": "SELECT COUNT(*) FROM orders WHERE buyer_name LIKE '%민준'",
        # 같은 질문("이름이 민준으로 끝나는")을 인덱스로 답하려면 뒤집어 저장해야 한다.
        # LIKE '김%'로 바꾸는 건 다른 질문이라 비교가 성립하지 않는다.
        "good": "SELECT COUNT(*) FROM orders WHERE buyer_name_rev LIKE CONCAT(REVERSE('민준'),'%')",
        "note": "생성 컬럼 buyer_name_rev(REVERSE(buyer_name))에 인덱스를 걸어 앞이 고정되게 만든다.",
    },
    {
        "key": "bit-op",
        "ko": "비트 연산 조건",
        "why": "계산 결과를 조건에 쓰면 일반 인덱스로는 찾아갈 수 없다. "
               "MySQL 8.0.13의 함수형 인덱스가 해법인데, 표현식이 정의와 정확히 일치해야 한다.",
        "bad": "SELECT COUNT(*) FROM orders WHERE user_id = 1 AND (status_flag & 0x0100)",
        "good": "SELECT COUNT(*) FROM orders WHERE user_id = 1 AND (status_flag & 0x0100) = 256",
        "note": "함수형 인덱스를 만든 뒤 측정한다. 등가 비교로 바꿔야 타는 것이 핵심이다.",
        "needs_index": "ALTER TABLE orders ADD KEY idx_gift (user_id, ((status_flag & 0x0100)))",
    },
]


def explain(cur, sql):
    cur.execute("EXPLAIN FORMAT=JSON " + sql)
    plan = json.loads(cur.fetchone()[0])
    cur.execute("EXPLAIN " + sql)
    cols = [d[0] for d in cur.description]
    row = dict(zip(cols, cur.fetchone()))
    return row, plan


def handler_reads(cur):
    cur.execute("SHOW SESSION STATUS WHERE Variable_name IN "
                "('Handler_read_next','Handler_read_rnd_next','Handler_read_key','Handler_read_first')")
    return {k: int(v) for k, v in cur.fetchall()}


def timeit(cur, sql):
    rows = ()
    for _ in range(WARMUP):
        cur.execute(sql)
        rows = cur.fetchall()
    before = handler_reads(cur)
    ts = []
    for _ in range(REPEAT):
        t0 = time.perf_counter()
        cur.execute(sql)
        rows = cur.fetchall()
        ts.append((time.perf_counter() - t0) * 1000)
    after = handler_reads(cur)
    scanned = sum(after[k] - before[k] for k in
                  ("Handler_read_next", "Handler_read_rnd_next")) // REPEAT
    # 몇 건이 나왔는지도 같이 남긴다. 이게 없으면 "빈 결과끼리 비교한 배수"를 못 알아본다.
    # COUNT(*) 쿼리는 반환 행이 1건이므로 그 값 자체를 따로 적는다.
    count = rows[0][0] if len(rows) == 1 and len(rows[0]) == 1 else None
    return {
        "med_ms": st.median(ts),
        "p95_ms": st.quantiles(ts, n=20)[18] if len(ts) >= 20 else max(ts),
        "min_ms": min(ts),
        "rows_scanned": scanned,
        "rows_returned": len(rows),
        "count": count,
    }


def ddl(cur, sql, label):
    try:
        cur.execute(sql)
        print(f"  {label}: {sql[:70]}")
    except pymysql.Error as e:
        if e.args[0] not in (1060, 1061):   # 컬럼/인덱스가 이미 있으면 넘어간다
            print(f"  {label} 실패: {e}")


def main():
    conn = pymysql.connect(host="127.0.0.1", port=13313, user="root",
                           password="lab", database="spoon", autocommit=True)
    cur = conn.cursor()
    for sql in PRE_DDL:
        ddl(cur, sql, "사전 DDL")
    out = []
    for case in CASES:
        if case.get("needs_index"):
            ddl(cur, case["needs_index"], f"인덱스 생성({case['key']})")
        rec = {"key": case["key"], "ko": case["ko"], "why": case["why"], "note": case["note"]}
        for side in ("bad", "good"):
            sql = case[side]
            row, plan = explain(cur, sql)
            perf = timeit(cur, sql)
            rec[side] = {
                "sql": sql,
                "type": row.get("type"), "key": row.get("key"),
                "est_rows": row.get("rows"), "filtered": row.get("filtered"),
                "extra": row.get("Extra"),
                **perf,
            }
        speedup = rec["bad"]["med_ms"] / rec["good"]["med_ms"] if rec["good"]["med_ms"] else 0
        rec["speedup"] = speedup
        out.append(rec)
        # 결과 건수가 양쪽 같은지 바로 보이게 찍는다. 다르면 배수를 읽기 전에 쿼리를 의심해야 한다.
        ans = (f"{rec['bad']['count']:,} / {rec['good']['count']:,}"
               if rec["bad"]["count"] is not None
               else f"{rec['bad']['rows_returned']}행 / {rec['good']['rows_returned']}행")
        print(f"{case['ko']:<18} {rec['bad']['med_ms']:>9.1f}ms → {rec['good']['med_ms']:>7.2f}ms "
              f"({speedup:>6.1f}배)  스캔 {rec['bad']['rows_scanned']:>10,} → "
              f"{rec['good']['rows_scanned']:>9,}  결과 {ans}")

    path = sys.argv[1] if len(sys.argv) > 1 else "results/bench.json"
    with open(path, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print("저장:", path)
    conn.close()


if __name__ == "__main__":
    main()
