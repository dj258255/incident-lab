#!/usr/bin/env bash
# R12 실험 전체.
#   0. 적재 (small 10만 행, hotrow 1행, big 400만 행 약 1.1GB > 버퍼 풀 256MB)
#   1. 함정: waits 소비자가 기본 비활성이라 샘플러가 대기를 못 본다
#   2. 계측과 소비자 활성화
#   3. 3구간 워크로드 + 1초 샘플러 (PI 방식) + 0.1초 샘플러 (대조)
#
# 1번 함정의 원인을 정확히 적어 둔다. 아래 SELECT의 실제 출력(results/01-default-instruments.txt)을
# 보면 조회한 계측 둘(wait/io/file/innodb/innodb_data_file, wait/lock/table/sql/handler)은
# ENABLED=YES였다. 꺼져 있던 것은 waits 소비자 셋이다. MySQL 문서 Pre-Filtering by Consumer가
# "이벤트가 어느 목적지에도 전달되지 않으면 Performance Schema는 그 이벤트를 만들지 않는다"고
# 적은 그대로다. 소비자가 NO면 events_waits_current가 비고, sampler.py의 LEFT JOIN이 NULL을
# 받고, NULL은 cpu로 분류된다. "계측이 기본 비활성"이라고 뭉뚱그리면 원인을 놓친다.
# 다만 wait/synch/% 와 wait/io/socket/% 처럼 계측 자체가 기본 OFF인 것도 있으므로 둘 다 켠다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/../../.venv/bin/python"
OUT="$ROOT/results"
mkdir -p "$OUT"
M() { docker exec r12-mysql mysql -uroot -plab -t -e "$1" 2>&1 | grep -v "Warning.*password"; }

echo "== 0. 적재 =="
M "CREATE TABLE IF NOT EXISTS spoon.small (id INT PRIMARY KEY, val INT);
   CREATE TABLE IF NOT EXISTS spoon.hotrow (id INT PRIMARY KEY, val BIGINT);
   CREATE TABLE IF NOT EXISTS spoon.big (id INT PRIMARY KEY, pad VARBINARY(255));
   INSERT IGNORE INTO spoon.hotrow VALUES (1, 0);"
"$PY" - <<'PYEOF'
import os, pymysql
conn = pymysql.connect(host="127.0.0.1", port=13312, user="root", password="lab",
                       database="spoon", autocommit=False)
cur = conn.cursor()
cur.execute("SELECT COUNT(*) FROM small"); n_small = cur.fetchone()[0]
if n_small < 100_000:
    for i in range(0, 100_000, 5000):
        cur.executemany("INSERT IGNORE INTO small VALUES (%s,%s)",
                        [(j+1, j) for j in range(i, i+5000)])
    conn.commit(); print("small 적재 완료")
cur.execute("SELECT COUNT(*) FROM big"); n_big = cur.fetchone()[0]
if n_big < 4_000_000:
    for i in range(n_big, 4_000_000, 5000):
        cur.executemany("INSERT IGNORE INTO big VALUES (%s,%s)",
                        [(j+1, os.urandom(255)) for j in range(i, i+5000)])
        if i % 500_000 == 0: conn.commit(); print(f"big {i:,}", flush=True)
    conn.commit(); print("big 적재 완료")
PYEOF

echo "== 1. 함정 재현: waits 소비자 기본 상태 =="
{
  echo '--- 8.4 기본값에서 wait/% 계측과 waits 소비자 상태'
  # 세 번째 이름(buf_pool_mutex)은 8.4에 그 계측이 없어 행이 나오지 않는다. 출력이 2행인 이유다.
  M "SELECT NAME, ENABLED FROM performance_schema.setup_instruments
     WHERE NAME IN ('wait/io/file/innodb/innodb_data_file','wait/lock/table/sql/handler',
                    'wait/synch/mutex/innodb/buf_pool_mutex');"
  M "SELECT NAME, ENABLED FROM performance_schema.setup_consumers WHERE NAME LIKE '%waits%';"
} | tee "$OUT/01-default-instruments.txt"

echo '--- 소비자를 켜기 전, 락이 걸린 상태에서 샘플러를 8초 돌려 본다'
docker exec r12-mysql mysql -uroot -plab spoon -e \
  "START TRANSACTION; UPDATE hotrow SET val=val+1 WHERE id=1; DO SLEEP(12); COMMIT;" 2>/dev/null &
HOLD=$!
sleep 1
docker exec r12-mysql mysql -uroot -plab spoon -e "UPDATE hotrow SET val=val+1 WHERE id=1;" 2>/dev/null &
BLOCKED=$!
"$PY" "$ROOT/scripts/sampler.py" 8 "$OUT/blind-sample.csv" 1.0
wait $HOLD $BLOCKED 2>/dev/null || true
tail -5 "$OUT/blind-sample.csv" | tee -a "$OUT/01-default-instruments.txt"

echo "== 2. 계측과 소비자 활성화 =="
M "UPDATE performance_schema.setup_instruments SET ENABLED='YES', TIMED='YES' WHERE NAME LIKE 'wait/%';
   UPDATE performance_schema.setup_consumers SET ENABLED='YES' WHERE NAME LIKE '%waits%';" \
  | tee "$OUT/02-enable.txt"

echo '--- 같은 락 상황을 다시 관측'
docker exec r12-mysql mysql -uroot -plab spoon -e \
  "START TRANSACTION; UPDATE hotrow SET val=val+1 WHERE id=1; DO SLEEP(12); COMMIT;" 2>/dev/null &
HOLD=$!
sleep 1
docker exec r12-mysql mysql -uroot -plab spoon -e "UPDATE hotrow SET val=val+1 WHERE id=1;" 2>/dev/null &
BLOCKED=$!
"$PY" "$ROOT/scripts/sampler.py" 8 "$OUT/sighted-sample.csv" 1.0
wait $HOLD $BLOCKED 2>/dev/null || true
tail -5 "$OUT/sighted-sample.csv" | tee -a "$OUT/02-enable.txt"

echo "== 3. 3구간 워크로드 + 샘플러 2개 =="
"$PY" "$ROOT/scripts/sampler.py" 185 "$OUT/pi-1s.csv" 1.0 &
S1=$!
"$PY" "$ROOT/scripts/sampler.py" 185 "$OUT/pi-100ms.csv" 0.1 &
S2=$!
sleep 2
"$PY" "$ROOT/scripts/workload.py" | tee "$OUT/03-workload.txt"
wait $S1 $S2
echo "실험 종료"
