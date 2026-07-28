#!/usr/bin/env python3
"""OLTP 조회 부하와 버퍼 풀 지표를 함께 기록한다.

스레드 8개가 핫 테이블을 PK로 점조회하고 건별 지연을 남긴다.
동시에 1초마다 INNODB_BUFFER_POOL_STATS에서 히트율과 young/old 지표를 뽑는다.
배치 스캔이 캐시를 밀어내면 히트율이 떨어지고 조회가 디스크로 간다.

  사용법: workload.py <지속초> <지연출력.csv> <버퍼풀출력.csv>
"""
import csv
import random
import sys
import threading
import time

import pymysql

DURATION = int(sys.argv[1])
OUT_LAT = sys.argv[2]
OUT_BP = sys.argv[3]
THREADS = 8
HOT_ROWS = 1_500_000

stop = threading.Event()
rows = []
lock = threading.Lock()


def worker():
    conn = pymysql.connect(host="127.0.0.1", port=13308, user="root",
                           password="lab", database="spoon", autocommit=True)
    cur = conn.cursor()
    local = []
    while not stop.is_set():
        pk = random.randint(1, HOT_ROWS)
        t0 = time.perf_counter()
        cur.execute("SELECT id, user_id, status, amount FROM orders_hot WHERE id = %s", (pk,))
        cur.fetchall()
        local.append((time.time(), f"{(time.perf_counter() - t0) * 1000:.3f}"))
    conn.close()
    with lock:
        rows.extend(local)


def bp_poller():
    conn = pymysql.connect(host="127.0.0.1", port=13308, user="root",
                           password="lab", database="spoon", autocommit=True)
    cur = conn.cursor()
    with open(OUT_BP, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["ts", "hit_rate", "young_per_1k", "not_young_per_1k",
                    "pages_made_young_rate", "old_pages", "total_pages", "reads_from_disk_rate"])
        while not stop.is_set():
            cur.execute("""SELECT HIT_RATE, YOUNG_MAKE_PER_THOUSAND_GETS, NOT_YOUNG_MAKE_PER_THOUSAND_GETS,
                                  PAGES_MADE_YOUNG_RATE, OLD_DATABASE_PAGES, DATABASE_PAGES, PAGES_READ_RATE
                           FROM information_schema.INNODB_BUFFER_POOL_STATS""")
            r = cur.fetchone()
            w.writerow([f"{time.time():.1f}"] + [str(x) for x in r])
            f.flush()
            time.sleep(1)
    conn.close()


threads = [threading.Thread(target=worker) for _ in range(THREADS)]
poller = threading.Thread(target=bp_poller)
poller.start()
for t in threads:
    t.start()
time.sleep(DURATION)
stop.set()
for t in threads:
    t.join()
poller.join()

rows.sort()
with open(OUT_LAT, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["ts", "latency_ms"])
    w.writerows(rows)
print(f"조회 {len(rows):,}건 기록")
