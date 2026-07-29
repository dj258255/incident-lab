#!/usr/bin/env bash
# 세 함정을 각각 전후로 잰다.
#   1. N+1        : naive / graph(fetch join) / projection(집계)
#   2. 페이지네이션 : offset 깊이별 vs 커서
#   3. 대량 삽입   : saveAll(배치 0) / saveAll(배치 500) / JDBC batchUpdate
#
# 앱을 세 번 띄운다. hibernate.jdbc.batch_size는 기동 시 결정되는 값이라
# 한 프로세스에서 켜고 끌 수 없다. 같은 jar, 환경변수만 바꿔 조건을 만든다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JAVA_BIN="${JAVA_BIN:-/opt/homebrew/Cellar/openjdk@21/21.0.9/libexec/openjdk.jdk/Contents/Home/bin/java}"
OUT="$ROOT/results"
mkdir -p "$OUT"

start_app() {   # start_app <BATCH_SIZE> <REWRITE>
  pkill -f 'list-api.jar' 2>/dev/null || true
  sleep 1
  BATCH_SIZE="$1" REWRITE="$2" "$JAVA_BIN" -Xms1g -Xmx1g \
    -jar "$ROOT/app/build/libs/list-api.jar" > "$OUT/app-b$1-r$2.log" 2>&1 &
  for _ in $(seq 1 60); do
    curl -sf "http://127.0.0.1:8080/list?mode=projection&from=1&size=1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "앱 기동 실패" >&2
  return 1
}

# 워밍업 3회 후 5회 측정. 중앙값을 쓴다.
bench() {   # bench <라벨> <URL>
  local label="$1" url="$2"
  for _ in 1 2 3; do curl -s "$url" >/dev/null; done
  local body times=()
  for _ in $(seq 1 5); do
    body=$(curl -s "$url")
    times+=("$(echo "$body" | sed -n 's/.*"elapsed_ms":\([0-9]*\).*/\1/p')")
  done
  local med
  med=$(printf '%s\n' "${times[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
  local q
  q=$(echo "$body" | sed -n 's/.*"select_count":\([0-9-]*\).*/\1/p')
  echo "$label,$med,${q:-0}" >> "$OUT/bench.csv"
  printf "%-28s %8sms  쿼리 %s개\n" "$label" "$med" "${q:-0}"
}

echo "label,elapsed_ms,select_count" > "$OUT/bench.csv"

echo "== 1. N+1 (방송 20건 + 후원 합계, 구간 id 100000~100019) =="
start_app 0 true || exit 1
FROM=100000
bench "N+1 지연로딩" "http://127.0.0.1:8080/list?mode=naive&from=$FROM&size=20"
bench "fetch join(EntityGraph)" "http://127.0.0.1:8080/list?mode=graph&from=$FROM&size=20"
bench "집계 프로젝션" "http://127.0.0.1:8080/list?mode=projection&from=$FROM&size=20"

echo
echo "== 2. 페이지네이션 (방송 20만 건) =="
for off in 0 10000 100000 199980; do
  bench "OFFSET $off" "http://127.0.0.1:8080/page?mode=offset&offset=$off&size=20"
done
# 커서는 같은 위치의 앵커를 먼저 구해서 그 지점부터 읽는다.
# 행값 비교와 풀어쓴 형태를 둘 다 잰다. 표준 문법으로 알려진 쪽이 느린 것이 이 세션의 발견이다.
for off in 0 10000 100000 199980; do
  A=$(curl -s "http://127.0.0.1:8080/anchor?offset=$off")
  ID=$(echo "$A" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  TS=$(echo "$A" | sed -n 's/.*"created_at":"\([^"]*\)".*/\1/p')
  ENC=$(echo "$TS" | sed 's/ /%20/')
  bench "커서(행값) $off" "http://127.0.0.1:8080/page?mode=cursor-rowvalue&lastId=$ID&lastCreatedAt=$ENC&size=20"
  bench "커서(풀어씀) $off" "http://127.0.0.1:8080/page?mode=cursor-expanded&lastId=$ID&lastCreatedAt=$ENC&size=20"
done

echo
echo "== 3. 대량 삽입 1만 건 =="
insert() {  # insert <라벨> <mode>
  local label="$1" mode="$2"
  local ms
  ms=$(curl -s -X POST "http://127.0.0.1:8080/insert?mode=$mode&liveId=1&n=10000" \
       | sed -n 's/.*"elapsed_ms":\([0-9]*\).*/\1/p')
  echo "$label,$ms,0" >> "$OUT/bench.csv"
  printf "%-28s %8sms\n" "$label" "$ms"
}
insert "saveAll IDENTITY (배치 0)" saveAll
insert "JDBC batchUpdate" jdbc

start_app 500 true || exit 1
insert "saveAll IDENTITY (배치 500)" saveAll
insert "saveAll 직접ID (배치 500)" saveAllAssigned
insert "JDBC batchUpdate (배치 500)" jdbc

start_app 500 false || exit 1
insert "saveAll 직접ID (배치 500 · rewrite 끔)" saveAllAssigned

pkill -f 'list-api.jar' 2>/dev/null || true
echo
echo "결과: $OUT/bench.csv"
