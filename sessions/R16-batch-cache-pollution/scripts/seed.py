#!/usr/bin/env python3
"""핫 테이블(약 300MB)과 콜드 테이블(약 2GB)을 채운다.

크기 관계가 이 세션의 전제다.
  핫(300MB) < 버퍼 풀(1GB) < 콜드(2GB)
핫 워킹셋은 버퍼 풀에 다 들어가므로 평상시 조회는 메모리에서 끝난다.
콜드 풀 스캔은 버퍼 풀보다 커서 무엇이든 밀어내야만 진행된다.
"""
import os
import random
import time

import pymysql

random.seed(20260728)

HOT_ROWS = 1_500_000        # 행당 약 200바이트 → 데이터+인덱스 약 400MB
COLD_ROWS = 8_000_000       # 행당 약 260바이트 → 약 2.2GB
BATCH = 4000

conn = pymysql.connect(host="127.0.0.1", port=13308, user="root",
                       password="lab", database="spoon", autocommit=False)
cur = conn.cursor()
t0 = time.time()

print("핫 테이블 적재")
for i in range(0, HOT_ROWS, BATCH):
    rows = [(random.randint(1, 300_000), random.randint(0, 4),
             random.randint(1000, 500_000), os.urandom(128)) for _ in range(BATCH)]
    cur.executemany("INSERT INTO orders_hot (user_id, status, amount, pad) VALUES (%s,%s,%s,%s)", rows)
    if (i // BATCH) % 50 == 0:
        conn.commit()
        print(f"  {i:,}/{HOT_ROWS:,} ({time.time()-t0:.0f}초)", flush=True)
conn.commit()

print("콜드 테이블 적재")
for i in range(0, COLD_ROWS, BATCH):
    rows = [(random.randint(1, HOT_ROWS), random.randint(1000, 500_000),
             random.randint(10, 5000), os.urandom(200),
             f"2026-0{random.randint(1,6)}-{random.randint(1,28):02d} 12:00:00") for _ in range(BATCH)]
    cur.executemany(
        "INSERT INTO settlement_history (order_id, amount, fee, pad, created_at) VALUES (%s,%s,%s,%s,%s)", rows)
    if (i // BATCH) % 100 == 0:
        conn.commit()
        print(f"  {i:,}/{COLD_ROWS:,} ({time.time()-t0:.0f}초)", flush=True)
conn.commit()

cur.execute("""SELECT TABLE_NAME, ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024) FROM information_schema.TABLES
               WHERE TABLE_SCHEMA='spoon' ORDER BY TABLE_NAME""")
for name, mb in cur.fetchall():
    print(f"{name}: {mb}MB")
conn.close()
print(f"완료 ({time.time()-t0:.0f}초)")
