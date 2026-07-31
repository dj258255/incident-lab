#!/usr/bin/env bash
# README 의 "못 한 것" 세 개를 잡는다.
#
#   1) batch_size 를 바꿔 가며 재지 않았습니다
#      7절은 500 하나만 썼다. 배치 크기가 커지면 왕복이 줄지만 한 번에 보내는 패킷이
#      커진다. 어디서 이득이 멈추는지 잰다.
#
#   2) 7절은 빈 테이블에서만 쟀습니다
#      200만 행이 든 테이블에 넣을 때 같은 비율이 나오는지 안 쟀다.
#      인덱스가 이미 크면 삽입마다 B-Tree 를 더 깊이 타므로 비율이 달라질 수 있다.
#
#   3) MySQL 쪽 타이브레이커 조건을 만들지 않았습니다
#      6절에서 같은 시각이 200행씩 몰리는 테이블로 PostgreSQL 쪽만 확인했다.
#      MySQL 의 seed.py 는 created_at 이 전부 다른 데이터를 만든다.
#      같은 시각이 겹치는 데이터를 만들어 커서 페이지네이션이 행을 건너뛰는지 본다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
JAVA_BIN="${JAVA_BIN:-/opt/homebrew/Cellar/openjdk@21/21.0.9/libexec/openjdk.jdk/Contents/Home/bin/java}"
N="${N:-20000}"
PRELOAD="${PRELOAD:-2000000}"
M(){ docker exec b52-mysql mysql -uroot -plab spoon -N -B -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }

for _ in $(seq 1 90); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(M 'SELECT 1')" = "1" ] || { echo "중단: b52-mysql 이 쿼리를 받지 못합니다" >&2; exit 2; }
M "INSERT IGNORE INTO live (id, title, streamer_id, created_at) VALUES (1,'bench',1,NOW(3))" >/dev/null

start_app() { # $1=BATCH_SIZE $2=REWRITE
  pkill -f 'list-api.jar' 2>/dev/null || true
  sleep 1
  BATCH_SIZE="$1" REWRITE="$2" "$JAVA_BIN" -Xms1g -Xmx1g \
    -jar "$ROOT/app/build/libs/list-api.jar" > "$OUT/insert-extra-app.log" 2>&1 &
  for _ in $(seq 1 90); do
    curl -sf -X POST "http://127.0.0.1:8080/insert?mode=jdbcBatchAssigned&liveId=1&n=1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "  앱이 뜨지 않았습니다"; tail -8 "$OUT/insert-extra-app.log" | sed 's/^/    /'
  return 1
}

run() { # $1=라벨 $2=mode $3=테이블 $4=batch $5=rewrite $6=truncate(yes/no)
  local label="$1" mode="$2" tbl="$3"
  [ "${6:-yes}" = "yes" ] && M "TRUNCATE TABLE $tbl" >/dev/null
  local q0 q1 t0 t1 rows0 rows1
  rows0=$(M "SELECT COUNT(*) FROM $tbl")
  q0=$(M "SHOW GLOBAL STATUS LIKE 'Questions'" | awk '{print $2}')
  t0=$(date +%s%N)
  curl -sf -X POST "http://127.0.0.1:8080/insert?mode=${mode}&liveId=1&n=${N}" >/dev/null 2>&1
  t1=$(date +%s%N)
  q1=$(M "SHOW GLOBAL STATUS LIKE 'Questions'" | awk '{print $2}')
  rows1=$(M "SELECT COUNT(*) FROM $tbl")
  local sec; sec=$(python3 -c "print(f'{($t1-$t0)/1e9:.2f}')")
  printf "  %-38s %8s초  쿼리 %7d개  넣은 행 %s\n" \
    "$label" "$sec" "$((q1 - q0))" "$((rows1 - rows0))"
  echo "$label,$sec,$((q1 - q0)),$((rows1 - rows0)),$4,$5,${6:-yes}" >> "$OUT/insert-extra.csv"
}

