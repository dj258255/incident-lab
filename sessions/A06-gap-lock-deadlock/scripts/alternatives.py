#!/usr/bin/env python3
"""시나리오 1의 다른 선택지 넷을 각각 30회 돌려 데드락이 어떻게 되는지 센다.

README 의 "못 한 것"에 적어 둔 두 항목을 처리한다.
  - SELECT ... FOR UPDATE SKIP LOCKED / NOWAIT 비교
  - 재시도 전략

넷을 고른 이유가 다르다.
  nowait      : 대기를 없애면 데드락도 없어지는가. 에러의 종류가 무엇으로 바뀌는가
  skiplocked  : 흔히 함께 소개되지만 갭 락에 통하는가. 통하지 않을 것으로 본다
  retry       : 데드락은 정상 동작의 일부이므로 잡아 재시도하는 것이 정석이다.
                재시도로 최종 성공률이 100%가 되는지, 총 시도가 몇 번이 되는지 센다
  insert_ignore : ON DUPLICATE KEY UPDATE 말고 이쪽도 갭 락 단계를 없애는가

원 스크립트(deadlock.py)를 건드리지 않는다. 발행된 표의 값이 그 파일의 실행분이다.
"""
import sys
import threading
import time

import pymysql

DSN = dict(host="127.0.0.1", port=13315, user="root", password="lab",
           database="spoon", autocommit=False)
RUNS = 30
LIVE_ID = 3
DATE = "2026-07-30"


def conn(autocommit=False):
    return pymysql.connect(**{**DSN, "autocommit": autocommit})


def reset():
    c = conn(True)
    c.cursor().execute("DELETE FROM settlement WHERE live_id = %s", (LIVE_ID,))
    c.close()


def one_round(mode, stats):
    """두 세션이 동시에 "없으면 넣는다"를 실행한다. mode 가 방법을 정한다."""
    barrier = threading.Barrier(2)
    result = {}

    def worker(name):
        attempts = 0
        max_try = 4 if mode == "retry" else 1
        while attempts < max_try:
            attempts += 1
            c = conn()
            cur = c.cursor()
            try:
                cur.execute("BEGIN")
                # 배리어는 첫 문장 앞에 둔다. 뒤에 두면 두 세션의 SELECT 가
                # 동시에 돌지 않아 NOWAIT 이 경합을 만들지 못한다.
                if attempts == 1:
                    try:
                        barrier.wait(timeout=15)
                    except threading.BrokenBarrierError:
                        # 상대가 먼저 끝났다. 이 라운드는 경합이 없었으므로 그대로 진행한다.
                        pass
                if mode == "insert_ignore":
                    cur.execute(
                        "INSERT IGNORE INTO settlement (live_id, settle_date, amount) "
                        "VALUES (%s, %s, 1000)", (LIVE_ID, DATE))
                else:
                    suffix = {"nowait": " NOWAIT",
                              "skiplocked": " SKIP LOCKED"}.get(mode, "")
                    cur.execute(
                        "SELECT id FROM settlement WHERE live_id=%s AND settle_date=%s "
                        "FOR UPDATE" + suffix, (LIVE_ID, DATE))
                    found = cur.fetchall()
                    time.sleep(0.2)
                    if found:
                        # "있으면 더한다". 재시도가 수렴하려면 이 분기가 있어야 한다.
                        cur.execute(
                            "UPDATE settlement SET amount = amount + 1000 WHERE id = %s",
                            (found[0][0],))
                    else:
                        cur.execute(
                            "INSERT INTO settlement (live_id, settle_date, amount) "
                            "VALUES (%s, %s, 1000)", (LIVE_ID, DATE))
                c.commit()
                result[name] = ("성공", attempts)
                c.close()
                return
            except pymysql.Error as e:
                code = e.args[0]
                c.rollback()
                c.close()
                stats.setdefault(code, 0)
                stats[code] += 1
                # 데드락(1213), 락 대기 타임아웃(1205), 중복키(1062) 를 재시도 대상으로 둔다.
                # 중복키는 상대가 먼저 넣었다는 뜻이므로 다시 돌면 UPDATE 분기로 간다.
                if mode == "retry" and code in (1213, 1205, 1062) and attempts < max_try:
                    time.sleep(0.05 * attempts)
                    continue
                result[name] = (f"{code}", attempts)
                return
        result[name] = ("재시도 소진", attempts)

    ts = [threading.Thread(target=worker, args=(n,)) for n in ("A", "B")]
    for t in ts:
        t.start()
    for t in ts:
        t.join(timeout=40)
    return result


