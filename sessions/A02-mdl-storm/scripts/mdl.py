#!/usr/bin/env python3
"""롱 트랜잭션과 DDL과 일반 조회를 한 타임라인 위에 올려 놓고 잰다.

시나리오는 하나다. 조회 부하가 흐르는 중에

  t=LONG_AT   세션 L이 트랜잭션을 열고 SELECT 한 번. 메타데이터 락을 쥔 채로 안 닫는다
  t=DDL_AT    세션 D가 ALTER TABLE. L이 락을 놓을 때까지 못 들어간다
  t=LONG_END  세션 L이 커밋. 여기서 풀린다

여기서 볼 것은 D가 기다리는 동안 일반 조회가 어떻게 되느냐다. 매뉴얼은 대기 중인 배타적
메타데이터 락이 뒤따르는 트랜잭션을 막는다고 적어 두었고, 이 스크립트는 그 문장을 초당
처리 건수로 옮긴다.

부하 워커는 프로세스로 띄운다. 스레드로 하면 GIL 대기가 지연에 섞인다(A08에서 확인).

  사용법: mdl.py --case ddl-default --out /results/case-ddl-default.json
"""
import argparse
import json
import multiprocessing as mp
import os
import threading
import time

import pymysql

p = argparse.ArgumentParser()
p.add_argument("--case", required=True,
               choices=["control", "ddl-default", "ddl-timeout", "ddl-alone"])
p.add_argument("--procs", type=int, default=2)
p.add_argument("--duration", type=int, default=60)
p.add_argument("--long-at", type=int, default=15)
p.add_argument("--ddl-at", type=int, default=25)
p.add_argument("--long-end", type=int, default=45)
p.add_argument("--lock-wait-timeout", type=int, default=2)   # ddl-timeout 조건에서만 쓴다
p.add_argument("--out", required=True)
args = p.parse_args()

HOST = os.environ.get("MYSQL_HOST", "127.0.0.1")
events = []          # (경과초, 종류, 내용)
ev_lock = threading.Lock()


def connect():
    return pymysql.connect(host=HOST, user="root", password="lab", database="lab",
                           autocommit=True)


def mark(t0, kind, msg):
    with ev_lock:
        events.append({"at_s": round(time.time() - t0, 2), "kind": kind, "msg": msg})
    print(f"  [{time.time()-t0:5.1f}초] {kind}: {msg}", flush=True)


def worker(t0, t_end, q, rows_max):
    """PK 점조회. 막히면 그 대기가 그대로 지연으로 잡힌다."""
    import random
    rnd = random.Random(7)
    conn = connect()
    cur = conn.cursor()
    local = []
    while time.time() < t_end:
        pk = rnd.randint(1, rows_max)
        s = time.perf_counter()
        try:
            cur.execute("SELECT id, user_id, status, amount FROM orders WHERE id = %s", (pk,))
            cur.fetchall()
            local.append((round(time.time() - t0, 3), round((time.perf_counter() - s) * 1000, 3), 1))
        except Exception:
            local.append((round(time.time() - t0, 3), round((time.perf_counter() - s) * 1000, 3), 0))
            try:
                conn.close()
            except Exception:
                pass
            conn = connect()
            cur = conn.cursor()
    conn.close()
    q.put(local)


def long_txn(t0):
    """트랜잭션을 열고 SELECT 한 번 한 뒤 닫지 않는다. 이게 메타데이터 락을 쥔다."""
    time.sleep(max(0, args.long_at - (time.time() - t0)))
    c = pymysql.connect(host=HOST, user="root", password="lab", database="lab",
                        autocommit=False)
    cur = c.cursor()
    cur.execute("SELECT COUNT(*) FROM orders WHERE id < 100")
    cur.fetchall()
    mark(t0, "롱 트랜잭션", "BEGIN 후 SELECT 실행, 커밋하지 않음")
    time.sleep(max(0, args.long_end - (time.time() - t0)))
    c.commit()
    c.close()
    mark(t0, "롱 트랜잭션", "커밋")


def ddl(t0, result):
    time.sleep(max(0, args.ddl_at - (time.time() - t0)))
    c = connect()
    cur = c.cursor()
    if args.case == "ddl-timeout":
        cur.execute(f"SET SESSION lock_wait_timeout = {args.lock_wait_timeout}")
        mark(t0, "DDL", f"lock_wait_timeout={args.lock_wait_timeout}초로 설정")
    cur.execute("SELECT @@lock_wait_timeout")
    lwt = cur.fetchone()[0]
    stmt = "ALTER TABLE orders ADD COLUMN memo VARCHAR(64) NULL"
    mark(t0, "DDL", f"실행 시작 (lock_wait_timeout={lwt}) {stmt}")
    s = time.perf_counter()
    try:
        cur.execute(stmt)
        el = time.perf_counter() - s
        result.update({"ok": True, "elapsed_s": round(el, 2), "error": None,
                       "lock_wait_timeout": lwt})
        mark(t0, "DDL", f"성공, {el:.2f}초 걸림")
    except Exception as e:
        el = time.perf_counter() - s
        result.update({"ok": False, "elapsed_s": round(el, 2), "error": str(e),
                       "lock_wait_timeout": lwt})
        mark(t0, "DDL", f"실패, {el:.2f}초 뒤 {e}")
    c.close()


