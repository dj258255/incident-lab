#!/usr/bin/env python3
"""갭 락 데드락 세 가지를 재현하고, 그때의 락 상태와 데드락 그래프를 원문으로 남긴다.

데드락은 부하가 아니라 순서 문제라서 스레드 두 개면 충분하다.
중요한 건 "언제 무엇을 잡고 있었나"이므로, 각 단계마다 data_locks를 찍는다.

시나리오
  1. 없으면 넣는다(INSERT ... 유니크 충돌)  : 두 세션이 같은 갭에 insert intention을 요청
  2. 인덱스 없는 컬럼 UPDATE                : 스캔한 행 전부에 락이 걸려 범위가 겹친다
  3. 획득 순서 엇갈림                        : 같은 자원을 반대 순서로 잡는 고전적 형태
"""
import sys
import threading
import time

import pymysql

DSN = dict(host="127.0.0.1", port=13315, user="root", password="lab",
           database="spoon", autocommit=False)


def conn():
    return pymysql.connect(**DSN)


def admin():
    c = pymysql.connect(**{**DSN, "autocommit": True})
    return c, c.cursor()


def dump_locks(tag, out):
    """지금 이 순간 누가 무엇을 어떤 모드로 잡고 있는지 찍는다.

    LOCK_MODE의 X,GAP / X,INSERT_INTENTION 표기가 이 세션의 증거다.
    """
    c, cur = admin()
    cur.execute("""
        SELECT ENGINE_TRANSACTION_ID, OBJECT_NAME, INDEX_NAME,
               LOCK_TYPE, LOCK_MODE, LOCK_STATUS, LOCK_DATA
        FROM performance_schema.data_locks
        WHERE OBJECT_SCHEMA = 'spoon' ORDER BY ENGINE_TRANSACTION_ID, LOCK_MODE""")
    rows = cur.fetchall()
    out.append(f"\n[{tag}] performance_schema.data_locks")
    out.append(f"{'트랜잭션':>14} {'테이블':<12} {'인덱스':<14} {'종류':<8} {'모드':<22} {'상태':<8} 데이터")
    for r in rows:
        out.append(f"{r[0]:>14} {r[1]:<12} {str(r[2]):<14} {r[3]:<8} {r[4]:<22} {r[5]:<8} {r[6]}")
    c.close()
    return rows


def latest_deadlock():
    c, cur = admin()
    cur.execute("SHOW ENGINE INNODB STATUS")
    txt = cur.fetchone()[2]
    c.close()
    if "LATEST DETECTED DEADLOCK" not in txt:
        return "데드락 기록 없음"
    seg = txt.split("LATEST DETECTED DEADLOCK", 1)[1]
    seg = seg.split("------------\nTRANSACTIONS", 1)[0]
    return "LATEST DETECTED DEADLOCK" + seg


