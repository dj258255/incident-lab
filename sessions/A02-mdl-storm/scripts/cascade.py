#!/usr/bin/env python3
"""MDL 폭풍이 애플리케이션 전체로 번지는 구간을 재현한다.

README 의 "못 한 것" 두 항목을 처리한다.
  - 쓰기 부하를 넣지 않았습니다
  - 커넥션 풀 고갈로 번지는 경로를 재지 않았습니다

두 번째가 이 세션의 진짜 사고 경로다. 원 세션은 부하가 커넥션 2개라 풀이 없었고,
막힌 조회의 지연까지만 쟀다. 실무에서 MDL 폭풍이 사고가 되는 이유는 그 테이블 조회가
느려져서가 아니라 막힌 커넥션이 풀을 다 채워 **그 테이블과 상관없는 API 까지** 커넥션을
못 받고 죽기 때문이다.

그래서 앞에 크기가 정해진 풀을 둔다. HikariCP 기본값과 같은 10 이다.
엔드포인트 둘을 함께 때린다.
  /orders  DDL 대상 테이블을 읽는다   → MDL 큐에 선다
  /other   상관없는 테이블을 읽는다    → MDL 과 무관하다. 그런데도 죽는지 본다

조건
  control      롱 트랜잭션도 DDL 도 없음
  ddl          롱 트랜잭션 + DDL. 읽기 부하
  ddl-write    롱 트랜잭션 + DDL. 쓰기 부하(UPDATE). SHARED_WRITE 도 같은 큐인지 본다
"""
import argparse
import json
import os
import queue
import random
import sys
import threading
import time

import pymysql

HOST = os.environ.get("MYSQL_HOST", "mysql")
DSN = dict(host=HOST, port=3306, user="root", password="lab",
           database="lab", autocommit=True)

POOL_SIZE = 10          # HikariCP 기본값과 같다
ACQUIRE_TIMEOUT = 2.0   # HikariCP connectionTimeout 기본값은 30초. 실험을 짧게 두려고 2초로 둔다
DURATION = 20.0
MAX_INFLIGHT = 600    # 웹 서버의 스레드 상한 역할. 동시 실행 수의 상한이다.
                      # 처음에 누적 스레드 수로 세어 control 에서도 200건이 발사되지
                      # 못했다. 조건 사이 비교가 깨지므로 세마포어로 바꿨다.
RPS_PER_ENDPOINT = 20


class Pool:
    """크기가 정해진 커넥션 풀. 획득에 시간 제한을 둔다.

    HikariCP 가 하는 일의 최소 버전이다. 풀이 비면 connectionTimeout 만큼 기다리고
    그래도 못 받으면 예외를 던진다. 이 예외가 실무에서 보는
    'Connection is not available, request timed out after 30000ms' 다.
    """

    def __init__(self, size):
        self.q = queue.Queue(maxsize=size)
        for _ in range(size):
            self.q.put(pymysql.connect(**DSN))
        self.timeouts = 0
        self.lock = threading.Lock()

    def acquire(self, timeout):
        try:
            return self.q.get(timeout=timeout)
        except queue.Empty:
            with self.lock:
                self.timeouts += 1
            return None

    def release(self, c):
        self.q.put(c)

    def free(self):
        return self.q.qsize()


def admin():
    c = pymysql.connect(**DSN)
    return c, c.cursor()


def one_request(pool, name, table, mode, rows_max, stats):
    """요청 하나. 커넥션을 받아 쿼리를 던지고 돌려준다."""
    s = time.time()
    c = pool.acquire(ACQUIRE_TIMEOUT)
    if c is None:
        # 풀에서 커넥션을 못 받았다. 이 요청은 DB 에 닿지도 못했다.
        # 실무에서 보는 'Connection is not available, request timed out' 이 이 자리다.
        with stats["_lock"]:
            stats[name]["pool_timeout"] += 1
            stats[name]["lat"].append((time.time() - s) * 1000)
        return
    try:
        cur = c.cursor()
        pk = random.randrange(1, rows_max)
        if mode == "write" and table == "orders":
            cur.execute("UPDATE orders SET amount = amount + 1 WHERE id = %s", (pk,))
        else:
            cur.execute(f"SELECT id FROM {table} WHERE id = %s", (pk,))
            cur.fetchall()
        with stats["_lock"]:
            stats[name]["ok"] += 1
    except pymysql.Error as e:
        with stats["_lock"]:
            stats[name]["err"] += 1
            stats[name]["codes"].setdefault(e.args[0], 0)
            stats[name]["codes"][e.args[0]] += 1
        try:
            c.close()
            c = pymysql.connect(**DSN)
        except Exception:
            pass
    finally:
        pool.release(c)
        with stats["_lock"]:
            stats[name]["lat"].append((time.time() - s) * 1000)


def _guarded(sem, *a):
    try:
        one_request(*a)
    finally:
        sem.release()


