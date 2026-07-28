#!/usr/bin/env python3
"""삭제 작업이 도는 동안 실시간 INSERT가 얼마나 느려지는지 잰다.

시청 로그는 삭제 중에도 계속 들어온다. 그 INSERT의 지연이 이 실험의 피해 지표다.
스레드 8개가 한 건씩 INSERT하고, 건마다 (시각, 지연 ms)를 CSV로 남긴다.

  사용법: oltp.py <대상테이블> <지속초> <출력.csv>
"""
import csv
import datetime as dt
import random
import sys
import threading
import time

import pymysql

TABLE = sys.argv[1]
DURATION = int(sys.argv[2])
OUT = sys.argv[3]
THREADS = 8

stop = threading.Event()
rows = []
lock = threading.Lock()


def worker():
    conn = pymysql.connect(host="127.0.0.1", port=13307, user="root",
                           password="lab", database="spoon", autocommit=True)
    cur = conn.cursor()
    local = []
    while not stop.is_set():
        now = dt.datetime.now()
        t0 = time.perf_counter()
        try:
            cur.execute(
                f"INSERT INTO {TABLE} (live_id, user_id, event_type, created_at) "
                "VALUES (%s, %s, %s, %s)",
                (random.randint(1, 1000), random.randint(1, 500_000),
                 random.randint(0, 3), now.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]))
            ms = (time.perf_counter() - t0) * 1000
            local.append((time.time(), f"{ms:.2f}", "ok"))
        except pymysql.Error as e:
            ms = (time.perf_counter() - t0) * 1000
            local.append((time.time(), f"{ms:.2f}", f"err:{e.args[0]}"))
    conn.close()
    with lock:
        rows.extend(local)


threads = [threading.Thread(target=worker) for _ in range(THREADS)]
start = time.time()
for t in threads:
    t.start()
time.sleep(DURATION)
stop.set()
for t in threads:
    t.join()

rows.sort()
with open(OUT, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["ts", "latency_ms", "status"])
    w.writerows(rows)
print(f"INSERT {len(rows):,}건 기록 → {OUT}")
