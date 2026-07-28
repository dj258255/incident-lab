#!/usr/bin/env python3
"""후원을 한 건씩 커밋하고, 커밋이 성공한 건만 로그에 남긴다.

이 로그가 "고객에게 성공했다고 답한 후원"의 목록이다. 장애 후 승격된 레플리카와
이 로그를 대조하면, 성공 응답을 받았는데 사라진 후원이 몇 건인지 셀 수 있다.
RPO를 문장이 아니라 건수와 금액으로 만드는 장치다.

  사용법: writer.py <지속초> <출력.csv>
"""
import csv
import random
import sys
import time

import pymysql

DURATION = int(sys.argv[1])
OUT = sys.argv[2]

random.seed()
conn = pymysql.connect(host="127.0.0.1", port=13310, user="root",
                       password="lab", database="spoon", autocommit=False)
cur = conn.cursor()

rows = []
end = time.time() + DURATION
seq = 0
while time.time() < end:
    seq += 1
    amount = random.choice([1000, 3000, 5000, 10000, 30000])
    try:
        cur.execute("INSERT INTO sponsor (seq, user_id, amount) VALUES (%s, %s, %s)",
                    (seq, random.randint(1, 100_000), amount))
        conn.commit()
        # 커밋이 성공 반환한 뒤에만 기록한다. 이 줄이 있으면 "고객이 성공 화면을 봤다"는 뜻이다.
        rows.append((f"{time.time():.3f}", seq, amount))
    except pymysql.Error as e:
        rows.append((f"{time.time():.3f}", seq, f"FAILED:{e.args[0]}"))
        break   # 소스가 죽으면 여기서 끝난다
    time.sleep(0.02)

with open(OUT, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["ts", "seq", "amount"])
    w.writerows(rows)

ok = [r for r in rows if not str(r[2]).startswith("FAILED")]
print(f"커밋 성공 {len(ok)}건, 합계 {sum(int(r[2]) for r in ok):,}원, 마지막 seq {ok[-1][1] if ok else 0}")
