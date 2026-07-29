#!/usr/bin/env python3
"""orders를 200만 행으로 채운다.

이 세션에서 데이터 크기는 주인공이 아니다. 조회가 버퍼 풀 안에서 끝나야 정지 구간이
메타데이터 락 때문이라고 말할 수 있으므로, 버퍼 풀 1GB에 다 들어가는 크기로 잡았다.
"""
import os
import time

import pymysql

TARGET = 2_000_000
conn = pymysql.connect(host=os.environ.get("MYSQL_HOST", "127.0.0.1"),
                       user="root", password="lab", database="lab", autocommit=False)
cur = conn.cursor()
t0 = time.time()

cur.execute("SELECT COUNT(*) FROM orders")
have = cur.fetchone()[0]
print(f"현재 {have:,}행, 목표 {TARGET:,}행", flush=True)

while have < 200_000:
    n = min(5000, 200_000 - have)
    cur.executemany(
        "INSERT INTO orders (user_id, status, amount, pad) "
        "VALUES (%s,%s,%s,RANDOM_BYTES(100))",
        [(i % 300_000 + 1, i % 5, i % 500_000 + 1000) for i in range(n)])
    conn.commit()
    have += n

while have < TARGET:
    n = min(500_000, have, TARGET - have)
    cur.execute(
        "INSERT INTO orders (user_id, status, amount, pad) "
        "SELECT FLOOR(RAND()*300000)+1, FLOOR(RAND()*5), FLOOR(RAND()*500000)+1000, "
        "RANDOM_BYTES(100) FROM orders LIMIT %s", (n,))
    conn.commit()
    have += n
    print(f"  {have:,}행 ({time.time()-t0:.0f}초)", flush=True)

cur.execute("ANALYZE TABLE orders")
cur.execute("""SELECT ROUND(DATA_LENGTH/1024/1024) FROM information_schema.TABLES
               WHERE TABLE_SCHEMA='lab' AND TABLE_NAME='orders'""")
print(f"테이블 {cur.fetchone()[0]}MB, 총 {time.time()-t0:.0f}초")
conn.close()
