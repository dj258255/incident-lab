#!/usr/bin/env python3
"""Performance Insights의 핵심 루프를 그대로 구현한 샘플러.

AWS 문서가 서술하는 PI의 동작은 "매초, 쿼리를 실행 중인 세션 수를 샘플링하고
그 세션들이 무엇을 기다리는지(wait event)로 쪼갠다"이다. 그 luop이 이 파일이다.

매초 performance_schema.threads에서 활성 포그라운드 세션을 세고,
events_waits_current의 현재 대기 이벤트로 분류한다.
대기 이벤트가 없는 활성 세션은 CPU로 분류한다(PI와 같은 해석).

  사용법: sampler.py <지속초> <출력.csv> [간격초=1.0]
"""
import csv
import sys
import time

import pymysql

DURATION = int(sys.argv[1])
OUT = sys.argv[2]
INTERVAL = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0

# PI가 쓰는 것과 같은 방식의 대분류. 이벤트 이름 접두어로 나눈다.
def classify(event):
    if event is None:
        return "cpu"
    if event.startswith("wait/io/file"):
        return "io_file"
    if event.startswith("wait/io/table"):
        return "io_table"
    if event.startswith("wait/lock"):
        return "lock"
    if event.startswith("wait/synch"):
        return "synch"
    if event.startswith("idle"):
        return "idle"
    return "other"


Q = """
SELECT t.PROCESSLIST_ID, t.PROCESSLIST_COMMAND, w.EVENT_NAME
FROM performance_schema.threads t
LEFT JOIN performance_schema.events_waits_current w
       ON w.THREAD_ID = t.THREAD_ID AND w.END_EVENT_ID IS NULL
WHERE t.TYPE = 'FOREGROUND'
  AND t.PROCESSLIST_ID IS NOT NULL
  AND t.PROCESSLIST_COMMAND NOT IN ('Sleep', 'Daemon')
"""

conn = pymysql.connect(host="127.0.0.1", port=13312, user="root",
                       password="lab", database="performance_schema", autocommit=True)
cur = conn.cursor()
me = conn.thread_id()

cats = ["cpu", "io_file", "io_table", "lock", "synch", "other"]
with open(OUT, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["ts", "active_sessions"] + cats)
    end = time.time() + DURATION
    while time.time() < end:
        t0 = time.time()
        cur.execute(Q)
        rows = [r for r in cur.fetchall() if r[0] != me]   # 샘플러 자신은 뺀다
        # 한 세션에 대기 이벤트가 여러 줄일 수 있어 세션당 하나로 접는다
        by_session = {}
        for pid, cmd, ev in rows:
            cat = classify(ev)
            prev = by_session.get(pid)
            # 대기 이벤트가 있는 줄을 우선한다. 없으면 cpu로 남는다
            if prev is None or (prev == "cpu" and cat != "cpu"):
                by_session[pid] = cat
        counts = {c: 0 for c in cats}
        for cat in by_session.values():
            if cat in counts:
                counts[cat] += 1
        w.writerow([f"{time.time():.2f}", len(by_session)] + [counts[c] for c in cats])
        f.flush()
        time.sleep(max(0.0, INTERVAL - (time.time() - t0)))
conn.close()
print(f"샘플링 종료 → {OUT}")
