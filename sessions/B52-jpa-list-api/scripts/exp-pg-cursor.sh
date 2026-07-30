#!/usr/bin/env bash
# PostgreSQL 대조. 이 세션의 핵심 결론 하나를 다른 엔진에서 확인한다.
#
# MySQL 8.4.3 은 행값 비교 (created_at, id) > (?, ?) 에 범위 최적화를 걸지 않는다.
# 그래서 커서 페이지네이션의 표준 문법으로 널리 소개되는 이 문법이 전체 인덱스
# 스캔이 되고, 같은 조건을 OR 로 풀어써야 type=range 가 된다.
#
# PostgreSQL 은 행값 비교를 인덱스 조건으로 밀어 넣는 것으로 알려져 있다. 확인한다.
# 이것은 플래너 질문이라 애플리케이션 없이 SQL 로만 답할 수 있다.
#
# 타이브레이커도 함께 본다. MySQL 쪽 시드는 created_at 이 전부 달라
# `created_at = ? AND id > ?` 가지가 한 번도 참이 되지 않았다. 여기서는
# 같은 시각이 몰리는 테이블을 따로 만들어 그 가지를 실제로 밟는다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
Q(){ docker exec b52-pg psql -U postgres -d spoon -qAt -c "$1" 2>&1; }

for _ in $(seq 1 90); do [ "$(Q 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(Q 'SELECT 1')" = "1" ] || { echo "중단: b52-pg 가 쿼리를 받지 못합니다" >&2; exit 2; }

ROWS=${ROWS:-200000}

plan(){ docker exec b52-pg psql -U postgres -d spoon -qAt -c "EXPLAIN (ANALYZE, BUFFERS) $1" 2>&1; }
# 인덱스 조건으로 밀려 들어갔는지가 이 대조의 판정 기준이다.
# Index Cond 에 조건이 있으면 구간을 탄 것이고, Filter 에 있으면 훑고 버린 것이다.
judge(){ # $1=라벨 $2=SQL
  local o scan ms rows cond filt buf
  o=$(plan "$2")
  scan=$(echo "$o" | grep -oE "(Seq Scan|Index Scan|Index Only Scan|Bitmap Heap Scan|Incremental Sort|Sort)" | head -1)
  ms=$(echo "$o"   | grep -oE "Execution Time: [0-9.]+" | grep -oE "[0-9.]+")
  rows=$(echo "$o" | grep -oE "Rows Removed by Filter: [0-9]+" | grep -oE "[0-9]+" | head -1)
  cond=$(echo "$o" | grep -oE "Index Cond: \(.*" | head -1 | cut -c1-70)
  filt=$(echo "$o" | grep -oE "Filter: \(.*" | head -1 | cut -c1-70)
  buf=$(echo "$o"  | grep -oE "shared hit=[0-9]+( read=[0-9]+)?" | head -1)
  printf "  %-24s %-16s %9s ms  %s\n" "$1" "${scan:-?}" "${ms:-?}" "$buf"
  [ -n "$cond" ] && echo "      $cond"
  [ -n "$filt" ] && echo "      $filt"
  [ -n "$rows" ] && echo "      Rows Removed by Filter: $rows"
}

{
echo "# PostgreSQL 대조. $(Q 'SELECT version()' | cut -c1-45)"
echo "# live ${ROWS}행. MySQL 쪽과 같은 규모, 같은 인덱스 (created_at, id)"
echo

# ── 시드 ────────────────────────────────────────────────────────────────
Q "DROP TABLE IF EXISTS live, live_tie" >/dev/null
Q "CREATE TABLE live (id bigserial PRIMARY KEY, title varchar(200) NOT NULL,
     streamer_id bigint NOT NULL, created_at timestamp(3) NOT NULL)" >/dev/null
# MySQL 쪽 seed.py 와 같이 created_at 을 3초 간격으로 넣는다. 전부 다른 시각이다.
Q "INSERT INTO live (title, streamer_id, created_at)
   SELECT 'live ' || i, (i % 500) + 1,
          timestamp '2026-01-01 00:00:00' + ((i - 1) * interval '3 seconds')
     FROM generate_series(1,$ROWS) i" >/dev/null
Q "CREATE INDEX idx_created ON live (created_at, id)" >/dev/null
Q "VACUUM ANALYZE live" >/dev/null
echo "## 0) 시드"
echo "  live = $(Q 'SELECT count(*) FROM live')행, 서로 다른 created_at = $(Q 'SELECT count(DISTINCT created_at) FROM live')개"