{
echo "# batch_size 스윕, 큰 테이블에 삽입, MySQL 타이브레이커"
echo "# MySQL $(M 'SELECT VERSION()'), 삽입 ${N}행"
echo "# 각 조건 1회 실행입니다."
: > "$OUT/insert-extra.csv"
echo "label,seconds,queries,rows,batch_size,rewrite,truncated" >> "$OUT/insert-extra.csv"
echo

# ── 1) batch_size 스윕 ──────────────────────────────────────────────────
echo "=================================================================="
echo "## 1) batch_size 를 바꿔 가며"
echo "=================================================================="
for bs in 1 10 50 100 500 1000 5000; do
  start_app "$bs" true || continue
  run "saveAll 직접 ID batch=${bs}" saveAllAssigned sponsor_assigned "$bs" true
done
echo
python3 - "$OUT/insert-extra.csv" <<'PY'
import csv, sys
rows = [r for r in csv.DictReader(open(sys.argv[1])) if r['label'].startswith('saveAll 직접 ID batch=')]
if rows:
    base = None
    print(f"  {'batch_size':>11} {'소요':>9} {'쿼리':>9} {'행당 쿼리':>11} {'가장 빠른 것 대비':>16}")
    best = min(float(r['seconds']) for r in rows)
    for r in rows:
        bs = r['batch_size']; sec = float(r['seconds']); q = int(r['queries']); n = max(1, int(r['rows']))
        print(f"  {bs:>11} {sec:>8.2f}초 {q:>9,} {q/n:>11.3f} {sec/best:>15.2f}배")
    print()
    print("  왕복이 줄어드는 것은 행당 쿼리 수로 보입니다. 배치가 커져도 그 값이 더 안")
    print("  내려가면 이득이 멈춘 것이고, 그 뒤로는 패킷만 커집니다.")
PY
echo

# ── 2) 큰 테이블에 삽입 ─────────────────────────────────────────────────
echo "=================================================================="
echo "## 2) 이미 큰 테이블에 넣으면"
echo "=================================================================="
echo "  빈 테이블과 ${PRELOAD}행이 든 테이블에 같은 ${N}행을 넣습니다."
start_app 500 true || exit 3
run "빈 테이블" saveAllAssigned sponsor_assigned 500 true yes

echo "  ${PRELOAD}행 미리 적재 중..."
M "TRUNCATE TABLE sponsor_assigned" >/dev/null
M "INSERT INTO sponsor_assigned (id, live_id, user_id, amount, created_at)
   SELECT n, 1, n % 1000, 1000, NOW(3) FROM (
     SELECT @r := @r + 1 AS n FROM information_schema.COLUMNS c1,
       information_schema.COLUMNS c2, (SELECT @r := 0) r LIMIT $PRELOAD
   ) t" >/dev/null 2>&1
PRE=$(M "SELECT COUNT(*) FROM sponsor_assigned")
echo "  적재 완료: ${PRE}행"
SZ=$(M "SELECT ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024) FROM information_schema.TABLES
        WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='sponsor_assigned'")
echo "  테이블 크기 = ${SZ}MB"
run "${PRE}행이 든 테이블" saveAllAssigned sponsor_assigned 500 true no
echo
echo "  두 값의 비율이 1에 가까우면 삽입 비용이 테이블 크기에 둔감한 것입니다."
echo "  클러스터드 인덱스가 id 순으로 이어 붙는 조건이라 그럴 수 있습니다."
echo "  비율이 크면 B-Tree 가 깊어진 몫입니다."
echo

# ── 3) MySQL 타이브레이커 ───────────────────────────────────────────────
echo "=================================================================="
echo "## 3) created_at 이 겹치는 데이터에서 커서 페이지네이션"
echo "=================================================================="
echo "  6절은 PostgreSQL 에서만 밟았습니다. MySQL 쪽 데이터를 같은 모양으로 만듭니다."
M "DROP TABLE IF EXISTS tie_test" >/dev/null
M "CREATE TABLE tie_test (
     id BIGINT AUTO_INCREMENT PRIMARY KEY,
     created_at DATETIME(3) NOT NULL,
     KEY idx_created (created_at)
   )" >/dev/null
# 같은 시각에 200행씩 몰리게 만든다. 커서가 created_at 하나만 보면 여기서 건너뛴다.
M "INSERT INTO tie_test (created_at)
   SELECT DATE_ADD('2026-01-01 00:00:00.000', INTERVAL FLOOR((n-1)/200) SECOND)
   FROM (SELECT @r := @r + 1 AS n FROM information_schema.COLUMNS c1,
         information_schema.COLUMNS c2, (SELECT @r := 0) r LIMIT 2000) t" >/dev/null 2>&1
TOTAL=$(M "SELECT COUNT(*) FROM tie_test")
DISTINCT=$(M "SELECT COUNT(DISTINCT created_at) FROM tie_test")
echo "  총 ${TOTAL}행, 서로 다른 시각 ${DISTINCT}개 (한 시각에 $((TOTAL / DISTINCT))행)"
echo

for mode in "created_at 만" "created_at 과 id"; do
  cursor_ts="2026-01-01 00:00:00.000"; cursor_id=0
  seen=0; page=0
  while [ "$page" -lt 40 ]; do
    if [ "$mode" = "created_at 만" ]; then
      rows=$(M "SELECT id, created_at FROM tie_test
                WHERE created_at > '$cursor_ts'
                ORDER BY created_at LIMIT 100")
    else
      rows=$(M "SELECT id, created_at FROM tie_test
                WHERE (created_at, id) > ('$cursor_ts', $cursor_id)
                ORDER BY created_at, id LIMIT 100")
    fi
    n=$(echo "$rows" | grep -c . || true)
    [ "$n" -eq 0 ] && break
    seen=$((seen + n))
    cursor_ts=$(echo "$rows" | tail -1 | awk -F'\t' '{print $2}')
    cursor_id=$(echo "$rows" | tail -1 | awk -F'\t' '{print $1}')
    page=$((page + 1))
  done
  printf "  %-16s 페이지 %2d회에 %5d행 읽음 (전체 %s행)  %s\n" \
    "$mode" "$page" "$seen" "$TOTAL" \
    "$([ "$seen" -lt "$TOTAL" ] && echo "**$((TOTAL - seen))행을 건너뛰었습니다**" || echo "전부 읽었습니다")"
done
echo
echo "  created_at 만 커서로 쓰면 같은 시각의 나머지 행을 건너뜁니다."
echo "  100행씩 끊는데 한 시각에 $((TOTAL / DISTINCT))행이 있으므로, 페이지 경계가 그 안에 떨어지면"
echo "  다음 질의의 > 조건이 남은 행을 통째로 넘깁니다. 타이브레이커로 id 를 더하면"
echo "  같은 시각 안에서도 순서가 정해져 경계가 안전해집니다."
pkill -f 'list-api.jar' 2>/dev/null || true

# ── 4) 무작위 id 로 넣으면 ──────────────────────────────────────────────
# 2절은 큰 테이블도 같은 비용이라고 봤는데 그때 id 가 순증했다. 순증이면 새 행이 항상
# 오른쪽 끝 페이지에 붙어 기존 페이지를 안 건드린다. 무작위면 아무 페이지나 열게 되고
# 페이지 분할이 난다. 이건 JPA 가 아니라 DB 쪽 이야기라 SQL 로 직접 잰다.
echo "=================================================================="
echo "## 4) 같은 큰 테이블에 순증 id 와 무작위 id"
echo "=================================================================="
echo "  ${PRELOAD}행이 든 표에 ${N}행을 넣습니다. id 만 다릅니다."
echo

RAND_MAX=$(( PRELOAD * 100 ))
for kind in seq rand; do
  M "DROP TABLE IF EXISTS ins_probe" >/dev/null
  M "CREATE TABLE ins_probe (
       id BIGINT PRIMARY KEY, live_id BIGINT NOT NULL, user_id BIGINT NOT NULL,
       amount INT NOT NULL, created_at DATETIME(3) NOT NULL,
       KEY idx_live (live_id, created_at)
     ) ENGINE=InnoDB" >/dev/null
  M "INSERT INTO ins_probe SELECT n, 1, n % 1000, 1000, NOW(3) FROM (
       SELECT @r := @r + 1 AS n FROM information_schema.COLUMNS c1,
         information_schema.COLUMNS c2, (SELECT @r := 0) r LIMIT ${PRELOAD}
     ) t" >/dev/null 2>&1
  PRE=$(M "SELECT COUNT(*) FROM ins_probe")
  case "${PRE:-0}" in ''|*[!0-9]*) PRE=0 ;; esac
  [ "$PRE" -gt 0 ] || { echo "  중단: ins_probe 적재 실패" >&2; break; }
  M "ANALYZE TABLE ins_probe" >/dev/null 2>&1
  SZ0=$(M "SELECT DATA_LENGTH+INDEX_LENGTH FROM information_schema.TABLES
           WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='ins_probe'")

  if [ "$kind" = "seq" ]; then
    EXPR="${PRELOAD} + n"
    LBL="순증 id"
  else
    # 이미 든 구간 밖의 무작위 값. 충돌을 피하려고 범위를 넓게 잡고 중복은 무시한다.
    EXPR="${PRELOAD} + 1 + FLOOR(RAND(42) * ${RAND_MAX})"
    LBL="무작위 id"
  fi
  T0=$(date +%s%N)
  M "INSERT IGNORE INTO ins_probe (id, live_id, user_id, amount, created_at)
     SELECT ${EXPR}, 1, n % 1000, 1000, NOW(3) FROM (
       SELECT @q := @q + 1 AS n FROM information_schema.COLUMNS c1,
         information_schema.COLUMNS c2, (SELECT @q := 0) q LIMIT ${N}
     ) t" >/dev/null 2>&1
  T1=$(date +%s%N)
  M "ANALYZE TABLE ins_probe" >/dev/null 2>&1
  SZ1=$(M "SELECT DATA_LENGTH+INDEX_LENGTH FROM information_schema.TABLES
           WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='ins_probe'")
  AFTER=$(M "SELECT COUNT(*) FROM ins_probe")
  ADDED=$(( ${AFTER:-0} - PRE ))
  printf "  %-12s %8s초  넣은 행 %8s  크기 %7.1fMB → %7.1fMB (증가 %6.1fMB, 행당 %5.0fB)\n" \
    "$LBL" "$(python3 -c "print(f'{($T1-$T0)/1e9:.2f}')")" "$ADDED" \
    "$(python3 -c "print(${SZ0:-0}/1048576)")" "$(python3 -c "print(${SZ1:-0}/1048576)")" \
    "$(python3 -c "print((${SZ1:-0}-${SZ0:-0})/1048576)")" \
    "$(python3 -c "print((${SZ1:-0}-${SZ0:-0})/max(1,${ADDED}))")"
done
echo
echo "  순증 id 는 새 행이 항상 오른쪽 끝 페이지에 붙습니다. 무작위 id 는 아무 페이지나"
echo "  열게 되어 페이지 분할이 납니다. 행당 바이트가 그 차이를 보입니다."
echo "  INSERT IGNORE 를 쓰므로 무작위 쪽은 충돌한 행이 빠집니다. 넣은 행 수를 함께 봅니다."
echo

} 2>&1 | tee "$OUT/exp-insert-extra.txt"
