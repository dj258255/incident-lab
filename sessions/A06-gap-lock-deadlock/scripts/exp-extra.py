#!/usr/bin/env python3
"""README 의 "못 한 것" 네 개를 잰다.

  1) 세 번째 시나리오(획득 순서 엇갈림)를 문서에 넣지 않았습니다
     고전적 형태라 새로 배울 게 적다고 적었는데, 갭 락 데드락과 무엇이 다른지를
     나란히 놓으면 그 자체가 정보다. 순서 엇갈림은 격리 수준을 내려도 남고,
     갭 락 쪽은 사라진다. 그 차이를 잰다.

  2) 4절의 인덱스 없는 UPDATE 는 여전히 1회 실행입니다
     락 204건이 한 번의 스냅숏이다. 반복하고, 인덱스를 붙였을 때와
     READ COMMITTED 로 내렸을 때 이 수가 얼마나 줄어드는지 함께 잰다.

  3) 재시도 횟수와 백오프를 조합해 재지 않았습니다
     5절은 최대 4회, 선형 백오프 하나만 썼다. 지수와 지터를 나란히 놓는다.

  4) SKIP LOCKED 가 유효한 큐 소비 패턴은 만들지 않았습니다
     5절에서 이 시나리오에 안 통한다는 것만 확인했다. 통하는 조건을 만들어
     "언제 쓰는 도구인가"를 보인다.
"""
import argparse
import collections
import json
import random
import statistics
import threading
import time

import pymysql

p = argparse.ArgumentParser()
p.add_argument("--out", default="/results/extra.json")
p.add_argument("--rounds", type=int, default=30)
p.add_argument("--repeat", type=int, default=3)
args = p.parse_args()

DSN = dict(host="127.0.0.1", port=13315, user="root", password="lab",
           database="spoon", charset="utf8mb4")
LIVE_ID = 777
DATE = "2026-07-01"


def conn(autocommit=False):
    return pymysql.connect(**{**DSN, "autocommit": autocommit})


def run_sql(sql, params=None, autocommit=True):
    c = conn(autocommit)
    cur = c.cursor()
    cur.execute(sql, params)
    rows = cur.fetchall() if cur.description else None
    c.close()
    return rows


out = {}

# ── 1) 획득 순서 엇갈림 ─────────────────────────────────────────────────
# 두 세션이 같은 두 행을 반대 순서로 잠근다. A 는 1 다음 2, B 는 2 다음 1이다.
# 갭 락과 달리 이것은 이미 있는 행 두 개의 순서 문제다.
print("## 1) 획득 순서 엇갈림 데드락")
print("   갭 락 데드락과 같은 1213 이 나지만 반응하는 조건이 다릅니다.")
run_sql("DROP TABLE IF EXISTS acct")
run_sql("CREATE TABLE acct (id INT PRIMARY KEY, bal INT, tag INT, KEY idx_tag (tag))")
run_sql("INSERT INTO acct VALUES (1,1000,10),(2,1000,20)")


def crossed_round(isolation, stats):
    """A 는 1 다음 2, B 는 2 다음 1 순서로 잠근다."""
    barrier = threading.Barrier(2)
    res = {}

    def worker(name, first, second):
        c = conn()
        cur = c.cursor()
        try:
            cur.execute(f"SET SESSION TRANSACTION ISOLATION LEVEL {isolation}")
            cur.execute("BEGIN")
            cur.execute("SELECT id FROM acct WHERE id=%s FOR UPDATE", (first,))
            cur.fetchall()
            barrier.wait(timeout=15)
            time.sleep(0.1)
            cur.execute("SELECT id FROM acct WHERE id=%s FOR UPDATE", (second,))
            cur.fetchall()
            c.commit()
            res[name] = "성공"
        except threading.BrokenBarrierError:
            res[name] = "배리어 깨짐"
        except pymysql.Error as e:
            stats[e.args[0]] += 1
            res[name] = str(e.args[0])
        finally:
            try:
                c.rollback()
                c.close()
            except Exception:
                pass

    ts = [threading.Thread(target=worker, args=("A", 1, 2)),
          threading.Thread(target=worker, args=("B", 2, 1))]
    for t in ts:
        t.start()
    for t in ts:
        t.join(timeout=30)
    return res


