#!/usr/bin/env python3
"""히스토리 리스트 길이와 파일 크기를 1초마다 기록한다.

대량 DELETE의 비용은 문장이 끝난 뒤에도 남는다. 지운 행은 퍼지 스레드가
언두 기록을 정리할 때까지 물리적으로 남아 있고, 그 밀린 양이 히스토리 리스트 길이다.
"쿼리는 끝났는데 부하는 안 끝나는 구간"을 이 시계열로 보인다.

  사용법: poll.py <지속초> <출력.csv>
"""
import csv
import subprocess
import sys
import time

import pymysql

DURATION = int(sys.argv[1])
OUT = sys.argv[2]


def ibd_bytes():
    """호스트에서 컨테이너 안 .ibd 크기를 합산한다."""
    r = subprocess.run(
        ["docker", "exec", "r17-mysql", "bash", "-c",
         "du -cb /var/lib/mysql/spoon/watch_log_plain*.ibd 2>/dev/null | tail -1 | cut -f1; "
         "du -cb /var/lib/mysql/spoon/watch_log_part*.ibd 2>/dev/null | tail -1 | cut -f1"],
        capture_output=True, text=True)
    vals = r.stdout.split()
    return (int(vals[0]) if len(vals) > 0 else 0,
            int(vals[1]) if len(vals) > 1 else 0)


conn = pymysql.connect(host="127.0.0.1", port=13307, user="root",
                       password="lab", database="spoon", autocommit=True)
cur = conn.cursor()

with open(OUT, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["ts", "history_list_len", "plain_ibd_bytes", "part_ibd_bytes"])
    end = time.time() + DURATION
    while time.time() < end:
        cur.execute("SELECT count FROM information_schema.INNODB_METRICS "
                    "WHERE name = 'trx_rseg_history_len'")
        hll = cur.fetchone()[0]
        plain, part = ibd_bytes()
        w.writerow([f"{time.time():.1f}", hll, plain, part])
        f.flush()
        time.sleep(1)
conn.close()
print(f"기록 완료 → {OUT}")