def lock_watcher(t0, t_end, snaps):
    """performance_schema.metadata_locks를 1초마다 훑어 누가 쥐고 누가 기다리는지 남긴다."""
    c = connect()
    cur = c.cursor()
    while time.time() < t_end:
        cur.execute("""
            SELECT ml.OBJECT_NAME, ml.LOCK_TYPE, ml.LOCK_STATUS, ml.OWNER_THREAD_ID,
                   COALESCE(t.PROCESSLIST_INFO, '')
            FROM performance_schema.metadata_locks ml
            LEFT JOIN performance_schema.threads t ON t.THREAD_ID = ml.OWNER_THREAD_ID
            WHERE ml.OBJECT_SCHEMA = 'lab' AND ml.OBJECT_NAME = 'orders'
            ORDER BY ml.LOCK_STATUS, ml.LOCK_TYPE""")
        rows = cur.fetchall()
        pending = [r for r in rows if r[2] != "GRANTED"]
        snaps.append({
            "at_s": round(time.time() - t0, 1),
            "granted": len([r for r in rows if r[2] == "GRANTED"]),
            "pending": len(pending),
            "types": sorted({f"{r[1]}:{r[2]}" for r in rows}),
        })
        time.sleep(1)
    c.close()


def main():
    admin = connect()
    acur = admin.cursor()
    acur.execute("SELECT COUNT(*), @@version, @@lock_wait_timeout FROM orders")
    rows_max, version, default_lwt = acur.fetchone()
    # 앞 조건에서 붙인 컬럼이 남아 있으면 ALTER가 중복 오류로 끝난다.
    acur.execute("""SELECT COUNT(*) FROM information_schema.COLUMNS
                    WHERE TABLE_SCHEMA='lab' AND TABLE_NAME='orders' AND COLUMN_NAME='memo'""")
    if acur.fetchone()[0]:
        acur.execute("ALTER TABLE orders DROP COLUMN memo")
    print(f"[{args.case}] MySQL {version}, 행 {rows_max:,}, "
          f"기본 lock_wait_timeout {default_lwt}초", flush=True)

    t0 = time.time()
    t_end = t0 + args.duration
    q = mp.Queue()
    procs = [mp.Process(target=worker, args=(t0, t_end, q, rows_max))
             for _ in range(args.procs)]
    for pr in procs:
        pr.start()

    snaps, ddl_result = [], {}
    threading.Thread(target=lock_watcher, args=(t0, t_end, snaps), daemon=True).start()
    if args.case != "ddl-alone":
        threading.Thread(target=long_txn, args=(t0,), daemon=True).start()
    if args.case != "control":
        threading.Thread(target=ddl, args=(t0, ddl_result), daemon=True).start()

    time.sleep(max(0, t_end - time.time()))
    samples = []
    for _ in procs:
        samples.extend(q.get())
    for pr in procs:
        pr.join(timeout=15)

    buckets = {}
    for sec, ms, ok in samples:
        b = buckets.setdefault(int(sec), {"n": 0, "err": 0, "lat": []})
        b["n"] += 1
        b["err"] += 0 if ok else 1
        b["lat"].append(ms)

    # 0초부터 끝까지 모든 초를 만든다. 완료된 조회가 한 건도 없는 초는 버킷이 생기지 않으므로,
    # 있는 버킷만 훑으면 정작 보려던 완전 정지 구간이 표에서 통째로 사라진다.
    timeline = []
    for sec in range(args.duration):
        b = buckets.get(sec)
        if not b:
            timeline.append({"sec": sec, "count": 0, "errors": 0,
                             "p50_ms": None, "p99_ms": None, "max_ms": None})
            continue
        lat = sorted(b["lat"])
        timeline.append({
            "sec": sec, "count": b["n"], "errors": b["err"],
            "p50_ms": lat[len(lat) // 2],
            "p99_ms": lat[min(len(lat) - 1, int(len(lat) * 0.99))],
            "max_ms": lat[-1],
        })

    # 평시 기준선은 DDL이 끼어들기 전 구간에서 잡는다. 정지 구간이 섞인 전체 중앙값을
    # 쓰면 기준선 자체가 내려가 정지가 덜 심해 보인다.
    pre = [t["count"] for t in timeline if t["sec"] < args.ddl_at and t["count"] > 0]
    base = sorted(pre)[len(pre) // 2] if pre else 0
    # 마지막 초는 측정 창 경계라 건수가 적게 잡히므로 판정에서 뺀다.
    stalled = [t["sec"] for t in timeline
               if base and t["sec"] < args.duration - 1 and t["count"] < base * 0.1]

    out = {
        "case": args.case,
        "mysql_version": version,
        "rows": rows_max,
        "default_lock_wait_timeout": default_lwt,
        "duration_s": args.duration,
        "procs": args.procs,
        "schedule": {"long_at": args.long_at, "ddl_at": args.ddl_at,
                     "long_end": args.long_end},
        "queries": len(samples),
        "errors": sum(1 for _, _, ok in samples if not ok),
        "median_qps": base,
        "stalled_seconds": stalled,
        "stall_len_s": len(stalled),
        "ddl": ddl_result or None,
        "events": events,
        "timeline": timeline,
        "lock_snapshots": snaps,
    }
    with open(args.out, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)

    print(f"  평시 초당 {base}건, 정지된 초 {len(stalled)}개 {stalled}", flush=True)
    admin.close()


if __name__ == "__main__":
    main()
