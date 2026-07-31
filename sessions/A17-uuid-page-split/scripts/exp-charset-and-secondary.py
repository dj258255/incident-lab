#!/usr/bin/env python3
"""README 의 "못 한 것" 둘을 잰다.

  1) 세컨더리 인덱스가 없습니다
     "InnoDB 의 세컨더리 인덱스는 값으로 PK 를 담으므로 PK 가 넓으면 세컨더리 인덱스도
      같이 커집니다. UUID 의 대가는 실제로는 이 세션이 잰 것보다 큽니다."
     크다고 적어 놓고 얼마나 큰지는 안 쟀다. PK 종류별로 같은 세컨더리 인덱스를
     붙여 INDEX_LENGTH 를 잰다.

  2) CHAR(36) 의 문자셋을 고정해 보지 않았습니다
     "DDL 에 문자셋을 적지 않아 MySQL 8.4 기본값인 utf8mb4 가 걸린 채로 쟀습니다.
      문자열 저장의 대가 중 폭의 몫과 문자셋의 몫을 가르지 못했습니다."
     같은 CHAR(36) 을 ascii 와 utf8mb4 로 각각 만들어 가른다.

UUID 값은 조건마다 같은 시드로 만들어 같은 값을 넣는다. 값이 다르면 페이지 분할이
달라져 비교가 성립하지 않는다.
"""
import argparse
import json
import os
import random
import sys
import time
import uuid

import pymysql

ap = argparse.ArgumentParser()
ap.add_argument("--rows", type=int, default=400_000)
ap.add_argument("--batch", type=int, default=2000)
ap.add_argument("--out", default="results/charset-and-secondary.json")
args = ap.parse_args()

HOST = os.environ.get("MYSQL_HOST", "127.0.0.1")
PORT = int(os.environ.get("MYSQL_PORT", "13310"))
PAD = 120

conn = pymysql.connect(host=HOST, port=PORT, user="root", password="lab",
                       database="lab", autocommit=True)
cur = conn.cursor()

# 조건. (이름, PK 컬럼 DDL, 세컨더리 인덱스 유무, PK 값 만드는 방식)
ARMS = [
    ("seq_noidx",        "id BIGINT NOT NULL AUTO_INCREMENT",         False, "seq"),
    ("seq_idx",          "id BIGINT NOT NULL AUTO_INCREMENT",         True,  "seq"),
    ("uuid4bin_noidx",   "id BINARY(16) NOT NULL",                    False, "uuid4"),
    ("uuid4bin_idx",     "id BINARY(16) NOT NULL",                    True,  "uuid4"),
    ("uuid4char8_noidx", "id CHAR(36) CHARACTER SET utf8mb4 NOT NULL", False, "uuid4s"),
    ("uuid4char8_idx",   "id CHAR(36) CHARACTER SET utf8mb4 NOT NULL", True,  "uuid4s"),
    ("uuid4charA_noidx", "id CHAR(36) CHARACTER SET ascii NOT NULL",   False, "uuid4s"),
    ("uuid4charA_idx",   "id CHAR(36) CHARACTER SET ascii NOT NULL",   True,  "uuid4s"),
]


def make_values(kind, n):
    """조건마다 같은 값을 넣는다. 시드를 고정해 UUID 열을 재현한다."""
    rnd = random.Random(20260731)
    pad = b"\x00" * PAD
    out = []
    for i in range(n):
        u = uuid.UUID(int=rnd.getrandbits(128), version=4)
        user_id = rnd.randrange(1, 100_000)
        if kind == "seq":
            out.append((None, user_id, i % 1000, pad))
        elif kind == "uuid4":
            out.append((u.bytes, user_id, i % 1000, pad))
        else:
            out.append((str(u), user_id, i % 1000, pad))
    return out


def size_of(table):
    cur.execute("ANALYZE TABLE " + table)
    cur.fetchall()
    cur.execute("SELECT DATA_LENGTH, INDEX_LENGTH FROM information_schema.TABLES "
                "WHERE TABLE_SCHEMA='lab' AND TABLE_NAME=%s", (table,))
    r = cur.fetchone()
    return (int(r[0] or 0), int(r[1] or 0))


results = {}
print(f"# 세컨더리 인덱스 비용과 CHAR(36) 문자셋 분리")
cur.execute("SELECT VERSION()")
print(f"# MySQL {cur.fetchone()[0]}, 조건마다 {args.rows:,}행, PAD {PAD}바이트")
print()

