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
# 지금까지 쟀던 DDL 은 ADD COLUMN 하나다. MySQL 8.4 에서 그것은 INSTANT 라 실행 자체가
# 0.09초이고, 테이블을 다시 쓰는 DDL 이 같은 MDL 대기 아래에서 어떻게 되는지는 안 봤다.
# 알고리즘을 명시해 셋을 갈라 잰다. 명시하면 그 알고리즘으로 못 할 때 서버가 거부하므로,
# "INSTANT 인 줄 알았는데 COPY 였다" 같은 일이 안 생긴다.
p.add_argument("--ddl", default="instant", choices=["instant", "inplace", "copy"],
               help="instant=ADD COLUMN, inplace=ADD INDEX, copy=테이블 재작성")
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


# 알고리즘을 명시한 세 DDL. 서버가 그 알고리즘으로 못 하면 에러를 내므로 조건이 안 선 채로
# 지나가지 않는다.
DDL_STMT = {
    "instant": "ALTER TABLE orders ADD COLUMN memo VARCHAR(64) NULL, ALGORITHM=INSTANT",
    "inplace": "ALTER TABLE orders ADD INDEX idx_mdl_probe (status, amount), "
               "ALGORITHM=INPLACE, LOCK=NONE",
    "copy":    "ALTER TABLE orders ADD COLUMN memo VARCHAR(64) NULL, ALGORITHM=COPY",
}


def ddl(t0, result):
    time.sleep(max(0, args.ddl_at - (time.time() - t0)))
    c = connect()
    cur = c.cursor()
    if args.case == "ddl-timeout":
        cur.execute(f"SET SESSION lock_wait_timeout = {args.lock_wait_timeout}")
        mark(t0, "DDL", f"lock_wait_timeout={args.lock_wait_timeout}초로 설정")
    cur.execute("SELECT @@lock_wait_timeout")
    lwt = cur.fetchone()[0]
    stmt = DDL_STMT[args.ddl]
    mark(t0, "DDL", f"실행 시작 (lock_wait_timeout={lwt}) {stmt}")
    s = time.perf_counter()
    try:
        cur.execute(stmt)
        el = time.perf_counter() - s
        result.update({"ok": True, "elapsed_s": round(el, 2), "error": None,
                       "lock_wait_timeout": lwt, "ddl_kind": args.ddl, "stmt": stmt})
        mark(t0, "DDL", f"성공, {el:.2f}초 걸림")
    except Exception as e:
        el = time.perf_counter() - s
        result.update({"ok": False, "elapsed_s": round(el, 2), "error": str(e),
                       "lock_wait_timeout": lwt, "ddl_kind": args.ddl, "stmt": stmt})
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
    # inplace 조건은 컬럼이 아니라 인덱스를 남긴다. 이것도 지워야 다음 회차가 중복으로 죽지 않는다.
    acur.execute("""SELECT COUNT(*) FROM information_schema.STATISTICS
                    WHERE TABLE_SCHEMA='lab' AND TABLE_NAME='orders'
                      AND INDEX_NAME='idx_mdl_probe'""")
    if acur.fetchone()[0]:
        acur.execute("ALTER TABLE orders DROP INDEX idx_mdl_probe")
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
    #
    # 주의: 이 값(median_qps)은 조건 사이의 비교용이 아니다. 구간이 sec < ddl_at이고
    # ddl_at은 네 조건 모두 25로 고정이라, ddl-timeout 조건의 SET lock_wait_timeout=2가
    # 실행되는 25.0초보다 앞이다. 즉 어떤 조건에서도 개입이 들어가기 전 구간이므로,
    # 조건별로 이 값이 다르면 그것은 설정의 효과가 아니라 실행 간 편차다.
    # (실제로 ddl-default 실행은 0초부터 다른 세 조건보다 30%가량 낮게 나왔다.)
    pre = [t["count"] for t in timeline if t["sec"] < args.ddl_at and t["count"] > 0]
    base = sorted(pre)[len(pre) // 2] if pre else 0
    # 마지막 초는 측정 창 경계라 건수가 적게 잡히므로 판정에서 뺀다.
    # "정지"는 완료 건수가 기준선의 10% 아래인 초다. 완료가 정확히 0인 초와 같지 않다.
    # 겹침 조건에서 stalled는 25~44초 20개지만 0건인 초는 26~44초 19개다(25초는 104건).
    stalled = [t["sec"] for t in timeline
               if base and t["sec"] < args.duration - 1 and t["count"] < base * 0.1]
    zero_secs = [t["sec"] for t in timeline
                 if t["sec"] < args.duration - 1 and t["count"] == 0]

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
        "zero_seconds": zero_secs,
        "zero_len_s": len(zero_secs),
        "ddl": ddl_result or None,
        "events": events,
        "timeline": timeline,
        "lock_snapshots": snaps,
    }
    with open(args.out, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)

    print(f"  평시 초당 {base}건, 정지된 초 {len(stalled)}개 {stalled}", flush=True)
    print(f"  그중 완료 0건인 초 {len(zero_secs)}개 {zero_secs}", flush=True)
    admin.close()


if __name__ == "__main__":
    main()
