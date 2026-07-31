#!/usr/bin/env python3
"""README 의 "못 한 것" 두 개를 잰다.

  1) 락 판별의 대안을 재지 않았습니다
     SHOW ENGINE INNODB STATUS 나 sys.innodb_lock_waits 가 data_lock_waits 보다
     나은지 비교하지 않았다. 셋을 같은 순간에 재서 무엇이 다른지 본다.

     세 방법이 같은 사실을 보는 것 같지만 갈리는 자리가 있다.
       data_lock_waits          진행 중인 대기 쌍. 가볍고 조인이 필요 없다
       sys.innodb_lock_waits    같은 정보에 스레드·질의를 붙인 뷰. 조인이 무겁다
       SHOW ENGINE INNODB STATUS  텍스트. 최근 데드락 하나와 현재 트랜잭션 목록.
                                  트랜잭션이 많으면 잘리고, 파싱해야 한다

  2) top SQL 은 190초 1회 실행입니다
     반복 측정이 없다. 같은 부하에서 여러 회차를 돌려 AAS 분해가 모이는지 본다.
"""
import argparse
import collections
import json
import re
import statistics
import threading
import time

import pymysql

p = argparse.ArgumentParser()
p.add_argument("--out", default="/results/lock-alternatives.json")
p.add_argument("--samples", type=int, default=40)
p.add_argument("--repeat", type=int, default=3)
p.add_argument("--duration", type=int, default=40)
args = p.parse_args()

DSN = dict(host="127.0.0.1", port=13312, user="root", password="lab",
           database="spoon", autocommit=True)


def conn(db=None):
    d = dict(DSN)
    if db:
        d["database"] = db
    return pymysql.connect(**d)


stop = threading.Event()


def hot_row_worker():
    """같은 행을 계속 갱신해 행 락 대기를 만든다."""
    c = conn()
    cur = c.cursor()
    try:
        while not stop.is_set():
            try:
                cur.execute("UPDATE live SET view_count = view_count + 1 WHERE id = 1")
            except pymysql.Error:
                pass
    finally:
        c.close()


def setup():
    c = conn()
    cur = c.cursor()
    cur.execute("CREATE TABLE IF NOT EXISTS live "
                "(id BIGINT PRIMARY KEY, view_count BIGINT DEFAULT 0)")
    cur.execute("INSERT IGNORE INTO live (id, view_count) VALUES (1, 0)")
    c.close()


# ── 세 방법을 같은 순간에 ────────────────────────────────────────────────
def count_data_lock_waits(cur):
    cur.execute("SELECT COUNT(*) FROM performance_schema.data_lock_waits")
    return cur.fetchone()[0]


def count_sys_view(cur):
    # sys.innodb_lock_waits 는 여러 테이블을 조인한 뷰다. 같은 사실을 보되 비싸다.
    cur.execute("SELECT COUNT(*) FROM sys.innodb_lock_waits")
    return cur.fetchone()[0]


def parse_engine_status(cur):
    """SHOW ENGINE INNODB STATUS 의 텍스트에서 대기 중인 트랜잭션 수를 센다."""
    cur.execute("SHOW ENGINE INNODB STATUS")
    row = cur.fetchone()
    text = row[2] if row and len(row) > 2 else ""
    waiting = len(re.findall(r"TRX HAS BEEN WAITING", text))
    lock_wait = len(re.findall(r"LOCK WAIT", text))
    truncated = "TRUNCATED" in text or "...truncated" in text.lower()
    return waiting, lock_wait, truncated, len(text)


def timed(fn, cur):
    t0 = time.perf_counter()
    v = fn(cur)
    return v, (time.perf_counter() - t0) * 1000


setup()
out = {}

print("## 1) 락 판별 세 방법을 같은 순간에")
print("   같은 부하에서 세 방법을 번갈아 재고, 값과 비용을 나란히 놓습니다.")
workers = [threading.Thread(target=hot_row_worker, daemon=True) for _ in range(8)]
for w in workers:
    w.start()
time.sleep(2)