for name, pk_ddl, with_idx, kind in ARMS:
    table = "t_cs_" + name
    cur.execute(f"DROP TABLE IF EXISTS {table}")
    idx = ", KEY idx_user (user_id)" if with_idx else ""
    cur.execute(f"CREATE TABLE {table} ({pk_ddl}, user_id INT NOT NULL, "
                f"amount INT NOT NULL, pad BINARY({PAD}) NOT NULL, "
                f"PRIMARY KEY (id){idx}) ENGINE=InnoDB")

    rows = make_values(kind, args.rows)
    cols = "(user_id, amount, pad)" if kind == "seq" else "(id, user_id, amount, pad)"
    ph = "(%s, %s, %s)" if kind == "seq" else "(%s, %s, %s, %s)"
    t0 = time.perf_counter()
    for i in range(0, len(rows), args.batch):
        chunk = rows[i:i + args.batch]
        if kind == "seq":
            chunk = [(r[1], r[2], r[3]) for r in chunk]
        cur.executemany(f"INSERT INTO {table} {cols} VALUES {ph}", chunk)
    elapsed = time.perf_counter() - t0

    cur.execute(f"SELECT COUNT(*) FROM {table}")
    n = cur.fetchone()[0]
    if n < args.rows:
        sys.exit(f"중단: {table} 에 {n}행만 들어갔습니다(기대 {args.rows})")
    data, index = size_of(table)
    results[name] = {"rows": n, "seconds": round(elapsed, 2),
                     "rows_per_s": round(n / elapsed),
                     "data_bytes": data, "index_bytes": index,
                     "with_secondary": with_idx}
    print(f"  {name:<18} {n:>8,}행 {elapsed:>7.1f}초 "
          f"데이터 {data/1048576:>7.1f}MB 인덱스 {index/1048576:>7.1f}MB")

print()
print("==================================================================")
print("## 1) 세컨더리 인덱스 하나가 PK 종류별로 얼마나 커지는가")
print("==================================================================")
print(f"  {'PK':<22} {'인덱스 크기':>12} {'seq 대비':>10} {'데이터 증가':>12}")
base_idx = results["seq_idx"]["index_bytes"]
LBL = {"seq": "BIGINT 8바이트", "uuid4bin": "BINARY(16)",
       "uuid4char8": "CHAR(36) utf8mb4", "uuid4charA": "CHAR(36) ascii"}
for key in ("seq", "uuid4bin", "uuid4char8", "uuid4charA"):
    a, b = results[key + "_noidx"], results[key + "_idx"]
    ratio = b["index_bytes"] / base_idx if base_idx else 0
    print(f"  {LBL[key]:<22} {b['index_bytes']/1048576:>10.1f}MB {ratio:>9.2f}배 "
          f"{(b['data_bytes']-a['data_bytes'])/1048576:>10.1f}MB")
print()
print("  세컨더리 인덱스의 잎에는 인덱스 컬럼과 PK 값이 함께 들어갑니다.")
print("  PK 가 넓으면 인덱스도 그만큼 넓어집니다. 인덱스가 여러 개면 그만큼 곱해집니다.")

print()
print("==================================================================")
print("## 2) CHAR(36) 의 대가 중 폭의 몫과 문자셋의 몫")
print("==================================================================")
b16 = results["uuid4bin_noidx"]["data_bytes"]
c_a = results["uuid4charA_noidx"]["data_bytes"]
c_8 = results["uuid4char8_noidx"]["data_bytes"]
print(f"  BINARY(16)           데이터 {b16/1048576:>7.1f}MB")
print(f"  CHAR(36) ascii       데이터 {c_a/1048576:>7.1f}MB  "
      f"({(c_a-b16)/1048576:+.1f}MB, {c_a/b16:.2f}배)")
print(f"  CHAR(36) utf8mb4     데이터 {c_8/1048576:>7.1f}MB  "
      f"({(c_8-c_a)/1048576:+.1f}MB, ascii 대비 {c_8/c_a:.2f}배)")
print()
print("  BINARY(16) → CHAR(36) ascii 가 폭의 몫이고,")
print("  ascii → utf8mb4 가 문자셋의 몫입니다.")

print()
print(f"  각 조건 1회 실행입니다. 값은 조건마다 같은 시드로 만든 같은 UUID 열입니다.")
os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
with open(args.out, "w") as f:
    json.dump(results, f, ensure_ascii=False, indent=1)
print(f"\n원문: {args.out}")
