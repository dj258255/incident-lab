#!/usr/bin/env python3
"""활성 세션을 SQL 차원으로 분해한다. 그리고 미분류 이벤트의 이름을 남긴다.

README 의 "못 한 것" 두 항목을 처리한다.
  - SQL 차원 분해(top SQL)를 구현하지 않았습니다
  - 미분류 이벤트의 정체를 모릅니다 (샘플러가 이벤트 이름을 안 남겼기 때문)

Performance Insights 의 화면이 "무엇이 DB 를 붙잡고 있는가"를 대기 이벤트로 나누고
그 옆에 "어느 SQL 이 그러고 있는가"를 함께 보여 준다. 원 샘플러는 앞쪽만 했다.

SQL 차원은 events_statements_current 를 조인해 얻는다. DIGEST_TEXT 가 파라미터를
지운 형태라 같은 모양의 질의가 한 줄로 묶인다.

미분류('other')는 이벤트 이름을 그대로 적는다. 원 샘플러가 분류만 하고 이름을 버려
21% 가 무엇이었는지 알 수 없었다. 이름을 남기면 다음에 분류를 늘릴 수 있다.
"""
import collections
import csv
import json
import os
import sys
import time

import pymysql

DURATION = int(sys.argv[1]) if len(sys.argv) > 1 else 60
OUT = sys.argv[2] if len(sys.argv) > 2 else "/results/sampler-sql.csv"
OUT_JSON = os.path.splitext(OUT)[0] + ".json"


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


# 원 샘플러의 질의에 events_statements_current 를 더 붙인다.
# DIGEST_TEXT 는 파라미터를 ? 로 지운 형태라 같은 모양이 한 줄로 묶인다.
Q = """
SELECT t.PROCESSLIST_ID,
       t.PROCESSLIST_COMMAND,
       w.EVENT_NAME             AS wait_event,
       s.DIGEST                 AS digest,
       LEFT(s.DIGEST_TEXT, 90)  AS digest_text
FROM performance_schema.threads t
LEFT JOIN performance_schema.events_waits_current w
       ON w.THREAD_ID = t.THREAD_ID AND w.END_EVENT_ID IS NULL
LEFT JOIN performance_schema.events_statements_current s
       ON s.THREAD_ID = t.THREAD_ID AND s.END_EVENT_ID IS NULL
WHERE t.TYPE = 'FOREGROUND'
  AND t.PROCESSLIST_ID IS NOT NULL
  AND t.PROCESSLIST_COMMAND NOT IN ('Sleep', 'Daemon')
"""

conn = pymysql.connect(host="127.0.0.1", port=13312, user="root",
                       password="lab", database="performance_schema", autocommit=True)
cur = conn.cursor()
me = conn.thread_id()

cats = ["cpu", "io_file", "io_table", "lock", "synch", "other"]
# 누적 집계. 샘플 하나가 활성 세션 하나를 뜻하므로 그대로 더하면 AAS 의 분해가 된다.
sql_total = collections.Counter()          # digest_text → 샘플 수
sql_by_cat = collections.defaultdict(collections.Counter)   # digest_text → {cat: n}
other_events = collections.Counter()       # 미분류 이벤트 이름 → 샘플 수
samples = 0

with open(OUT, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["ts", "active_sessions"] + cats)
    end = time.time() + DURATION
    while time.time() < end:
        t0 = time.time()
        cur.execute(Q)
        rows = [r for r in cur.fetchall() if r[0] != me]
        by_session = {}
        for pid, cmd, ev, digest, dtext in rows:
            cat = classify(ev)
            prev = by_session.get(pid)
            if prev is None or (prev[0] == "cpu" and cat != "cpu"):
                by_session[pid] = (cat, dtext, ev)
        counts = {c: 0 for c in cats}
        for cat, dtext, ev in by_session.values():
            if cat in counts:
                counts[cat] += 1
            key = (dtext or "(질의 없음)").strip()
            sql_total[key] += 1
            sql_by_cat[key][cat] += 1
            if cat == "other" and ev:
                other_events[ev] += 1
        samples += 1
        w.writerow([f"{time.time():.2f}", len(by_session)] + [counts[c] for c in cats])
        time.sleep(max(0, 1.0 - (time.time() - t0)))

out = {
    "samples": samples,
    "duration_s": DURATION,
    # 활성 세션 샘플을 SQL 별로 나눈 것. Performance Insights 의 top SQL 과 같은 축이다.
    "top_sql": [
        {"digest_text": k, "samples": v,
         "aas": round(v / samples, 2) if samples else 0,
         "by_wait": dict(sql_by_cat[k])}
        for k, v in sql_total.most_common(10)
    ],
    # 미분류 이벤트의 실제 이름. 원 샘플러가 버리던 정보다.
    "other_events": [{"event": k, "samples": v} for k, v in other_events.most_common(15)],
}
with open(OUT_JSON, "w") as f:
    json.dump(out, f, ensure_ascii=False, indent=1)

print(f"샘플 {samples}회, {DURATION}초\n")
print("## top SQL (활성 세션 샘플 기준)")
print(f"  {'AAS':>6}  {'샘플':>6}  대기 분해                          질의")
for r in out["top_sql"]:
    waits = ", ".join(f"{k} {v}" for k, v in sorted(r["by_wait"].items(), key=lambda x: -x[1]))
    print(f"  {r['aas']:>6.2f}  {r['samples']:>6}  {waits:<34}  {r['digest_text'][:70]}")
print("\n## 미분류(other) 이벤트의 실제 이름")
if out["other_events"]:
    for r in out["other_events"]:
        print(f"  {r['samples']:>6}  {r['event']}")
else:
    print("  없음")
print(f"\n원문: {OUT_JSON}")