c = conn("performance_schema")
cur = c.cursor()
rows = []
for _ in range(args.samples):
    dlw, t_dlw = timed(count_data_lock_waits, cur)
    try:
        sysv, t_sys = timed(count_sys_view, cur)
    except pymysql.Error as e:
        sysv, t_sys = None, 0.0
    (waiting, lockwait, trunc, size), t_eng = timed(parse_engine_status, cur)
    rows.append({"data_lock_waits": dlw, "ms_dlw": round(t_dlw, 2),
                 "sys_view": sysv, "ms_sys": round(t_sys, 2),
                 "engine_waiting": waiting, "engine_lockwait": lockwait,
                 "engine_truncated": trunc, "engine_bytes": size,
                 "ms_engine": round(t_eng, 2)})
    time.sleep(0.2)
stop.set()
for w in workers:
    w.join(timeout=5)
stop.clear()

def med(k):
    xs = [r[k] for r in rows if r[k] is not None]
    return statistics.median(xs) if xs else 0


print()
print(f"   {'방법':<26} {'중앙값':>10} {'최대':>8} {'조회 비용 중앙':>15}")
print(f"   {'data_lock_waits':<26} {med('data_lock_waits'):>10.0f} "
      f"{max(r['data_lock_waits'] for r in rows):>8} {med('ms_dlw'):>14.2f}ms")
if any(r["sys_view"] is not None for r in rows):
    print(f"   {'sys.innodb_lock_waits':<26} {med('sys_view'):>10.0f} "
          f"{max((r['sys_view'] or 0) for r in rows):>8} {med('ms_sys'):>14.2f}ms")
else:
    print(f"   {'sys.innodb_lock_waits':<26} {'조회 실패':>10}")
print(f"   {'ENGINE STATUS(LOCK WAIT)':<26} {med('engine_lockwait'):>10.0f} "
      f"{max(r['engine_lockwait'] for r in rows):>8} {med('ms_engine'):>14.2f}ms")
print()
print(f"   ENGINE STATUS 텍스트 크기 중앙 {med('engine_bytes'):,.0f}바이트, "
      f"잘림 {sum(1 for r in rows if r['engine_truncated'])}/{len(rows)}회")
print()

# ── 1-b) 대기가 없을 때 ────────────────────────────────────────────────
# 위는 락 경합이 있는 조건 하나다. "세 방법을 부하 없는 구간에서 재지 않았습니다"가
# README 에 남아 있었다. 판별 비용이 대기 유무에 따라 달라지는지 본다.
# ENGINE STATUS 는 대기 목록이 비어도 전체 상태를 통째로 만들어 내므로, 비용이
# 대기 수와 무관하다면 그것이 이 방법의 성질이다.
print("## 1-b) 대기가 없을 때 세 방법의 비용")
print("   워커를 띄우지 않고 같은 방법을 같은 횟수로 재 봅니다.")
idle_rows = []
for _ in range(args.samples):
    dlw, t_dlw = timed(count_data_lock_waits, cur)
    try:
        sysv, t_sys = timed(count_sys_view, cur)
    except pymysql.Error:
        sysv, t_sys = None, 0.0
    (waiting, lockwait, trunc, size), t_eng = timed(parse_engine_status, cur)
    idle_rows.append({"data_lock_waits": dlw, "ms_dlw": round(t_dlw, 2),
                      "sys_view": sysv, "ms_sys": round(t_sys, 2),
                      "engine_lockwait": lockwait, "engine_truncated": trunc,
                      "engine_bytes": size, "ms_engine": round(t_eng, 2)})
    time.sleep(0.2)


def imed(k):
    xs = [r[k] for r in idle_rows if r[k] is not None]
    return statistics.median(xs) if xs else 0


print()
print(f"   {'방법':<26} {'대기 중앙':>10} {'조회 비용 중앙':>15} {'부하 있을 때 대비':>18}")
for label, cnt, cost, bcost in (
        ("data_lock_waits", 'data_lock_waits', 'ms_dlw', med('ms_dlw')),
        ("sys.innodb_lock_waits", 'sys_view', 'ms_sys', med('ms_sys')),
        ("ENGINE STATUS(LOCK WAIT)", 'engine_lockwait', 'ms_engine', med('ms_engine'))):
    ic = imed(cost)
    ratio = (ic / bcost) if bcost else 0
    print(f"   {label:<26} {imed(cnt):>10.0f} {ic:>14.2f}ms {ratio:>17.2f}배")