crossed = []
for iso in ("REPEATABLE READ", "READ COMMITTED"):
    stats = collections.Counter()
    deadlocks = 0
    for _ in range(args.rounds):
        r = crossed_round(iso, stats)
        if "1213" in r.values():
            deadlocks += 1
    print(f"   {iso:<20} 데드락 {deadlocks:>3}/{args.rounds}회  에러 {dict(stats)}")
    crossed.append({"isolation": iso, "deadlocks": deadlocks,
                    "rounds": args.rounds, "errors": dict(stats)})
out["crossed_order"] = crossed
print("   갭 락 데드락은 READ COMMITTED 로 내리면 사라집니다. 갭 락이 없어지기 때문입니다.")
print("   순서 엇갈림은 내려도 남습니다. 이미 있는 행의 잠금 순서 문제라 갭과 무관합니다.")

# ── 2) 인덱스 없는 UPDATE 의 락 수를 반복해서 ───────────────────────────
print()
print("## 2) 인덱스 없는 UPDATE 가 잡는 락 수")
run_sql("DROP TABLE IF EXISTS wide")
run_sql("CREATE TABLE wide (id INT PRIMARY KEY, grp INT, val INT)")
run_sql("INSERT INTO wide (id, grp, val) "
        "SELECT n, n % 100, 0 FROM ("
        "  SELECT a.i + b.i*10 + c.i*100 + 1 AS n FROM "
        "  (SELECT 0 i UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION "
        "   SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a,"
        "  (SELECT 0 i UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION "
        "   SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b,"
        "  (SELECT 0 i UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION "
        "   SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c"
        ") t")


def count_locks(isolation, with_index):
    """UPDATE 를 열어 둔 채 performance_schema.data_locks 를 센다."""
    if with_index:
        try:
            run_sql("ALTER TABLE wide ADD KEY idx_grp (grp)")
        except pymysql.Error:
            pass
    else:
        try:
            run_sql("ALTER TABLE wide DROP KEY idx_grp")
        except pymysql.Error:
            pass
    c = conn()
    cur = c.cursor()
    cur.execute(f"SET SESSION TRANSACTION ISOLATION LEVEL {isolation}")
    cur.execute("BEGIN")
    cur.execute("UPDATE wide SET val = val + 1 WHERE grp = 7")
    # 잠금을 연 채로 다른 커넥션에서 센다.
    n = run_sql("SELECT COUNT(*) FROM performance_schema.data_locks "
                "WHERE OBJECT_NAME='wide'")[0][0]
    kinds = run_sql("SELECT LOCK_TYPE, LOCK_MODE, COUNT(*) FROM performance_schema.data_locks "
                    "WHERE OBJECT_NAME='wide' GROUP BY 1,2 ORDER BY 3 DESC")
    c.rollback()
    c.close()
    return n, [f"{a}/{b}:{cnt}" for a, b, cnt in kinds]


lock_rows = []
print(f"   {'조건':<38} {'락 수(회차별)':<20} {'중앙값':>8}")
for iso in ("REPEATABLE READ", "READ COMMITTED"):
    for with_index in (False, True):
        counts, kinds = [], []
        for _ in range(args.repeat):
            n, k = count_locks(iso, with_index)
            counts.append(n)
            kinds = k
        label = f"{iso} / {'인덱스 있음' if with_index else '인덱스 없음'}"
        print(f"   {label:<38} {str(counts):<20} {statistics.median(counts):>8.0f}")
        lock_rows.append({"isolation": iso, "with_index": with_index,
                          "counts": counts, "median": statistics.median(counts),
                          "kinds": kinds})
