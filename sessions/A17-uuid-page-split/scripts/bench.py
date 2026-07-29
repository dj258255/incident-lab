#!/usr/bin/env python3
"""PK 종류만 바꿔 같은 행을 같은 수만큼 넣고, 적재 속도와 최종 크기를 잰다.

네 조건을 잰다. 페이로드 컬럼은 전부 같고 PK만 다르다.

  seq         BIGINT AUTO_INCREMENT     순차
  uuid7_bin   BINARY(16)  UUIDv7        시간 정렬, 앞 48비트가 밀리초 타임스탬프
  uuid4_bin   BINARY(16)  UUIDv4        완전 랜덤
  uuid4_char  CHAR(36)    UUIDv4 문자열 완전 랜덤 + 길이 낭비

핵심 대조는 uuid7_bin과 uuid4_bin이다. 컬럼 타입과 길이가 같고 값의 정렬성만 다르므로,
둘 사이의 차이는 순전히 "PK가 증가하느냐 흩어지느냐"에서 나온다. seq와 uuid7_bin의 차이는
컬럼이 8바이트냐 16바이트냐에서 나오고, uuid4_char는 거기에 문자열 저장의 대가가 얹힌다.

적재 도중 청크마다 시간을 남긴다. 랜덤 PK의 손해는 총 시간보다 "뒤로 갈수록 느려진다"는
모양에서 잘 보인다. 인덱스가 버퍼 풀을 넘어서는 순간부터 페이지를 디스크에서 읽어 와
고쳐야 하기 때문이다.

  사용법: bench.py --arm uuid4_bin --rows 3000000 --out /results/bench-uuid4_bin.json
"""
import argparse
import json
import os
import random
import time
import uuid

import pymysql

p = argparse.ArgumentParser()
p.add_argument("--arm", required=True,
               choices=["seq", "uuid7_bin", "uuid7_counter", "uuid4_bin", "uuid4_char"])
p.add_argument("--rows", type=int, default=3_000_000)
p.add_argument("--batch", type=int, default=1_000)
p.add_argument("--chunk", type=int, default=100_000)   # 이 단위로 경과 시간을 남긴다
# UUIDv7의 앞 48비트는 밀리초 타임스탬프다. 같은 밀리초 안의 값들은 서로 순서가 없으므로,
# "1밀리초에 몇 행이 들어가느냐"가 정렬성을 좌우한다. 이 값을 실제 적재 속도와 맞춰야 한다.
# 초당 2만 행이면 밀리초당 20행이다. 여기를 크게 잡으면 같은 밀리초를 공유하는 행이 늘어
# 실제보다 훨씬 흩어진 조건을 재게 된다.
p.add_argument("--uuid7-rows-per-ms", type=int, default=20)
p.add_argument("--out", required=True)
args = p.parse_args()

HOST = os.environ.get("MYSQL_HOST", "127.0.0.1")
PAD = 120          # 페이로드를 채우는 바이트 수. 네 조건이 모두 같다.
rnd = random.Random(20260729)

DDL = {
    "seq": """CREATE TABLE t_seq (
                id BIGINT NOT NULL AUTO_INCREMENT,
                user_id INT NOT NULL, amount INT NOT NULL, pad BINARY(120) NOT NULL,
                PRIMARY KEY (id)) ENGINE=InnoDB""",
    "uuid7_bin": """CREATE TABLE t_uuid7_bin (
                id BINARY(16) NOT NULL,
                user_id INT NOT NULL, amount INT NOT NULL, pad BINARY(120) NOT NULL,
                PRIMARY KEY (id)) ENGINE=InnoDB""",
    "uuid7_counter": """CREATE TABLE t_uuid7_counter (
                id BINARY(16) NOT NULL,
                user_id INT NOT NULL, amount INT NOT NULL, pad BINARY(120) NOT NULL,
                PRIMARY KEY (id)) ENGINE=InnoDB""",
    "uuid4_bin": """CREATE TABLE t_uuid4_bin (
                id BINARY(16) NOT NULL,
                user_id INT NOT NULL, amount INT NOT NULL, pad BINARY(120) NOT NULL,
                PRIMARY KEY (id)) ENGINE=InnoDB""",
    "uuid4_char": """CREATE TABLE t_uuid4_char (
                id CHAR(36) NOT NULL,
                user_id INT NOT NULL, amount INT NOT NULL, pad BINARY(120) NOT NULL,
                PRIMARY KEY (id)) ENGINE=InnoDB""",
}
TABLE = {"seq": "t_seq", "uuid7_bin": "t_uuid7_bin", "uuid7_counter": "t_uuid7_counter",
         "uuid4_bin": "t_uuid4_bin", "uuid4_char": "t_uuid4_char"}[args.arm]


def uuid7_bytes(ts_ms, counter=None):
    """RFC 9562 UUIDv7. 앞 48비트가 밀리초 타임스탬프다.

    counter가 None이면 rand_a 12비트와 rand_b 62비트를 전부 난수로 채운다. 타임스탬프가
    같은 값들끼리는 순서가 없다는 뜻이고, 밀리초 안에 여러 행이 들어가면 그만큼 흩어진다.

    counter를 주면 RFC 9562 6.2절의 "Method 1: Fixed Bit-Length Dedicated Counter"가
    된다. rand_a 자리를 밀리초 안에서 증가하는 카운터로 쓰므로 값이 단조 증가한다.
    12비트라 한 밀리초에 4,096개까지 담는다.
    """
    b = bytearray(16)
    b[0:6] = ts_ms.to_bytes(6, "big")
    rand_a = rnd.getrandbits(12) if counter is None else (counter & 0xFFF)
    b[6] = 0x70 | (rand_a >> 8)              # 버전 7
    b[7] = rand_a & 0xFF
    # 카운터 방식이라도 rand_b는 난수다. 같은 밀리초·같은 카운터가 겹치지 않는 한 정렬은
    # 앞 60비트로 이미 결정되므로 뒤쪽 난수는 순서에 영향을 주지 않는다.
    rand_b = rnd.getrandbits(62)
    b[8] = 0x80 | (rand_b >> 56)             # variant 10
    b[9:16] = (rand_b & ((1 << 56) - 1)).to_bytes(7, "big")
    return bytes(b)