print()
print(f"   ENGINE STATUS 텍스트 크기 중앙 {imed('engine_bytes'):,.0f}바이트, "
      f"잘림 {sum(1 for r in idle_rows if r['engine_truncated'])}/{len(idle_rows)}회")
print()
out["idle"] = {"samples": idle_rows}

print("   읽는 법. 세 값이 같은 방향으로 움직이면 어느 것을 써도 판별은 됩니다.")
print("   갈리는 것은 비용과 형태입니다. data_lock_waits 는 숫자를 바로 주고,")
print("   sys 뷰는 같은 정보에 질의 텍스트를 붙이는 대신 조인이 붙고,")
print("   ENGINE STATUS 는 매번 수만 바이트를 파싱해야 하며 트랜잭션이 많으면 잘립니다.")
print("   1초 간격 샘플러에 넣을 것은 가장 싼 것이어야 합니다.")
out["lock_methods"] = {"samples": rows,
                       "median_ms": {"data_lock_waits": med("ms_dlw"),
                                     "sys_view": med("ms_sys"),
                                     "engine_status": med("ms_engine")}}

# ── 2) top SQL 반복 ─────────────────────────────────────────────────────
print()
print("## 2) top SQL 분해를 반복해서")
print(f"   같은 부하로 {args.duration}초씩 {args.repeat}회 재고 AAS 분해가 모이는지 봅니다.")

Q = """
SELECT t.PROCESSLIST_ID,
       w.EVENT_NAME AS wait_event,
       LEFT(s.DIGEST_TEXT, 60) AS digest_text
FROM performance_schema.threads t
LEFT JOIN performance_schema.events_waits_current w
       ON w.THREAD_ID = t.THREAD_ID AND w.END_EVENT_ID IS NULL
LEFT JOIN performance_schema.events_statements_current s
       ON s.THREAD_ID = t.THREAD_ID AND s.END_EVENT_ID IS NULL
WHERE t.TYPE = 'FOREGROUND' AND t.PROCESSLIST_ID IS NOT NULL
  AND t.PROCESSLIST_COMMAND NOT IN ('Sleep', 'Daemon')
"""

runs = []
for r in range(args.repeat):
    stop.clear()
    ws = [threading.Thread(target=hot_row_worker, daemon=True) for _ in range(8)]
    for w in ws:
        w.start()
    time.sleep(2)
    c2 = conn("performance_schema")
    cur2 = c2.cursor()
    me = c2.thread_id()
    sql_total = collections.Counter()
    samples = 0
    end = time.time() + args.duration
    while time.time() < end:
        t0 = time.time()
        cur2.execute(Q)
        by_session = {}
        for pid, ev, dtext in cur2.fetchall():
            if pid == me:
                continue
            by_session[pid] = (dtext or "(질의 없음)").strip()
        for dtext in by_session.values():
            sql_total[dtext] += 1
        samples += 1
        time.sleep(max(0, 1.0 - (time.time() - t0)))
    c2.close()
    stop.set()
    for w in ws:
        w.join(timeout=5)
    top = sql_total.most_common(3)
    runs.append({"samples": samples,
                 "top": [{"digest_text": k, "aas": round(v / samples, 2)} for k, v in top]})
    print(f"   회차 {r+1}: 샘플 {samples}회")
    for k, v in top:
        print(f"     AAS {v/samples:>5.2f}  {k[:60]}")

out["top_sql_runs"] = runs
if len(runs) >= 2:
    print()
    keys = set()
    for r in runs:
        for t in r["top"]:
            keys.add(t["digest_text"])
    print(f"   {'질의':<48} " + " ".join(f"{'회차'+str(i+1):>8}" for i in range(len(runs))))
    for k in sorted(keys):
        vals = []
        for r in runs:
            v = next((t["aas"] for t in r["top"] if t["digest_text"] == k), 0.0)
            vals.append(v)
        print(f"   {k[:48]:<48} " + " ".join(f"{v:>8.2f}" for v in vals))
    print()
    print("   회차마다 같은 질의가 같은 자리를 차지하면 분해가 안정적인 것입니다.")

c.close()
with open(args.out, "w") as f:
    json.dump(out, f, ensure_ascii=False, indent=1)
print(f"\n원문: {args.out}")
print(f"1절은 {args.samples}샘플 1회, 2절은 {args.duration}초 {args.repeat}회입니다.")
