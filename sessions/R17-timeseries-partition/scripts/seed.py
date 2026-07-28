#!/usr/bin/env python3
"""시청 로그 14일치를 두 테이블에 동일하게 적재한다.

데이터는 R13과 같은 원칙으로 만든다. 실제 시청 로그를 닮게, 그리고 검증 가능하게.
  - 방송 쏠림: 방송 1,000개에 Zipf(s=1.2). 인기 방송에 이벤트가 몰린다
  - 이벤트 구성: 입장 30% / 퇴장 30% / 채팅 35% / 선물 5%
  - 하루 안에서 시각은 저녁 피크(20~24시)에 60%가 몰리는 이봉 분포
적재 후 일별 건수를 덤프해 분포를 감사한다.
"""
import argparse
import datetime as dt
import random
import time

import pymysql

DAYS = 14
BASE = dt.date(2026, 7, 14)
LIVES = 1000
ZIPF_S = 1.2
BATCH = 5000

random.seed(20260728)   # 재현 가능해야 하므로 시드를 고정한다

# Zipf 누적분포
w = [1 / (i + 1) ** ZIPF_S for i in range(LIVES)]
total_w = sum(w)
cdf = []
acc = 0.0
for x in w:
    acc += x / total_w
    cdf.append(acc)


def pick_live():
    r = random.random()
    lo, hi = 0, LIVES - 1
    while lo < hi:
        mid = (lo + hi) // 2
        if cdf[mid] < r:
            lo = mid + 1
        else:
            hi = mid
    return lo + 1


def pick_time(day):
    """저녁 피크 이봉 분포. 60%는 20~24시, 40%는 나머지 시간에 균등."""
    if random.random() < 0.6:
        sec = random.randint(20 * 3600, 24 * 3600 - 1)
    else:
        sec = random.randint(0, 20 * 3600 - 1)
    t = dt.datetime.combine(day, dt.time()) + dt.timedelta(seconds=sec,
                                                           milliseconds=random.randint(0, 999))
    return t


def pick_event():
    r = random.random()
    if r < 0.30:
        return 0
    if r < 0.60:
        return 1
    if r < 0.95:
        return 2
    return 3


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows-per-day", type=int, default=500_000)
    args = ap.parse_args()

    conn = pymysql.connect(host="127.0.0.1", port=13307, user="root",
                           password="lab", database="spoon", autocommit=False)
    cur = conn.cursor()
    t0 = time.time()
    total = 0
    for d in range(DAYS):
        day = BASE + dt.timedelta(days=d)
        rows = []
        for _ in range(args.rows_per_day):
            rows.append((pick_live(), random.randint(1, 500_000), pick_event(),
                         pick_time(day).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]))
        # 두 테이블에 같은 데이터를 넣는다. 그래야 삭제 비교가 공정하다.
        for table in ("watch_log_plain", "watch_log_part"):
            for i in range(0, len(rows), BATCH):
                cur.executemany(
                    f"INSERT INTO {table} (live_id, user_id, event_type, created_at) "
                    "VALUES (%s, %s, %s, %s)", rows[i:i + BATCH])
            conn.commit()
        total += len(rows)
        print(f"{day} 적재 완료 (누적 {total:,}행 x 2테이블, {time.time() - t0:.0f}초)", flush=True)

    cur.execute("SELECT DATE(created_at), COUNT(*) FROM watch_log_plain GROUP BY 1 ORDER BY 1")
    print("\n일별 건수 (watch_log_plain)")
    for day, cnt in cur.fetchall():
        print(f"  {day}  {cnt:,}")
    conn.close()


if __name__ == "__main__":
    main()
