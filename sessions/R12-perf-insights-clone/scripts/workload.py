#!/usr/bin/env python3
"""서로 다른 병목 3구간을 순서대로 만든다. 샘플러가 이걸 맞히는지가 검증이다.

  1구간 (0~60초)   CPU: 버퍼 풀에 다 들어가는 작은 테이블 PK 점조회
  2구간 (60~120초) 락: 스레드 8개가 같은 행 하나를 UPDATE (R13의 핫 로우 그 자체)
  3구간 (120~180초) IO: 버퍼 풀(256MB)보다 큰 테이블을 무작위 점조회

각 구간의 실제 병목을 우리가 알고 만들었으므로,
샘플러의 분해 결과가 구간마다 cpu → lock → io로 바뀌면 정확한 것이다.
"""
import random
import threading
import time

import pymysql

THREADS = 8
PHASE = 60


def conn():
    return pymysql.connect(host="127.0.0.1", port=13312, user="root",
                           password="lab", database="spoon", autocommit=True)


stop = threading.Event()
phase = {"n": 0}


def worker():
    c = conn()
    cur = c.cursor()
    while not stop.is_set():
        p = phase["n"]
        try:
            if p == 0:
                cur.execute("SELECT val FROM small WHERE id = %s", (random.randint(1, 100_000),))
                cur.fetchall()
            elif p == 1:
                cur.execute("UPDATE hotrow SET val = val + 1 WHERE id = 1")
            else:
                cur.execute("SELECT pad FROM big WHERE id = %s", (random.randint(1, 4_000_000),))
                cur.fetchall()
        except pymysql.Error:
            time.sleep(0.5)
    c.close()


threads = [threading.Thread(target=worker) for _ in range(THREADS)]
for t in threads:
    t.start()
for p, name in ((0, "CPU (점조회, 전부 캐시)"), (1, "락 (핫 로우 UPDATE)"), (2, "IO (버퍼 풀보다 큰 테이블)")):
    phase["n"] = p
    print(f"[{time.strftime('%H:%M:%S')}] 구간 {p + 1}: {name}", flush=True)
    time.sleep(PHASE)
stop.set()
for t in threads:
    t.join()
print("워크로드 종료")
