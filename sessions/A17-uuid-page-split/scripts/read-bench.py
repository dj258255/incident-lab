#!/usr/bin/env python3
"""적재가 끝난 테이블에서 조회 비용과 리프 페이지 충전율을 잰다.

README 의 "못 한 것" 두 항목을 처리한다.
  - 적재만 쟀고 조회는 재지 않았습니다
  - 페이지 충전율을 직접 재지 않았습니다

bench.py 가 그 조건의 테이블을 만들어 둔 직후에 같은 컨테이너에서 돌려야 한다.
run-read.sh 가 그 순서를 지킨다.

충전율은 information_schema.INNODB_BUFFER_PAGE 로 잰다. 이 뷰는 버퍼 풀에 지금
올라와 있는 페이지의 DATA_SIZE(그 페이지에 실린 레코드 바이트 합)를 준다. 페이지
크기 16384 로 나누면 실제 채움 비율이다.

**중요한 한계**: 버퍼 풀(256MB)이 테이블보다 작으므로 전수가 아니라 표본이다.
그래서 표본 페이지 수와 전체 리프 페이지 수를 함께 적어 어느 정도를 봤는지 밝힌다.
README 가 지금까지 쓰던 DATA_LENGTH 역산값과 이 표본값은 축이 다르므로 나란히
놓지 않는다.
"""
import argparse
import json
import random
import statistics
import time

import pymysql

p = argparse.ArgumentParser()
p.add_argument("--arm", required=True)
p.add_argument("--rows", type=int, default=1_200_000)
p.add_argument("--out", required=True)
args = p.parse_args()

TABLE = {"seq": "t_seq", "uuid7_bin": "t_uuid7_bin", "uuid7_counter": "t_uuid7_counter",
         "uuid4_bin": "t_uuid4_bin", "uuid4_char": "t_uuid4_char"}[args.arm]

c = pymysql.connect(host="mysql", user="root", password="lab", database="lab", autocommit=True)
cur = c.cursor()

out = {"arm": args.arm, "table": TABLE}
cur.execute("SELECT @@innodb_buffer_pool_size DIV 1024 DIV 1024")
out["buffer_pool_mb"] = cur.fetchone()[0]
cur.execute(f"SELECT COUNT(*) FROM {TABLE}")
out["rows"] = cur.fetchone()[0]
cur.execute("""SELECT ROUND(DATA_LENGTH/1024/1024), DATA_LENGTH DIV 16384
               FROM information_schema.TABLES
               WHERE TABLE_SCHEMA='lab' AND TABLE_NAME=%s""", (TABLE,))
mb, pages = cur.fetchone()
out["data_mb"] = mb
out["clustered_pages_total"] = pages


def status(name):
    cur.execute("SHOW GLOBAL STATUS LIKE %s", (name,))
    r = cur.fetchone()
    return int(r[1]) if r else 0


def timed(sql, params=None, fetch=True):
    t0 = time.perf_counter()
    cur.execute(sql, params or ())
    if fetch:
        cur.fetchall()
    return (time.perf_counter() - t0) * 1000


# ── 1) 임의 단건 조회 ────────────────────────────────────────────────────
# 적재 순서와 무관하게 흩어진 키를 고른다. 버퍼 풀이 테이블보다 작으므로
# 랜덤 PK 쪽은 미스가 잦아야 한다. 그것이 이 세션이 주장한 메커니즘이다.
cur.execute(f"SELECT id FROM {TABLE} ORDER BY RAND() LIMIT 300")
keys = [r[0] for r in cur.fetchall()]

# 버퍼 풀을 비운다. 재시작 없이 비울 방법이 없으므로 다른 테이블을 훑는 대신
# 측정 전 상태를 그대로 적고, 읽기 카운터의 차분으로 판정한다.
r0, l0 = status("Innodb_buffer_pool_reads"), status("Innodb_buffer_pool_read_requests")
lat = [timed(f"SELECT user_id FROM {TABLE} WHERE id = %s", (k,)) for k in keys]
r1, l1 = status("Innodb_buffer_pool_reads"), status("Innodb_buffer_pool_read_requests")
lat.sort()
out["point"] = {
    "n": len(lat),
    "p50_ms": round(statistics.median(lat), 3),
    "p95_ms": round(lat[int(len(lat) * 0.95)], 3),
    "max_ms": round(lat[-1], 3),
    "disk_reads": r1 - r0,          # 버퍼 풀 미스로 디스크를 때린 횟수
    "read_requests": l1 - l0,
}

