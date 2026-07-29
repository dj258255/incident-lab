#!/usr/bin/env python3
"""주문 300만 건을 적재한다.

분포를 실제 주문 데이터에 맞춘다. 균등 분포로 만들면 어떤 쿼리를 써도 비슷하게 나와서
"인덱스를 못 타면 얼마나 손해인가"가 드러나지 않는다.
  - order_no: 'ORD' + 12자리 숫자. 유니크에 가깝다(형변환 함정의 무대)
  - user_id: Zipf 쏠림. 헤비 유저 소수가 주문의 상당수를 차지한다
  - status_flag: 비트 플래그. 0x0100(선물 주문)이 약 3%, 0x0001(공개)이 약 60%
  - buyer_name: 성씨 분포를 반영해 선행 와일드카드 LIKE의 무대를 만든다
"""
import random
import time

import pymysql

random.seed(20260729)
ROWS = 3_000_000
BATCH = 5000
LIVE_USERS = 200_000
ZIPF_S = 1.1

# Zipf 누적분포
w = [1 / (i + 1) ** ZIPF_S for i in range(LIVE_USERS)]
tot = sum(w)
cdf = []
acc = 0.0
for x in w:
    acc += x / tot
    cdf.append(acc)


def pick_user():
    r = random.random()
    lo, hi = 0, LIVE_USERS - 1
    while lo < hi:
        mid = (lo + hi) // 2
        if cdf[mid] < r:
            lo = mid + 1
        else:
            hi = mid
    return lo + 1


SURNAMES = ["김", "이", "박", "최", "정", "강", "조", "윤", "장", "임"]
GIVEN = ["민준", "서연", "도윤", "지우", "예준", "하은", "시우", "지호", "수아", "건우"]


def pick_flag():
    f = 0
    if random.random() < 0.60:
        f |= 0x0001            # 공개
    if random.random() < 0.03:
        f |= 0x0100            # 선물 주문 (희소 조건. 인덱스가 필요한 자리)
    if random.random() < 0.20:
        f |= 0x0010            # 쿠폰 사용
    return f


conn = pymysql.connect(host="127.0.0.1", port=13313, user="root",
                       password="lab", database="spoon", autocommit=False)
cur = conn.cursor()
t0 = time.time()

base = int(time.mktime((2026, 1, 1, 0, 0, 0, 0, 0, 0)))
for i in range(0, ROWS, BATCH):
    rows = []
    for j in range(i, min(i + BATCH, ROWS)):
        rows.append((
            f"ORD{j + 1:012d}",
            pick_user(),
            pick_flag(),
            random.choice([1000, 3000, 5000, 9900, 15000, 29000, 50000]),
            random.choice(SURNAMES) + random.choice(GIVEN),
            time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(base + j // 10)),
        ))
    cur.executemany(
        "INSERT INTO orders (order_no, user_id, status_flag, amount, buyer_name, created_at) "
        "VALUES (%s,%s,%s,%s,%s,%s)", rows)
    if (i // BATCH) % 60 == 0:
        conn.commit()
        print(f"  {i:,}/{ROWS:,} ({time.time() - t0:.0f}초)", flush=True)
conn.commit()

# 레거시 조인 테이블. 주문의 10%만 메모가 있다고 가정한다.
print("레거시 테이블 적재")
for tbl in ("order_legacy", "order_legacy_fixed"):
    cur.execute(f"INSERT INTO {tbl} (order_no, memo) "
                f"SELECT order_no, CONCAT('memo-', id) FROM orders WHERE id % 10 = 0")
    conn.commit()

cur.execute("ANALYZE TABLE orders, order_legacy, order_legacy_fixed")
cur.execute("""SELECT TABLE_NAME, TABLE_ROWS,
                      ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024) mb
               FROM information_schema.TABLES WHERE TABLE_SCHEMA='spoon' ORDER BY TABLE_NAME""")
for name, rows_, mb in cur.fetchall():
    print(f"{name}: {rows_:,}행 추정, {mb}MB")

# 분포 감사. 의도대로 들어갔는지 원장에서 직접 센다.
cur.execute("SELECT COUNT(*), COUNT(DISTINCT user_id), COUNT(DISTINCT buyer_name) FROM orders")
print("총 {:,}건 / 유저 {:,} / 이름 {:,}종".format(*cur.fetchone()))
cur.execute("SELECT SUM(status_flag & 0x0100 > 0), SUM(status_flag & 0x0001 > 0) FROM orders")
gift, public = cur.fetchone()
print(f"선물 주문 {gift:,}건 ({gift / ROWS:.1%}), 공개 {public:,}건 ({public / ROWS:.1%})")
cur.execute("SELECT COUNT(*) FROM orders WHERE user_id = 1")
print(f"1위 유저 주문 {cur.fetchone()[0]:,}건")
conn.close()
print(f"완료 ({time.time() - t0:.0f}초)")