def endpoint(pool, name, table, mode, t0, t_end, rows_max, stats, threads, sem):
    """도착률을 고정한 열린 모델. 요청마다 스레드를 새로 띄운다.

    처음에는 엔드포인트마다 스레드 하나로 순차 요청을 던졌다. 그러면 /orders 가
    11초 막히는 동안 커넥션을 하나만 쥐어 풀 10개 중 9개가 남고, 재현하려던
    풀 고갈이 일어나지 않는다. 실제 웹 서버는 요청마다 스레드를 배정하므로
    막힌 요청이 쌓이는 만큼 커넥션도 함께 쌓인다. 그 모델로 바꿨다.
    """
    interval = 1.0 / RPS_PER_ENDPOINT
    nxt = time.time()
    while time.time() < t_end:
        nxt += interval
        if sem.acquire(blocking=False):
            th = threading.Thread(target=_guarded,
                                  args=(sem, pool, name, table, mode, rows_max, stats),
                                  daemon=True)
            threads.append(th)
            th.start()
        else:
            # 동시 실행 상한에 걸렸다. 웹 서버가 요청을 받지 못한 것과 같다.
            with stats["_lock"]:
                stats[name]["dropped"] += 1
        slp = nxt - time.time()
        if slp > 0:
            time.sleep(slp)


def long_txn(t0, hold):
    """트랜잭션을 열고 SELECT 한 번. 커밋하지 않는다. 이게 MDL 을 쥔다."""
    c = pymysql.connect(**{**DSN, "autocommit": False})
    cur = c.cursor()
    cur.execute("BEGIN")
    cur.execute("SELECT COUNT(*) FROM orders WHERE id < 100")
    cur.fetchall()
    time.sleep(hold)
    c.rollback()
    c.close()


def ddl(t0, out):
    c, cur = admin()
    cur.execute("SET SESSION lock_wait_timeout = 31536000")
    s = time.time()
    try:
        cur.execute("ALTER TABLE orders ADD COLUMN cascade_probe TINYINT NULL")
        out["ddl"] = f"성공 {(time.time()-s)*1000:.0f}ms"
    except pymysql.Error as e:
        out["ddl"] = f"{e.args[0]} {(time.time()-s)*1000:.0f}ms"
    c.close()


def pool_sampler(pool, t_end, samples):
    while time.time() < t_end:
        samples.append(pool.free())
        time.sleep(0.25)


def run(case):
    c, cur = admin()
    cur.execute("SELECT COUNT(*) FROM orders")
    rows = cur.fetchone()[0]
    cur.execute("DROP TABLE IF EXISTS other")
    cur.execute("CREATE TABLE other (id INT PRIMARY KEY, memo VARCHAR(20)) ENGINE=InnoDB")
    cur.execute("INSERT INTO other SELECT id, 'x' FROM orders LIMIT 100000")
    cur.execute("ALTER TABLE orders DROP COLUMN cascade_probe" if _has_probe(cur) else "SELECT 1")
    c.close()
    if rows < 100000:
        print(f"중단: orders 가 {rows}행입니다. 적재를 먼저 하세요", file=sys.stderr)
        sys.exit(4)

    pool = Pool(POOL_SIZE)
    stats = {n: dict(ok=0, err=0, pool_timeout=0, dropped=0, codes={}, lat=[])
             for n in ("/orders", "/other")}
    stats["_lock"] = threading.Lock()
    threads = []
    sem = threading.BoundedSemaphore(MAX_INFLIGHT)
    out = {"case": case, "rows": rows, "pool_size": POOL_SIZE,
           "acquire_timeout_s": ACQUIRE_TIMEOUT, "rps_per_endpoint": RPS_PER_ENDPOINT}
    samples = []
    t0 = time.time()
    t_end = t0 + DURATION
    mode = "write" if case == "ddl-write" else "read"

    ts = [
        threading.Thread(target=endpoint, args=(pool, "/orders", "orders", mode, t0, t_end, rows, stats, threads, sem)),
        threading.Thread(target=endpoint, args=(pool, "/other", "other", "read", t0, t_end, 100000, stats, threads, sem)),
        threading.Thread(target=pool_sampler, args=(pool, t_end, samples)),
    ]
    if case != "control":
        # 5초 뒤에 롱 트랜잭션이 열리고, 그 1초 뒤에 DDL 이 들어온다.
        ts.append(threading.Thread(target=lambda: (time.sleep(5), long_txn(t0, 12))))
        ts.append(threading.Thread(target=lambda: (time.sleep(6), ddl(t0, out))))
    for t in ts:
        t.start()
    for t in ts:
        t.join(timeout=DURATION + 30)
    for t in threads:
        t.join(timeout=60)

    out["requests_spawned"] = len(threads)
    out["pool_free_min"] = min(samples) if samples else None
    out["pool_free_median"] = sorted(samples)[len(samples)//2] if samples else None
    out["pool_acquire_timeouts_total"] = pool.timeouts
    for n, s in stats.items():
        if n == "_lock":
            continue
        lat = sorted(s["lat"])
        out[n] = dict(ok=s["ok"], err=s["err"], pool_timeout=s["pool_timeout"],
                      dropped=s["dropped"], codes=s["codes"],
                      p50=round(lat[len(lat)//2], 1) if lat else None,
                      p95=round(lat[int(len(lat)*0.95)], 1) if lat else None,
                      max=round(lat[-1], 1) if lat else None,
                      n=len(lat))
    return out


def _has_probe(cur):
    cur.execute("""SELECT COUNT(*) FROM information_schema.COLUMNS
                   WHERE TABLE_SCHEMA='lab' AND TABLE_NAME='orders'
                     AND COLUMN_NAME='cascade_probe'""")
    return cur.fetchone()[0] > 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", required=True, choices=["control", "ddl", "ddl-write"])
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    r = run(a.case)
    with open(a.out, "w") as f:
        json.dump(r, f, ensure_ascii=False, indent=1)
    print(json.dumps(r, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