# ── 시나리오 1: 없으면 넣는다 ────────────────────────────────
def scenario_upsert(out):
    out.append("=" * 78)
    out.append("시나리오 1. 없으면 넣고 있으면 더한다 (유니크 키 + INSERT)")
    out.append("=" * 78)
    out.append("""
두 세션이 같은 (live_id, settle_date)를 동시에 정산한다.
각자 먼저 SELECT로 확인하고, 없으면 INSERT한다. 애플리케이션에서 가장 흔한 형태다.

  세션 A: SELECT ... FOR UPDATE (없음 → 갭 락 획득)
  세션 B: SELECT ... FOR UPDATE (없음 → 같은 갭에 갭 락 획득. 갭 락끼리는 공존한다)
  세션 A: INSERT  → insert intention 락 요청. B의 갭 락과 충돌해서 대기
  세션 B: INSERT  → 같은 이유로 대기. 서로를 기다리므로 데드락""")

    # 행이 이미 있으면 갭 락이 아니라 레코드 락을 잡는다. 매번 없는 상태에서 시작한다.
    c, cur = admin()
    cur.execute("DELETE FROM settlement WHERE live_id = 1")
    c.close()

    barrier = threading.Barrier(2)
    result = {}

    def worker(name, delay):
        c = conn()
        cur = c.cursor()
        try:
            cur.execute("BEGIN")
            cur.execute("SELECT id FROM settlement WHERE live_id=1 AND settle_date='2026-07-29' FOR UPDATE")
            cur.fetchall()
            barrier.wait(timeout=10)          # 둘 다 갭 락을 잡을 때까지 맞춘다
            time.sleep(delay)
            cur.execute("INSERT INTO settlement (live_id, settle_date, amount) "
                        "VALUES (1, '2026-07-29', 1000)")
            c.commit()
            result[name] = "성공"
        except pymysql.Error as e:
            result[name] = f"{e.args[0]} {e.args[1][:60]}"
            c.rollback()
        finally:
            c.close()

    ta = threading.Thread(target=worker, args=("A", 0.0))
    tb = threading.Thread(target=worker, args=("B", 0.3))
    ta.start()
    tb.start()
    time.sleep(0.15)                          # 둘 다 갭 락만 잡은 상태를 포착한다
    dump_locks("INSERT 직전: 두 세션이 같은 갭에 갭 락", out)
    ta.join()
    tb.join()
    out.append(f"\n결과: 세션A = {result.get('A')}")
    out.append(f"      세션B = {result.get('B')}")
    out.append("\n" + latest_deadlock())
    return result


# ── 시나리오 2: 인덱스 없는 컬럼 UPDATE ──────────────────────
def scenario_no_index(out):
    out.append("\n" + "=" * 78)
    out.append("시나리오 2. 인덱스 없는 컬럼으로 UPDATE (락 범위가 테이블 전체로)")
    out.append("=" * 78)
    out.append("""
status 컬럼에는 인덱스가 없다. WHERE status='PENDING'으로 UPDATE하면
InnoDB는 전 행을 훑으면서 훑은 행마다 락을 잡는다. 조건에 맞지 않는 행의 락은
곧 풀리지만, 그 사이에 다른 세션과 겹치면 데드락이 된다.""")
    c, cur = admin()
    cur.execute("TRUNCATE payout")
    cur.executemany("INSERT INTO payout (live_id, status, amount) VALUES (%s,%s,%s)",
                    [(i, "PENDING" if i % 2 else "DONE", i * 100) for i in range(1, 201)])
    c.close()

    barrier = threading.Barrier(2)
    result = {}

    def worker(name, order):
        c = conn()
        cur = c.cursor()
        try:
            cur.execute("BEGIN")
            # 같은 조건을 서로 반대 순서로 훑게 만든다
            cur.execute(f"UPDATE payout SET amount = amount + 1 "
                        f"WHERE status = 'PENDING' AND live_id {'<' if order else '>'} 100")
            barrier.wait(timeout=10)
            time.sleep(0.1)
            cur.execute(f"UPDATE payout SET amount = amount + 1 "
                        f"WHERE status = 'PENDING' AND live_id {'>' if order else '<'} 100")
            c.commit()
            result[name] = "성공"
        except pymysql.Error as e:
            result[name] = f"{e.args[0]} {e.args[1][:60]}"
            c.rollback()
        finally:
            c.close()

    ta = threading.Thread(target=worker, args=("A", True))
    tb = threading.Thread(target=worker, args=("B", False))
    ta.start()
    tb.start()
    time.sleep(0.15)
    rows = dump_locks("두 번째 UPDATE 직전", out)
    out.append(f"→ 잡힌 락 {len(rows)}개. 200행짜리 테이블에서 조건에 맞는 건 100행이다.")
    ta.join()
    tb.join()
    out.append(f"\n결과: 세션A = {result.get('A')}")
    out.append(f"      세션B = {result.get('B')}")
    out.append("\n" + latest_deadlock())
    return result