out["lock_counts"] = lock_rows
print("   인덱스가 없으면 조건에 안 맞는 행까지 잠깁니다. 붙이면 대상만 잠깁니다.")
print("   READ COMMITTED 는 조건에 안 맞는 행의 잠금을 문장이 끝날 때 놓아 줍니다.")

# ── 3) 백오프 조합 ──────────────────────────────────────────────────────
print()
print("## 3) 백오프 방식별 처리량")
run_sql("DELETE FROM settlement WHERE live_id = %s", (LIVE_ID,))


def retry_round(backoff, max_try, stats):
    barrier = threading.Barrier(2)
    res = {}

    def worker(name):
        attempts = 0
        while attempts < max_try:
            attempts += 1
            c = conn()
            cur = c.cursor()
            try:
                cur.execute("BEGIN")
                if attempts == 1:
                    try:
                        barrier.wait(timeout=15)
                    except threading.BrokenBarrierError:
                        pass
                cur.execute("SELECT id FROM settlement WHERE live_id=%s AND settle_date=%s "
                            "FOR UPDATE", (LIVE_ID, DATE))
                found = cur.fetchall()
                time.sleep(0.2)
                if found:
                    cur.execute("UPDATE settlement SET amount = amount + 1000 WHERE id = %s",
                                (found[0][0],))
                else:
                    cur.execute("INSERT INTO settlement (live_id, settle_date, amount) "
                                "VALUES (%s, %s, 1000)", (LIVE_ID, DATE))
                c.commit()
                c.close()
                res[name] = ("성공", attempts)
                return
            except pymysql.Error as e:
                code = e.args[0]
                stats[code] += 1
                try:
                    c.rollback()
                    c.close()
                except Exception:
                    pass
                if code in (1213, 1205, 1062) and attempts < max_try:
                    # 여기가 이 실험의 변수다.
                    if backoff == "선형":
                        time.sleep(0.05 * attempts)
                    elif backoff == "지수":
                        time.sleep(0.05 * (2 ** (attempts - 1)))
                    elif backoff == "지수+지터":
                        time.sleep(random.uniform(0, 0.05 * (2 ** (attempts - 1))))
                    continue
                res[name] = (str(code), attempts)
                return
        res[name] = ("소진", attempts)

    ts = [threading.Thread(target=worker, args=(n,)) for n in ("A", "B")]
    for t in ts:
        t.start()
    for t in ts:
        t.join(timeout=60)
    return res


backoff_rows = []
print(f"   {'백오프':<12} {'최대 시도':>9} {'성공':>10} {'총 시도':>8} {'소요':>9} {'최종금액':>10}")
for backoff in ("없음", "선형", "지수", "지수+지터"):
    for max_try in (4, 8):
        run_sql("DELETE FROM settlement WHERE live_id = %s", (LIVE_ID,))
        stats = collections.Counter()
        ok = total = 0
        t0 = time.time()
        for _ in range(args.rounds):
            r = retry_round(backoff, max_try, stats)
            for v, a in r.values():
                total += a
                if v == "성공":
                    ok += 1
        el = time.time() - t0
        amt = run_sql("SELECT COALESCE(SUM(amount),0) FROM settlement WHERE live_id=%s",
                      (LIVE_ID,))[0][0]
        print(f"   {backoff:<12} {max_try:>9} {ok:>7}/{args.rounds*2} {total:>8} "
              f"{el:>8.1f}초 {int(amt):>10,}")
        backoff_rows.append({"backoff": backoff, "max_try": max_try, "ok": ok,
                             "of": args.rounds * 2, "attempts": total,
                             "elapsed_s": round(el, 1), "final_amount": int(amt),
                             "errors": dict(stats)})
out["backoff"] = backoff_rows
print(f"   의도한 최종금액은 {args.rounds*2*1000:,}원입니다. 모자라면 그만큼 잃은 것입니다.")