def counters(cur):
    cur.execute("""SHOW GLOBAL STATUS WHERE Variable_name IN
                   ('Innodb_buffer_pool_read_requests','Innodb_buffer_pool_reads',
                    'Innodb_pages_written','Innodb_data_written','Innodb_data_read',
                    'Innodb_buffer_pool_wait_free','Innodb_log_writes')""")
    return {k: int(v) for k, v in cur.fetchall()}


conn = pymysql.connect(host=HOST, user="root", password="lab", database="lab",
                       autocommit=False)
cur = conn.cursor()
cur.execute(f"DROP TABLE IF EXISTS {TABLE}")
cur.execute(DDL[args.arm])
conn.commit()

cur.execute("SELECT @@innodb_buffer_pool_size, @@version")
bp, version = cur.fetchone()
print(f"[{args.arm}] 버퍼 풀 {bp/1024/1024:.0f}MB, MySQL {version}, "
      f"목표 {args.rows:,}행", flush=True)

if args.arm == "seq":
    cols, ph = "(user_id, amount, pad)", "(%s,%s,%s)"
else:
    cols, ph = "(id, user_id, amount, pad)", "(%s,%s,%s,%s)"
sql = f"INSERT INTO {TABLE} {cols} VALUES {ph}"

before = counters(cur)
t0 = time.perf_counter()
chunks = []          # (누적행수, 누적초, 이 청크의 초당 삽입)
last_mark, last_t = 0, t0
ts_ms = 1_767_000_000_000    # UUIDv7 타임스탬프 시작점. 고정해 두어야 재실행이 같아진다.
ms_counter = 0               # 같은 밀리초 안에서 증가하는 카운터 (uuid7_counter 전용)
pad = os.urandom(PAD)

for done in range(0, args.rows, args.batch):
    n = min(args.batch, args.rows - done)
    rows = []
    for i in range(n):
        uid, amt = rnd.randint(1, 300_000), rnd.randint(1000, 500_000)
        if args.arm == "seq":
            rows.append((uid, amt, pad))
        elif args.arm in ("uuid7_bin", "uuid7_counter"):
            if (done + i) % args.uuid7_rows_per_ms == 0:
                ts_ms += 1
                ms_counter = 0
            else:
                ms_counter += 1
            rows.append((uuid7_bytes(ts_ms, ms_counter if args.arm == "uuid7_counter" else None),
                         uid, amt, pad))
        elif args.arm == "uuid4_bin":
            rows.append((uuid.UUID(int=rnd.getrandbits(128), version=4).bytes, uid, amt, pad))
        else:
            rows.append((str(uuid.UUID(int=rnd.getrandbits(128), version=4)), uid, amt, pad))
    cur.executemany(sql, rows)
    conn.commit()

    if done + n - last_mark >= args.chunk:
        now = time.perf_counter()
        rate = (done + n - last_mark) / (now - last_t)
        chunks.append({"rows": done + n, "elapsed_s": round(now - t0, 2),
                       "rate_per_s": round(rate, 1)})
        print(f"  {done+n:,}행  누적 {now-t0:6.1f}초  이 구간 {rate:,.0f}행/초", flush=True)
        last_mark, last_t = done + n, now

total_s = time.perf_counter() - t0
after = counters(cur)

cur.execute("ANALYZE TABLE " + TABLE)
cur.execute("""SELECT DATA_LENGTH, TABLE_ROWS FROM information_schema.TABLES
               WHERE TABLE_SCHEMA='lab' AND TABLE_NAME=%s""", (TABLE,))
data_len, approx_rows = cur.fetchone()
cur.execute(f"SELECT COUNT(*) FROM {TABLE}")
exact_rows = cur.fetchone()[0]

out = {
    "arm": args.arm,
    "table": TABLE,
    "mysql_version": version,
    "buffer_pool_mb": bp // 1024 // 1024,
    "rows": exact_rows,
    "pad_bytes": PAD,
    "total_s": round(total_s, 2),
    "rows_per_s": round(exact_rows / total_s, 1),
    "data_length_bytes": data_len,
    "data_length_mb": round(data_len / 1024 / 1024, 1),
    "bytes_per_row": round(data_len / exact_rows, 1),
    "disk_reads": after["Innodb_buffer_pool_reads"] - before["Innodb_buffer_pool_reads"],
    "read_requests": after["Innodb_buffer_pool_read_requests"] - before["Innodb_buffer_pool_read_requests"],
    "pages_written": after["Innodb_pages_written"] - before["Innodb_pages_written"],
    "data_written_mb": round((after["Innodb_data_written"] - before["Innodb_data_written"]) / 1024 / 1024, 1),
    "data_read_mb": round((after["Innodb_data_read"] - before["Innodb_data_read"]) / 1024 / 1024, 1),
    "chunks": chunks,
}
with open(args.out, "w") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)

print(f"  총 {total_s:.1f}초, {out['rows_per_s']:,.0f}행/초, "
      f"테이블 {out['data_length_mb']}MB, 행당 {out['bytes_per_row']}바이트, "
      f"적재 중 디스크 읽기 {out['disk_reads']:,}페이지", flush=True)
conn.close()
