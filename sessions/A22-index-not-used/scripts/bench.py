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

CASES = [
    {
        "key": "implicit-cast",
        "ko": "암묵적 형변환",
        "why": "문자열 컬럼을 숫자와 비교하면 인덱스를 쓸 수 없다. "
               "'1', ' 1', '1a'가 모두 1로 변환되므로 인덱스 순서로 찾아갈 수 없기 때문이다.",
        "bad": "SELECT id, amount FROM orders WHERE order_no = 1500000",
        "good": "SELECT id, amount FROM orders WHERE order_no = 'ORD001500000'",
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
        "bad": "SELECT COUNT(*) FROM orders WHERE DATE(created_at) = '2026-03-15'",
        "good": "SELECT COUNT(*) FROM orders WHERE created_at >= '2026-03-15' "
                "AND created_at < '2026-03-16'",
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
    for _ in range(WARMUP):
        cur.execute(sql)
        cur.fetchall()
    before = handler_reads(cur)
    ts = []
    for _ in range(REPEAT):
        t0 = time.perf_counter()
        cur.execute(sql)
        cur.fetchall()
        ts.append((time.perf_counter() - t0) * 1000)
    after = handler_reads(cur)
    scanned = sum(after[k] - before[k] for k in
                  ("Handler_read_next", "Handler_read_rnd_next")) // REPEAT
    return {
        "med_ms": st.median(ts),
        "p95_ms": st.quantiles(ts, n=20)[18] if len(ts) >= 20 else max(ts),
        "min_ms": min(ts),
        "rows_scanned": scanned,
    }


def main():
    conn = pymysql.connect(host="127.0.0.1", port=13313, user="root",
                           password="lab", database="spoon", autocommit=True)
    cur = conn.cursor()
    out = []
    for case in CASES:
        if case.get("needs_index"):
            try:
                cur.execute(case["needs_index"])
                print(f"  인덱스 생성: {case['key']}")
            except pymysql.Error as e:
                if e.args[0] != 1061:      # 이미 있으면 넘어간다
                    print(f"  인덱스 생성 실패: {e}")
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
        print(f"{case['ko']:<18} {rec['bad']['med_ms']:>9.1f}ms → {rec['good']['med_ms']:>7.2f}ms "
              f"({speedup:>6.0f}배)  스캔 {rec['bad']['rows_scanned']:>10,} → {rec['good']['rows_scanned']:,}")

    path = sys.argv[1] if len(sys.argv) > 1 else "results/bench.json"
    with open(path, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print("저장:", path)
    conn.close()


if __name__ == "__main__":
    main()