# ── 4) SKIP LOCKED 가 통하는 조건 ───────────────────────────────────────
print()
print("## 4) SKIP LOCKED 가 통하는 큐 소비 패턴")
print("   5절의 시나리오는 두 세션이 '같은 한 행'을 원해서 SKIP LOCKED 가 일을 버립니다.")
print("   큐는 반대입니다. 일감이 여럿이고 누가 어느 것을 가져가든 상관없습니다.")
run_sql("DROP TABLE IF EXISTS job_queue")
run_sql("CREATE TABLE job_queue (id INT PRIMARY KEY AUTO_INCREMENT, "
        "state VARCHAR(10) DEFAULT 'ready', taken_by VARCHAR(10), KEY idx_state (state))")

JOBS = 200
WORKERS = 4


def queue_worker(name, mode, taken, lock):
    idle = 0
    while idle < 3:
        c = conn()
        cur = c.cursor()
        try:
            cur.execute("BEGIN")
            suffix = {"skiplocked": " SKIP LOCKED", "nowait": " NOWAIT"}.get(mode, "")
            cur.execute("SELECT id FROM job_queue WHERE state='ready' "
                        "ORDER BY id LIMIT 1 FOR UPDATE" + suffix)
            row = cur.fetchone()
            if not row:
                c.rollback()
                c.close()
                # 남은 일감이 정말 없는지 확인한다. SKIP LOCKED 는 남아 있어도
                # 잠긴 것뿐이면 빈 결과를 주므로 곧장 끝내면 안 된다.
                left = run_sql("SELECT COUNT(*) FROM job_queue WHERE state='ready'")[0][0]
                if left == 0:
                    return
                idle += 1
                time.sleep(0.02)
                continue
            idle = 0
            cur.execute("UPDATE job_queue SET state='done', taken_by=%s WHERE id=%s",
                        (name, row[0]))
            c.commit()
            with lock:
                taken[name] += 1
        except pymysql.Error as e:
            with lock:
                taken[f"에러{e.args[0]}"] += 1
            idle += 1
        finally:
            try:
                c.rollback()
                c.close()
            except Exception:
                pass


queue_rows = []
print(f"   {'방식':<14} {'처리':>9} {'소요':>9} {'초당':>8}  워커별 분배")
for mode in ("plain", "skiplocked", "nowait"):
    run_sql("TRUNCATE job_queue")
    run_sql(f"INSERT INTO job_queue (state) SELECT 'ready' FROM wide LIMIT {JOBS}")
    taken = collections.Counter()
    lock = threading.Lock()
    t0 = time.time()
    ts = [threading.Thread(target=queue_worker, args=(f"w{i}", mode, taken, lock))
          for i in range(WORKERS)]
    for t in ts:
        t.start()
    for t in ts:
        t.join(timeout=180)
    el = time.time() - t0
    done = run_sql("SELECT COUNT(*) FROM job_queue WHERE state='done'")[0][0]
    dist = ", ".join(f"{k} {v}" for k, v in sorted(taken.items()))
    print(f"   {mode:<14} {done:>5}/{JOBS} {el:>8.1f}초 {done/el if el else 0:>7.1f}  {dist}")
    queue_rows.append({"mode": mode, "done": done, "of": JOBS,
                       "elapsed_s": round(el, 1),
                       "per_s": round(done / el, 1) if el else 0,
                       "distribution": dict(taken)})
out["queue"] = queue_rows
print("   큐에서는 SKIP LOCKED 가 일을 버리지 않습니다. 잠긴 것을 건너뛰고 다음 일감을")
print("   가져갈 뿐이고 일감은 어차피 누군가 처리합니다. 5절과 결론이 갈리는 이유는")
print("   도구가 달라서가 아니라 '같은 한 행이 목표인가'가 달라서입니다.")

with open(args.out, "w") as f:
    json.dump(out, f, ensure_ascii=False, indent=1)
print(f"\n원문: {args.out}")
print(f"각 조건 {args.rounds}라운드 1회 실행이고 락 수만 {args.repeat}회 반복입니다.")