def run(mode, out):
    reset()
    stats = {}
    ok = 0
    total_attempts = 0
    t0 = time.time()
    for _ in range(RUNS):
        reset()
        r = one_round(mode, stats)
        for _name, (verdict, attempts) in r.items():
            total_attempts += attempts
            if verdict == "성공":
                ok += 1
    el = time.time() - t0
    tries = RUNS * 2
    # 마지막 라운드의 최종 금액. 두 요청이 각각 1000 을 넣으려 했으므로
    # 의도한 결과는 2000 이다. 1000 이면 한 건이 조용히 사라진 것이다.
    cc = conn(True)
    ccur = cc.cursor()
    ccur.execute("SELECT COALESCE(SUM(amount),0) FROM settlement WHERE live_id=%s AND settle_date=%s", (LIVE_ID, DATE))
    amount = ccur.fetchone()[0]
    cc.close()
    line = (f"  {mode:14} 시도 {tries}건  성공 {ok}건  "
            f"총 실행 {total_attempts}회  {el:.1f}초  최종금액 {amount}")
    out.append(line)
    print(line)
    if stats:
        names = {1213: "데드락", 1205: "락 대기 타임아웃", 1062: "중복키",
                 3572: "NOWAIT 즉시 실패"}
        detail = ", ".join(f"{names.get(k, k)}({k}) {v}건"
                          for k, v in sorted(stats.items()))
        out.append(f"                 에러: {detail}")
        print(f"                 에러: {detail}")
    else:
        out.append("                 에러: 없음")
        print("                 에러: 없음")
    return dict(mode=mode, ok=ok, tries=tries, attempts=total_attempts, stats=stats, amount=amount)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "results/alternatives.txt"
    out = ["# 시나리오 1의 다른 선택지. 각 조건 30회(시도 60건).",
           f"# MySQL {conn(True).get_server_info()}, REPEATABLE READ 기본값",
           "",
           "발행된 표의 기준선은 원래 방식 데드락 30회, ON DUPLICATE KEY UPDATE 0회,",
           "READ COMMITTED 데드락 0회에 중복키 30회입니다(deadlock.py 실행분).",
           "아래는 그 표에 없던 넷입니다.",
           ""]
    for line in out:
        print(line)
    rows = [run(m, out) for m in ("nowait", "skiplocked", "retry", "insert_ignore")]

    out += ["", "## 읽는 방법", ""]
    out += ["  `총 실행` 은 실제로 DB 에 던진 트랜잭션 수입니다. retry 만 시도보다 큽니다."]
    out += ["  `성공` 은 60건 중 최종적으로 커밋된 수입니다."]
    out += ["  `최종금액` 은 마지막 라운드가 남긴 합계입니다. 두 요청이 각각 1000 을 넣으려"]
    out += ["  했으므로 의도한 결과는 2000 이고, 1000 이면 한 건이 조용히 사라진 것입니다."]
    for r in rows:
        if r["mode"] == "nowait" and 3572 in r["stats"]:
            out.append("  nowait 는 대기를 없애 데드락을 없앴지만 에러를 3572 로 바꿉니다.")
        if r["mode"] == "skiplocked" and 1213 in r["stats"]:
            out.append("  skiplocked 는 갭 락에 통하지 않습니다. 건너뛸 행이 없기 때문입니다.")
        if r["mode"] == "retry":
            out.append(f"  retry 는 {r['tries']}건을 {r['attempts']}회 실행으로 처리했습니다.")
        if r["mode"] == "insert_ignore" and r["amount"] < 2000:
            out.append(f"  insert_ignore 는 데드락을 없애지만 금액이 {r['amount']} 입니다. 두 번째 요청이 조용히 사라집니다.")
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")
    print(f"\n원문: {path}")


if __name__ == "__main__":
    main()
