#!/usr/bin/env python3
"""서로 다른 병목 3구간을 순서대로 만든다. 샘플러가 이걸 맞히는지가 검증이다.

  1구간 (0~60초)   CPU: 버퍼 풀에 다 들어가는 작은 테이블 PK 점조회
  2구간 (60~120초) 락: 스레드 8개가 같은 행 하나를 UPDATE (R13의 핫 로우 그 자체)
  3구간 (120~180초) IO: 버퍼 풀(256MB)보다 큰 테이블을 무작위 점조회

실행 결과로 확인된 두 가지를 여기 적어 둔다. 이 파일의 원래 주석이 둘 다 틀렸었다.

1) "cpu → lock → io로 바뀌면 정확한 것"이 아니다.
   2구간의 행 락 대기는 lock이 아니라 io_table(wait/io/table/sql/handler)로 나온다.
   lock 열은 60초 내내 0이다. performance_schema의 wait/lock/%는 서버 계층의
   테이블 락·메타데이터 락 자리이고, InnoDB 행 락 대기는 핸들러 호출 안에서 일어나기
   때문이다. 이건 버그가 아니라 실제 PI 화면에서도 같은 관측 결과다.
   락인지 진짜 IO인지는 lock-probe.py처럼 data_lock_waits를 함께 세야 갈린다.

2) 1구간은 CPU 병목을 만들지 못했다.
   THREADS=8이 60초 내내 PK 점조회를 도는데 관측된 평균 활성 세션이 0.55다.
   스레드 하나가 쿼리 안에 있던 시간 비율이 약 7%라 DB가 사실상 논 상태였다.
   CPython의 GIL과 PyMySQL 동기 드라이버 때문에 부하 생성기가 DB를 못 채운 것으로
   보이지만 클라이언트를 프로파일링하지 않아 확정하지 못했다.
   같은 8스레드가 2구간에서 7.52를 만든 것은 락이 세션을 DB 안에 붙잡아 두기 때문이다.
   1구간의 검증을 제대로 하려면 부하 생성기를 sysbench나 k6로 바꾸거나
   쿼리를 무겁게 만들어 세션이 DB 안에 머물게 해야 한다.
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
