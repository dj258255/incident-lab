#!/usr/bin/env bash
# 대량 삽입의 남은 세 항목을 한 번에 잰다.
#
#   1) 삽입 방식을 같은 테이블에서 비교      (원래는 sponsor 와 sponsor_assigned 로 갈렸다)
#   2) rewriteBatchedStatements 를 끈 JDBC batchUpdate
#   3) Persistable.isNew() 로 merge 를 피하는 변형
#
# 세 방식 모두 ID 를 직접 부여하고 빈 테이블에 넣는다. 그래야 소요 시간을 나란히 놓을 수
# 있다. 원래 측정은 batchUpdate 가 200만 행이 든 sponsor 에, saveAll 직접 ID 가 빈
# sponsor_assigned 에 넣어 출발선이 달랐다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
JAVA_BIN="${JAVA_BIN:-/opt/homebrew/Cellar/openjdk@21/21.0.9/libexec/openjdk.jdk/Contents/Home/bin/java}"
N="${N:-20000}"
M(){ docker exec b52-mysql mysql -uroot -plab spoon -N -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }

for _ in $(seq 1 90); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(M 'SELECT 1')" = "1" ] || { echo "중단: b52-mysql 이 쿼리를 받지 못합니다" >&2; exit 2; }

# live 한 행이 있어야 saveAll 이 getReference 로 참조할 수 있다.
M "INSERT IGNORE INTO live (id, title, streamer_id, created_at) VALUES (1,'bench',1,NOW(3))" >/dev/null

start_app() { # $1=BATCH_SIZE $2=REWRITE
  pkill -f 'list-api.jar' 2>/dev/null || true
  sleep 1
  BATCH_SIZE="$1" REWRITE="$2" "$JAVA_BIN" -Xms1g -Xmx1g \
    -jar "$ROOT/app/build/libs/list-api.jar" > "$OUT/insert-app.log" 2>&1 &
  APP_PID=$!
  # /insert 는 POST 다. GET 으로 찔러 준비 여부를 보면 405 만 받고 영원히 기다린다.
  for _ in $(seq 1 90); do
    curl -sf -X POST "http://127.0.0.1:8080/insert?mode=jdbcBatchAssigned&liveId=1&n=1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "  앱이 뜨지 않았습니다" >&2; return 1
}

run() { # $1=라벨 $2=mode $3=대상테이블 $4=BATCH_SIZE $5=REWRITE
  local label="$1" mode="$2" tbl="$3"
  M "TRUNCATE TABLE $tbl" >/dev/null
  # 이 조건에서 실제로 나간 쿼리 수를 센다. 시간만 보면 왕복이 줄었는지 알 수 없다.
  local q0 q1 t0 t1 rows
  q0=$(M "SHOW GLOBAL STATUS LIKE 'Questions'" | awk '{print $2}')
  t0=$(date +%s.%N)
  curl -sf -X POST "http://127.0.0.1:8080/insert?mode=${mode}&liveId=1&n=${N}" >/dev/null 2>&1
  t1=$(date +%s.%N)
  q1=$(M "SHOW GLOBAL STATUS LIKE 'Questions'" | awk '{print $2}')
  rows=$(M "SELECT COUNT(*) FROM $tbl")
  printf "  %-34s %8.2f초  쿼리 %6d개  적재 %s행\n" \
    "$label" "$(echo "$t1-$t0" | bc)" "$((q1 - q0))" "${rows:-?}"
  echo "$label,$(echo "$t1-$t0" | bc),$((q1 - q0)),${rows:-0},$4,$5" >> "$OUT/insert-summary.csv"
}

{
echo "# 대량 삽입: 같은 빈 테이블에서 ${N}행"
echo "# MySQL $(M 'SELECT VERSION()')"
echo
: > "$OUT/insert-summary.csv"
echo "label,seconds,queries,rows,batch_size,rewrite" >> "$OUT/insert-summary.csv"

echo "## A. batch_size=500, rewriteBatchedStatements=true"
start_app 500 true || exit 3
run "saveAll 자동 ID(IDENTITY)"      saveAll            sponsor             500 true
run "saveAll 직접 ID"                saveAllAssigned    sponsor_assigned    500 true
run "saveAll 직접 ID + Persistable"  saveAllPersistable sponsor_persistable 500 true
run "JDBC batchUpdate"               jdbcBatchAssigned  sponsor_assigned    500 true
echo

echo "## B. batch_size=500, rewriteBatchedStatements=false"
start_app 500 false || exit 3
run "saveAll 직접 ID"                saveAllAssigned    sponsor_assigned    500 false
run "saveAll 직접 ID + Persistable"  saveAllPersistable sponsor_persistable 500 false
run "JDBC batchUpdate"               jdbcBatchAssigned  sponsor_assigned    500 false
echo

echo "## 정리"
echo "  쿼리 수는 SHOW GLOBAL STATUS 의 Questions 차분입니다. 왕복이 줄었는지를 봅니다."
echo "  네 방식 모두 ID 를 직접 부여하는 조건(saveAll 자동 ID 제외)이고 빈 테이블에 넣습니다."
echo "  각 조건 1회 실행입니다."
pkill -f 'list-api.jar' 2>/dev/null || true
} 2>&1 | tee "$OUT/exp-insert.txt"
