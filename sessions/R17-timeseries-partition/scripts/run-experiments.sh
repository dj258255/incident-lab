#!/usr/bin/env bash
# 본 실험 네 개를 순서대로 돌린다.
#   1. DELETE로 7일치 삭제       (OLTP 부하 + 히스토리 리스트 관측 병행)
#   2. DROP PARTITION으로 7일치 삭제 (같은 관측)
#   3. 열린 트랜잭션이 DROP PARTITION을 막아 세우는 장면
#   4. 파티션 프루닝이 깨지는 조건
#
# 1과 2는 서로 다른 테이블(watch_log_plain / watch_log_part)에 같은 데이터가 있어
# 같은 시작 조건에서 비교된다. 1을 먼저 돌리는 이유는, 2를 먼저 돌리면
# 퍼지 잔여 작업이 1의 측정 구간에 겹치기 때문이 아니라 그 반대가 성립하기 때문이다.
# DELETE의 퍼지 꼬리가 길어서 1 → 대기 → 2 순서로 두고 사이에 안정화 구간을 넣는다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/../../.venv/bin/python"
OUT="$ROOT/results"
mkdir -p "$OUT"

SQL() { docker exec r17-mysql mysql -uroot -plab spoon -e "$1" 2>/dev/null; }
SQLT() { docker exec r17-mysql mysql -uroot -plab spoon -t -e "$1" 2>/dev/null; }

stamp() { date '+%H:%M:%S'; }

echo "== 사전 상태 =="
SQLT "SELECT @@innodb_purge_threads AS purge_threads, @@version AS version;" | tee "$OUT/pre-state.txt"
SQLT "SELECT TABLE_NAME, TABLE_ROWS, ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024) AS mb
      FROM information_schema.TABLES WHERE TABLE_SCHEMA='spoon' ORDER BY TABLE_NAME;" | tee -a "$OUT/pre-state.txt"

echo
echo "== 실험 1: DELETE로 7일치 삭제 ($(stamp)) =="
# 관측을 먼저 켠다. 삭제 전 안정 상태 10초가 기준선이 된다.
"$PY" "$ROOT/scripts/poll.py" 480 "$OUT/delete-poll.csv" &
POLL=$!
"$PY" "$ROOT/scripts/oltp.py" watch_log_plain 480 "$OUT/delete-oltp.csv" &
OLTP=$!
sleep 10

D0=$(date +%s.%N)
SQL "DELETE FROM watch_log_plain WHERE created_at < '2026-07-21';"
D1=$(date +%s.%N)
echo "DELETE 소요: $(echo "$D1 - $D0" | bc)초" | tee "$OUT/delete-elapsed.txt"
date +%s.%N > "$OUT/delete-done-ts.txt"
echo "$D0" > "$OUT/delete-start-ts.txt"

# 문장이 끝나도 퍼지가 남는다. 관측을 계속 붙잡아 둔다.
wait $OLTP $POLL
echo "삭제 후 행 수:" | tee -a "$OUT/delete-elapsed.txt"
SQLT "SELECT COUNT(*) AS remaining FROM watch_log_plain;" | tee -a "$OUT/delete-elapsed.txt"

echo
echo "== 안정화 대기 (퍼지 소진 확인) =="
for i in $(seq 1 60); do
  HLL=$(SQL "SELECT count FROM information_schema.INNODB_METRICS WHERE name='trx_rseg_history_len';" | tail -1)
  [ "$HLL" -lt 1000 ] && break
  sleep 5
done
echo "히스토리 리스트 길이: $HLL"

echo
echo "== 실험 2: DROP PARTITION으로 7일치 삭제 ($(stamp)) =="
"$PY" "$ROOT/scripts/poll.py" 120 "$OUT/drop-poll.csv" &
POLL=$!
"$PY" "$ROOT/scripts/oltp.py" watch_log_part 120 "$OUT/drop-oltp.csv" &
OLTP=$!
sleep 10

P0=$(date +%s.%N)
SQL "ALTER TABLE watch_log_part
     DROP PARTITION p20260714, p20260715, p20260716, p20260717, p20260718, p20260719, p20260720
     ;" 2>&1 | tee "$OUT/drop-output.txt"
P1=$(date +%s.%N)
echo "DROP PARTITION 소요: $(echo "$P1 - $P0" | bc)초" | tee "$OUT/drop-elapsed.txt"
echo "$P0" > "$OUT/drop-start-ts.txt"
date +%s.%N > "$OUT/drop-done-ts.txt"

