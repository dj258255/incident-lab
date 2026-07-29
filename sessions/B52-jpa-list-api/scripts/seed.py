#!/usr/bin/env python3
"""방송 20만 건과 후원 200만 건을 적재한다.

목록 API가 상대할 만한 규모로 잡았다. 방송당 후원 수를 균등하게 두면
N+1의 비용이 방송 수에만 비례하는데, 실제로는 인기 방송에 후원이 몰린다.
Zipf 쏠림을 넣어 "첫 페이지에 인기 방송이 오는" 상황도 만든다.
"""
import random
import time

import pymysql

random.seed(20260729)
LIVES = 200_000
SPONSORS = 2_000_000
BATCH = 5000

conn = pymysql.connect(host="127.0.0.1", port=13314, user="root",
                       password="lab", database="spoon", autocommit=False)
cur = conn.cursor()
t0 = time.time()

base = int(time.mktime((2026, 1, 1, 0, 0, 0, 0, 0, 0)))
print("방송 적재")
for i in range(0, LIVES, BATCH):
    rows = [(f"라이브 방송 {j + 1}", random.randint(1, 20_000),
             time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(base + j * 3)))
            for j in range(i, min(i + BATCH, LIVES))]
    cur.executemany("INSERT INTO live (title, streamer_id, created_at) VALUES (%s,%s,%s)", rows)
conn.commit()
print(f"  {LIVES:,}건 ({time.time() - t0:.0f}초)")

# 후원 쏠림. 상위 방송에 몰리게 하되, 목록 첫 페이지(id 1~20)에도 충분히 붙게 한다.
print("후원 적재")
w = [1 / (i + 1) ** 0.8 for i in range(LIVES)]
tot = sum(w)
cdf = []
acc = 0.0
for x in w:
    acc += x / tot
    cdf.append(acc)


def pick_live():
    r = random.random()
    lo, hi = 0, LIVES - 1
    while lo < hi:
        mid = (lo + hi) // 2
        if cdf[mid] < r:
            lo = mid + 1
        else:
            hi = mid
    return lo + 1


for i in range(0, SPONSORS, BATCH):
    rows = [(pick_live(), random.randint(1, 500_000),
             random.choice([1000, 3000, 5000, 10000, 30000]),
             time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(base + j)))
            for j in range(i, min(i + BATCH, SPONSORS))]
    cur.executemany(
        "INSERT INTO sponsor (live_id, user_id, amount, created_at) VALUES (%s,%s,%s,%s)", rows)
    if (i // BATCH) % 80 == 0:
        conn.commit()
        print(f"  {i:,}/{SPONSORS:,} ({time.time() - t0:.0f}초)", flush=True)
conn.commit()

cur.execute("ANALYZE TABLE live, sponsor")
cur.execute("SELECT COUNT(*) FROM live")
lives = cur.fetchone()[0]
cur.execute("SELECT COUNT(*) FROM sponsor")
sponsors = cur.fetchone()[0]
cur.execute("SELECT COUNT(*) FROM sponsor WHERE live_id BETWEEN 1 AND 20")
first_page = cur.fetchone()[0]
cur.execute("SELECT AVG(c) FROM (SELECT COUNT(*) c FROM sponsor GROUP BY live_id) t")
avg = cur.fetchone()[0]
print(f"\n방송 {lives:,} / 후원 {sponsors:,}")
print(f"목록 첫 페이지(방송 1~20)의 후원 {first_page:,}건, 방송당 평균 {float(avg):.1f}건")
conn.close()
print(f"완료 ({time.time() - t0:.0f}초)")
