#!/usr/bin/env python3
"""보강 실험: wait/io/table/sql/handler가 락인지 진짜 IO인지 구분하는 방법.

행 락 대기는 performance_schema에서 wait/lock이 아니라 wait/io/table/sql/handler로 잡힌다.
같은 이벤트 이름이 콜드 IO 조회에서도 나오므로 이름만으로는 못 가른다.
data_lock_waits(진행 중인 행 락 대기)를 함께 세면 갈라진다는 것을 확인한다.
"""
import csv, random, sys, threading, time
import pymysql

def conn():
    return pymysql.connect(host="127.0.0.1", port=13312, user="root",
                           password="lab", database="spoon", autocommit=True)

stop = threading.Event()
phase = {"n": 0}

def worker():
    c = conn(); cur = c.cursor()
    while not stop.is_set():
        try:
            if phase["n"] == 0:
                cur.execute("UPDATE hotrow SET val = val + 1 WHERE id = 1")
            else:
                cur.execute("SELECT pad FROM big WHERE id = %s", (random.randint(1, 4_000_000),))
                cur.fetchall()
        except pymysql.Error:
            time.sleep(0.5)
    c.close()

mon = conn(); mcur = mon.cursor()
rows = []
threads = [threading.Thread(target=worker) for _ in range(8)]
for t in threads: t.start()
t0 = time.time()
for p, dur in ((0, 30), (1, 30)):
    phase["n"] = p
    end = time.time() + dur
    while time.time() < end:
        mcur.execute("""SELECT
          (SELECT COUNT(*) FROM performance_schema.events_waits_current w
            JOIN performance_schema.threads t ON t.THREAD_ID=w.THREAD_ID
            WHERE w.EVENT_NAME='wait/io/table/sql/handler' AND w.END_EVENT_ID IS NULL
              AND t.PROCESSLIST_ID IS NOT NULL),
          (SELECT COUNT(*) FROM performance_schema.data_lock_waits)""")
        io_table, lock_waits = mcur.fetchone()
        rows.append((f"{time.time()-t0:.1f}", p, io_table, lock_waits))
        time.sleep(1)
stop.set()
for t in threads: t.join()
with open(sys.argv[1], "w", newline="") as f:
    w = csv.writer(f); w.writerow(["t","phase","io_table_sessions","data_lock_waits"]); w.writerows(rows)
import statistics as st
for p, name in ((0,"핫 로우 UPDATE"),(1,"콜드 IO 조회")):
    seg=[r for r in rows if r[1]==p]
    print(f"{name}: io/table 세션 평균 {st.mean(r[2] for r in seg):.1f}, data_lock_waits 평균 {st.mean(r[3] for r in seg):.1f}")