wait $OLTP $POLL
SQLT "SELECT COUNT(*) AS remaining FROM watch_log_part;" | tee -a "$OUT/drop-elapsed.txt"

echo
echo "== 사후 파일 크기 =="
docker exec r17-mysql bash -c \
  "ls -l /var/lib/mysql/spoon/*.ibd | awk '{printf \"%-50s %12d\n\", \$NF, \$5}'" | tee "$OUT/post-ibd.txt"

echo
echo "== 실험 3: 열린 트랜잭션이 DROP PARTITION을 막는 장면 ($(stamp)) =="
# 세션 A: 트랜잭션을 열고 SELECT만 한 채 커밋하지 않는다 (25초 유지)
docker exec r17-mysql mysql -uroot -plab spoon -e \
  "START TRANSACTION; SELECT COUNT(*) FROM watch_log_part; DO SLEEP(25); COMMIT;" 2>/dev/null &
HOLDER=$!
sleep 2

# 세션 B: LOCK=NONE을 명시해도 MDL 대기에 걸린다
( T0=$(date +%s.%N)
  SQL "ALTER TABLE watch_log_part DROP PARTITION p20260721;"
  T1=$(date +%s.%N)
  echo "DROP PARTITION (열린 트랜잭션 뒤): $(echo "$T1 - $T0" | bc)초 대기" > "$OUT/mdl-drop-elapsed.txt"
) &
DROPPER=$!
sleep 3

# 세션 C: 평범한 SELECT까지 대기 행렬에 갇힌다
( T0=$(date +%s.%N)
  SQL "SELECT COUNT(*) FROM watch_log_part WHERE created_at >= '2026-07-27';"
  T1=$(date +%s.%N)
  echo "일반 SELECT (DDL 뒤): $(echo "$T1 - $T0" | bc)초 대기" > "$OUT/mdl-select-elapsed.txt"
) &
SELECTOR=$!
sleep 3

# 그 순간의 대기 행렬을 증거로 남긴다
SQLT "SELECT OBJECT_NAME, LOCK_TYPE, LOCK_STATUS,
             LEFT(COALESCE(pt.INFO,''),60) AS query
      FROM performance_schema.metadata_locks ml
      LEFT JOIN performance_schema.threads th ON ml.OWNER_THREAD_ID = th.THREAD_ID
      LEFT JOIN information_schema.PROCESSLIST pt ON th.PROCESSLIST_ID = pt.ID
      WHERE ml.OBJECT_SCHEMA='spoon'
      ORDER BY ml.LOCK_STATUS;" > "$OUT/mdl-locks.txt"
SQLT "SELECT ID, STATE, LEFT(INFO,70) AS query FROM information_schema.PROCESSLIST
      WHERE INFO IS NOT NULL;" >> "$OUT/mdl-locks.txt"
cat "$OUT/mdl-locks.txt"

wait $HOLDER $DROPPER $SELECTOR
cat "$OUT/mdl-drop-elapsed.txt" "$OUT/mdl-select-elapsed.txt"

echo
echo "== 실험 4: 파티션 프루닝 ($(stamp)) =="
{
  echo '$ EXPLAIN SELECT COUNT(*) FROM watch_log_part WHERE created_at >= "2026-07-27" (범위 조건)'
  SQLT "EXPLAIN SELECT COUNT(*) FROM watch_log_part WHERE created_at >= '2026-07-27';"
  echo
  echo '$ EXPLAIN ... WHERE DATE(created_at) = "2026-07-27" (함수로 감싼 조건)'
  SQLT "EXPLAIN SELECT COUNT(*) FROM watch_log_part WHERE DATE(created_at) = '2026-07-27';"
} > "$OUT/pruning-explain.txt"
cat "$OUT/pruning-explain.txt"

echo
echo "== 실험 5: ERROR 1491 원문 =="
SQL "CREATE TABLE bad_part (
       id BIGINT AUTO_INCREMENT PRIMARY KEY,
       created_at DATETIME NOT NULL
     ) PARTITION BY RANGE (TO_DAYS(created_at)) (
       PARTITION p0 VALUES LESS THAN MAXVALUE);" 2>&1 | tee "$OUT/error-1491.txt" || true

echo
echo "실험 종료 ($(stamp))"
