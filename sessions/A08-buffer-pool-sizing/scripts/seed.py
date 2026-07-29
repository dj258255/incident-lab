#!/usr/bin/env python3
"""orders 테이블을 약 1.4GB로 채운다.

버퍼 풀을 128M에서 2G까지 스윕할 때 데이터가 그 구간 한가운데 놓여야 한다.
데이터가 128M보다 작으면 제일 작은 풀에서도 전부 캐시되고, 2G보다 크면 제일 큰 풀에서도
전부 캐시되지 않는다. 어느 쪽이든 곡선이 평평해져서 볼 것이 없어진다.

적재는 파이썬에서 20만 행을 넣은 뒤 INSERT ... SELECT로 불려 나가는 방식이다.
700만 행을 전부 파이썬에서 왕복시키면 이 2코어 서버에서 한참 걸린다. pad는 RANDOM_BYTES()로
행마다 새로 만들어 복제본이 서로 같은 내용이 되지 않게 했다.

  사용법: seed.py [목표행수]
"""
import os
import sys
import time

import pymysql

TARGET = int(sys.argv[1]) if len(sys.argv) > 1 else 7_000_000
BOOTSTRAP = 200_000
CHUNK = 500_000          # INSERT ... SELECT 한 번이 삼키는 최대 행 수
BATCH = 5_000

conn = pymysql.connect(host=os.environ.get("MYSQL_HOST", "127.0.0.1"),
                       port=int(os.environ.get("MYSQL_PORT", 3306)),
                       user="root", password="lab", database="lab", autocommit=False)
cur = conn.cursor()
t0 = time.time()

cur.execute("SELECT COUNT(*) FROM orders")
have = cur.fetchone()[0]
print(f"현재 {have:,}행, 목표 {TARGET:,}행", flush=True)

if have < BOOTSTRAP:
    print("씨앗 행 적재", flush=True)
    while have < BOOTSTRAP:
        n = min(BATCH, BOOTSTRAP - have)
        cur.executemany(
            "INSERT INTO orders (user_id, status, amount, pad) VALUES (%s,%s,%s,RANDOM_BYTES(160))",
            [(i % 300_000 + 1, i % 5, i % 500_000 + 1000) for i in range(n)])
        conn.commit()
        have += n
    print(f"  {have:,}행 ({time.time()-t0:.0f}초)", flush=True)

print("복제로 불리기", flush=True)
while have < TARGET:
    n = min(CHUNK, have, TARGET - have)
    cur.execute(
        "INSERT INTO orders (user_id, status, amount, pad) "
        "SELECT FLOOR(RAND()*300000)+1, FLOOR(RAND()*5), FLOOR(RAND()*500000)+1000, RANDOM_BYTES(160) "
        "FROM orders LIMIT %s", (n,))
    conn.commit()
    have += n
    print(f"  {have:,}행 ({time.time()-t0:.0f}초)", flush=True)

# id가 연속이어야 부하 스크립트가 PK를 균등하게 뽑을 수 있다. 중간이 비면 빈 조회가 섞인다.
cur.execute("SELECT MIN(id), MAX(id), COUNT(*) FROM orders")
lo, hi, cnt = cur.fetchone()
print(f"id 범위 {lo:,}~{hi:,}, 행 수 {cnt:,}, 연속 여부 {'연속' if hi - lo + 1 == cnt else '구멍 있음'}")

cur.execute("ANALYZE TABLE orders")
cur.execute("""SELECT ROUND(DATA_LENGTH/1024/1024) FROM information_schema.TABLES
               WHERE TABLE_SCHEMA='lab' AND TABLE_NAME='orders'""")
print(f"클러스터드 인덱스 크기 {cur.fetchone()[0]}MB")
print(f"총 {time.time()-t0:.0f}초")
conn.close()