# 깊은 페이지의 커서 값을 잡는다. MySQL 쪽과 같은 자리(19만 번째)로 둔다.
OFF=190000
CUR=$(Q "SELECT created_at || '|' || id FROM live ORDER BY created_at, id OFFSET $OFF LIMIT 1")
CTS=${CUR%%|*}; CID=${CUR##*|}
echo "  커서 = created_at '$CTS', id $CID (${OFF}번째)"
echo

echo "## 1) 깊은 페이지네이션 세 방식"
judge "OFFSET $OFF" \
  "SELECT id FROM live ORDER BY created_at, id LIMIT 20 OFFSET $OFF"
judge "커서: 행값 비교" \
  "SELECT id FROM live WHERE (created_at, id) > ('$CTS', $CID) ORDER BY created_at, id LIMIT 20"
judge "커서: 풀어쓴 조건" \
  "SELECT id FROM live WHERE created_at > '$CTS' OR (created_at = '$CTS' AND id > $CID) ORDER BY created_at, id LIMIT 20"
echo
echo "  MySQL 8.4.3 에서는 행값 비교가 type=index(전체 인덱스 스캔) 31ms 였고"
echo "  풀어쓴 조건만 type=range 3ms 였습니다. 10.3배 차이입니다."
echo

# ── 2) 타이브레이커 가지를 실제로 밟는다 ────────────────────────────────
echo "## 2) 같은 시각이 몰리는 데이터 (타이브레이커 가지)"
Q "CREATE TABLE live_tie (id bigserial PRIMARY KEY, title varchar(200) NOT NULL,
     streamer_id bigint NOT NULL, created_at timestamp(3) NOT NULL)" >/dev/null
# 시각을 1,000개로만 나눠 한 시각에 200행씩 몰리게 한다.
Q "INSERT INTO live_tie (title, streamer_id, created_at)
   SELECT 'live ' || i, (i % 500) + 1,
          timestamp '2026-01-01 00:00:00' + ((i % 1000) * interval '1 second')
     FROM generate_series(1,$ROWS) i" >/dev/null
Q "CREATE INDEX idx_created_tie ON live_tie (created_at, id)" >/dev/null
Q "VACUUM ANALYZE live_tie" >/dev/null
echo "  live_tie = $(Q 'SELECT count(*) FROM live_tie')행, 서로 다른 created_at = $(Q 'SELECT count(DISTINCT created_at) FROM live_tie')개"
TCUR=$(Q "SELECT created_at || '|' || id FROM live_tie ORDER BY created_at, id OFFSET $OFF LIMIT 1")
TTS=${TCUR%%|*}; TID=${TCUR##*|}
echo "  커서 = created_at '$TTS', id $TID"
echo "  이 커서에서 created_at 이 같은 행 = $(Q "SELECT count(*) FROM live_tie WHERE created_at = '$TTS'")개"
judge "행값 비교" \
  "SELECT id FROM live_tie WHERE (created_at, id) > ('$TTS', $TID) ORDER BY created_at, id LIMIT 20"
judge "풀어쓴 조건" \
  "SELECT id FROM live_tie WHERE created_at > '$TTS' OR (created_at = '$TTS' AND id > $TID) ORDER BY created_at, id LIMIT 20"
echo
echo "  두 문법이 같은 결과를 주는지 검산합니다."
A=$(Q "SELECT string_agg(id::text, ',') FROM (SELECT id FROM live_tie WHERE (created_at, id) > ('$TTS', $TID) ORDER BY created_at, id LIMIT 20) t")
B=$(Q "SELECT string_agg(id::text, ',') FROM (SELECT id FROM live_tie WHERE created_at > '$TTS' OR (created_at = '$TTS' AND id > $TID) ORDER BY created_at, id LIMIT 20) t")
[ "$A" = "$B" ] && echo "  일치" || { echo "  불일치"; echo "    행값: $A"; echo "    풀어씀: $B"; }
echo

echo "## 정리"
echo "  판정 기준은 조건이 Index Cond 로 밀려 들어갔는지입니다."
echo "  Index Cond 면 인덱스 구간을 탄 것이고 Filter 면 훑고 버린 것입니다."
echo "  각 조건 1회 실행입니다."
} 2>&1 | tee "$OUT/exp-pg-cursor.txt"
