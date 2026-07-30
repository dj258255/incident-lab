#!/usr/bin/env python3
"""파티션 수가 조회에 물리는 비용을 잰다.

README 의 "못 한 것"에 적어 둔 항목이다. 파티션 드롭이 DELETE 보다 싸다는 것은
이 세션이 보였지만, 파티션을 많이 두는 대가는 재지 않았다.

파티션이 많으면 두 자리에서 비용이 생긴다.
  1) 파티션 프루닝이 듣지 않는 질의는 모든 파티션을 열어야 한다
  2) 파티션마다 파일 핸들과 메타데이터가 있어 여는 비용 자체가 붙는다

같은 행 수를 파티션 개수만 바꿔 담고, 프루닝이 되는 질의와 안 되는 질의를 나눠 잰다.
"""
import argparse
import json
import statistics
import time

import pymysql

p = argparse.ArgumentParser()
p.add_argument("--out", required=True)
p.add_argument("--rows", type=int, default=2_000_000)
p.add_argument("--repeat", type=int, default=5)
args = p.parse_args()

c = pymysql.connect(host="127.0.0.1", port=13307, user="root", password="lab",
                    database="lab", autocommit=True)
cur = c.cursor()
out = {"rows": args.rows}
cur.execute("SELECT VERSION()")
out["mysql"] = cur.fetchone()[0]
cur.execute("SELECT @@innodb_open_files, @@open_files_limit, @@table_open_cache")
out["open_files"], out["open_files_limit"], out["table_open_cache"] = cur.fetchone()

BASE = "2026-01-01"


def timed(sql, n=None):
    n = n or args.repeat
    lat = []
    for i in range(n + 1):
        t0 = time.perf_counter()
        cur.execute(sql)
        cur.fetchall()
        if i:
            lat.append((time.perf_counter() - t0) * 1000)
    return round(statistics.median(lat), 2)


def partitions_used(sql):
    cur.execute("EXPLAIN " + sql)
    r = cur.fetchone()
    parts = r[3]           # partitions 컬럼
    return len(parts.split(",")) if parts else 0


DAYS = 365     # 데이터가 걸치는 날짜 폭. 파티션 수와 무관하게 고정한다.


def build(nparts):
    """같은 행 수를 같은 365일에 담되, 그 365일을 nparts 개 파티션으로 묶는다.

    처음에는 날짜 폭을 파티션 수와 같게 두었다. 그러면 파티션이 많을수록 하루치
    행 수가 줄어 "하루 범위" 질의의 결과 집합이 365배 차이 났고, 프루닝의 이득처럼
    보인 286.78ms → 0.87ms 가 사실은 결과 집합이 줄어든 것이었다. 날짜 폭을 고정해야
    프루닝만 바뀐다.
    """
    cur.execute("DROP TABLE IF EXISTS pcount")
    cols = ("id BIGINT NOT NULL AUTO_INCREMENT, live_id INT NOT NULL, "
            "amount INT NOT NULL, memo VARCHAR(40) NOT NULL, created_at DATETIME NOT NULL")
    if nparts <= 1:
        cur.execute(f"CREATE TABLE pcount ({cols}, PRIMARY KEY (id), KEY idx_created (created_at)) ENGINE=InnoDB")
    else:
        # 하루 한 파티션. nparts 일치를 만든다.
        # 365일을 nparts 조각으로 나눈다. 조각마다 담는 날짜 수가 DAYS/nparts 다.
        step = DAYS / nparts
        defs = ",\n".join(
            f"PARTITION p{i:04d} VALUES LESS THAN (TO_DAYS('{BASE}') + {int((i + 1) * step) + 1})"
            for i in range(nparts))
        cur.execute(f"""CREATE TABLE pcount ({cols}, PRIMARY KEY (id, created_at),
                        KEY idx_created (created_at)) ENGINE=InnoDB
                        PARTITION BY RANGE (TO_DAYS(created_at)) ({defs})""")
    # 행을 365일에 고르게 흩는다. 파티션 수와 무관하게 같은 분포다.
    days = DAYS
    cur.execute(f"""
        INSERT INTO pcount (live_id, amount, memo, created_at)
        WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < {args.rows})
        SELECT n % 1000 + 1, 1000, 'x',
               TIMESTAMPADD(SECOND, (n % 86400), TIMESTAMPADD(DAY, n % {days}, '{BASE}'))
          FROM s""")
    cur.execute("ANALYZE TABLE pcount")


cur.execute(f"SET SESSION cte_max_recursion_depth = {args.rows + 10}")
out["cases"] = []
for nparts in (1, 7, 30, 90, 365):
    t0 = time.time()
    build(nparts)
    load_s = round(time.time() - t0, 1)

    # 프루닝이 듣는 질의: 하루 범위. 파티션 하나만 열면 된다.
    pruned = (f"SELECT COUNT(*) FROM pcount WHERE created_at >= '{BASE} 00:00:00' "
              f"AND created_at < '{BASE} 23:59:59'")
    # 프루닝이 안 듣는 질의: 파티션 키가 조건에 없다. 모든 파티션을 열어야 한다.
    scan = "SELECT COUNT(*) FROM pcount WHERE live_id = 7"
    # 프루닝 질의의 결과 집합이 조건마다 같은지 검산한다. 다르면 비교가 성립하지 않는다.
    cur.execute(pruned_check := (f"SELECT COUNT(*) FROM pcount WHERE created_at >= '{BASE} 00:00:00' "
                                 f"AND created_at < '{BASE} 23:59:59'"))
    pruned_rows = cur.fetchone()[0]
    # 단건 조회. PK 에 파티션 키가 섞여 있어 파티션 키 없이 찾으면 전부 뒤진다.
    point = "SELECT amount FROM pcount WHERE id = 1000"

    cur.execute("SELECT ROUND(SUM(DATA_LENGTH+INDEX_LENGTH)/1024/1024) FROM information_schema.TABLES "
                "WHERE TABLE_SCHEMA='lab' AND TABLE_NAME='pcount'")
    mb = cur.fetchone()[0]
    row = {
        "partitions": nparts, "load_s": load_s, "size_mb": int(mb or 0),
        "pruned_ms": timed(pruned), "pruned_parts": partitions_used(pruned),
        "pruned_rows": int(pruned_rows),
        "scan_ms": timed(scan), "scan_parts": partitions_used(scan),
        "point_ms": timed(point), "point_parts": partitions_used(point),
    }
    out["cases"].append(row)
    print(f"  파티션 {nparts:>4}개  적재 {load_s:>6.1f}초  {row['size_mb']:>5}MB  "
          f"프루닝 {row['pruned_ms']:>8.2f}ms({row['pruned_parts']}개, {row['pruned_rows']}행)  "
          f"전체 {row['scan_ms']:>9.2f}ms({row['scan_parts']}개)  "
          f"단건 {row['point_ms']:>7.2f}ms({row['point_parts']}개)", flush=True)

cur.execute("DROP TABLE IF EXISTS pcount")
with open(args.out, "w") as f:
    json.dump(out, f, ensure_ascii=False, indent=1)
print(f"\n원문: {args.out}")