# ── 2) 범위 스캔 ────────────────────────────────────────────────────────
# PK 순서로 이어 읽는다. 순차 PK 는 물리적으로도 이어져 있고 랜덤 PK 는 흩어져 있다.
r0 = status("Innodb_buffer_pool_reads")
t = timed(f"SELECT SQL_NO_CACHE user_id FROM {TABLE} ORDER BY id LIMIT 100000")
r1 = status("Innodb_buffer_pool_reads")
out["range_scan"] = {"ms": round(t, 1), "disk_reads": r1 - r0, "limit": 100000}

# ── 3) 전체 스캔 ────────────────────────────────────────────────────────
r0 = status("Innodb_buffer_pool_reads")
t = timed(f"SELECT SQL_NO_CACHE COUNT(*) FROM {TABLE} WHERE user_id >= 0")
r1 = status("Innodb_buffer_pool_reads")
out["full_scan"] = {"ms": round(t, 1), "disk_reads": r1 - r0}

# ── 4) 리프 페이지 충전율 (표본) ────────────────────────────────────────
# 방금 전체 스캔을 했으므로 버퍼 풀에는 이 테이블의 페이지가 최대한 올라와 있다.
cur.execute("""
    SELECT COUNT(*), AVG(DATA_SIZE), MIN(DATA_SIZE), MAX(DATA_SIZE), AVG(NUMBER_RECORDS)
      FROM information_schema.INNODB_BUFFER_PAGE
     WHERE PAGE_TYPE = 'INDEX' AND INDEX_NAME = 'PRIMARY'
       AND TABLE_NAME IN (%s, %s)
""", (f"`lab`.`{TABLE}`", f"lab/{TABLE}"))
n, avg_data, min_data, max_data, avg_recs = cur.fetchone()
out["page_fill_sample"] = {
    "sampled_pages": int(n or 0),
    "of_total_pages": int(pages) if pages is not None else None,
    "coverage_pct": round(100.0 * (n or 0) / pages, 1) if pages else None,
    "avg_data_bytes": round(float(avg_data), 1) if avg_data else None,
    "min_data_bytes": int(min_data) if min_data is not None else None,
    "max_data_bytes": int(max_data) if max_data is not None else None,
    "avg_records_per_page": round(float(avg_recs), 1) if avg_recs else None,
    # 16384 로 나눈 실제 채움 비율. DATA_LENGTH 역산값과 축이 다르다.
    "avg_fill_pct": round(100.0 * float(avg_data) / 16384, 1) if avg_data else None,
}

# 페이지별 분포도 남긴다. 랜덤 PK 는 반쯤 찬 페이지가 많아야 한다.
cur.execute("""
    SELECT FLOOR(DATA_SIZE / 1638) AS decile, COUNT(*)
      FROM information_schema.INNODB_BUFFER_PAGE
     WHERE PAGE_TYPE = 'INDEX' AND INDEX_NAME = 'PRIMARY'
       AND TABLE_NAME IN (%s, %s)
     GROUP BY decile ORDER BY decile
""", (f"`lab`.`{TABLE}`", f"lab/{TABLE}"))
out["page_fill_histogram"] = {f"{int(d)*10}~{int(d)*10+10}%": int(k) for d, k in cur.fetchall()}

# pymysql 은 AVG()/SUM() 을 Decimal 로 돌려준다. json 이 못 다루므로 float 로 낮춘다.
from decimal import Decimal


def plain(o):
    if isinstance(o, Decimal):
        return float(o)
    if isinstance(o, dict):
        return {k: plain(v) for k, v in o.items()}
    if isinstance(o, list):
        return [plain(v) for v in o]
    return o


out = plain(out)
with open(args.out, "w") as f:
    json.dump(out, f, ensure_ascii=False, indent=1)
print(json.dumps(out, ensure_ascii=False, indent=1))