# ── 해소 검증 ────────────────────────────────────────────────
def fix_upsert(out, mode):
    """시나리오 1을 세 가지 방법으로 고쳐 각각 데드락이 사라지는지 확인한다."""
    c, cur = admin()
    cur.execute("DELETE FROM settlement WHERE live_id = 2")
    c.close()

    barrier = threading.Barrier(2)
    result = {}

    def worker(name):
        c = conn()
        cur = c.cursor()
        try:
            if mode == "rc":
                cur.execute("SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED")
            cur.execute("BEGIN")
            if mode == "upsert":
                # 확인 후 삽입을 한 문장으로 합친다. 갭 락을 먼저 잡는 단계가 없어진다.
                barrier.wait(timeout=10)
                cur.execute("INSERT INTO settlement (live_id, settle_date, amount) "
                            "VALUES (2, '2026-07-29', 1000) "
                            "ON DUPLICATE KEY UPDATE amount = amount + VALUES(amount)")
            elif mode == "rc":
                # READ COMMITTED에는 갭 락이 없다.
                # 주의: 격리 수준 변경은 BEGIN 앞에 와야 한다. 뒤에 두면 @@transaction_isolation은
                # 바뀐 값을 보여주는데 실행 중인 트랜잭션은 그대로 REPEATABLE READ로 돈다.
                cur.execute("SELECT id FROM settlement WHERE live_id=2 AND settle_date='2026-07-29' FOR UPDATE")
                cur.fetchall()
                barrier.wait(timeout=10)
                time.sleep(0.2)
                cur.execute("INSERT INTO settlement (live_id, settle_date, amount) "
                            "VALUES (2, '2026-07-29', 1000)")
            c.commit()
            result[name] = "성공"
        except pymysql.Error as e:
            result[name] = f"{e.args[0]} {e.args[1][:55]}"
            c.rollback()
        finally:
            c.close()

    ts = [threading.Thread(target=worker, args=(n,)) for n in ("A", "B")]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    return result


def main():
    out = []
    scenario_upsert(out)
    scenario_no_index(out)

    out.append("\n" + "=" * 78)
    out.append("해소 검증 (시나리오 1을 각 방법으로 30회 반복)")
    out.append("=" * 78)
    for mode, ko in (("upsert", "INSERT ... ON DUPLICATE KEY UPDATE"),
                     ("rc", "READ COMMITTED로 낮추기")):
        deadlocks = 0
        dup = 0
        for _ in range(30):
            r = fix_upsert(out, mode)
            for v in r.values():
                if v.startswith("1213"):
                    deadlocks += 1
                elif v.startswith("1062"):
                    dup += 1
        out.append(f"{ko:<40} 데드락 {deadlocks}회, 중복키 에러 {dup}회 (60시도)")

    # 원래 방식도 같은 횟수로 재서 비교 기준을 만든다
    deadlocks = 0
    for _ in range(30):
        c, cur = admin()
        cur.execute("DELETE FROM settlement WHERE live_id = 3")
        c.close()
        barrier = threading.Barrier(2)
        res = {}

        def w(name):
            c = conn()
            cur = c.cursor()
            try:
                cur.execute("BEGIN")
                cur.execute("SELECT id FROM settlement WHERE live_id=3 AND settle_date='2026-07-29' FOR UPDATE")
                cur.fetchall()
                barrier.wait(timeout=10)
                cur.execute("INSERT INTO settlement (live_id, settle_date, amount) VALUES (3,'2026-07-29',1000)")
                c.commit()
                res[name] = "성공"
            except pymysql.Error as e:
                res[name] = f"{e.args[0]}"
                c.rollback()
            finally:
                c.close()
        ts = [threading.Thread(target=w, args=(n,)) for n in ("A", "B")]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        deadlocks += sum(1 for v in res.values() if v.startswith("1213"))
    out.append(f"{'원래 방식 (SELECT FOR UPDATE 후 INSERT)':<40} 데드락 {deadlocks}회 (60시도)")

    path = sys.argv[1] if len(sys.argv) > 1 else "results/deadlock.txt"
    with open(path, "w") as f:
        f.write("\n".join(out))
    print("\n".join(out[-12:]))
    print(f"\n저장: {path}")


if __name__ == "__main__":
    main()
