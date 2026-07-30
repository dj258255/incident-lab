#!/usr/bin/env bash
# PostgreSQL 대조. MySQL 로만 잰 다섯 조건을 같은 데이터 규모로 다시 잰다.
#
# 다섯 조건이 PostgreSQL 에서 같은 모양으로 나타나지 않는다.
#   1) 암묵적 형변환    → 에러. 조용히 풀스캔하지 않는다
#   2) 문자셋 불일치 조인 → 콜레이션이 다르면 비교 자체가 거부되거나 명시를 요구한다
#   3) 함수 적용        → 표현식 인덱스로 직접 해소된다
#   4) 선행 와일드카드   → pg_trgm GIN 으로 직접 해소된다
#   5) 비트 연산        → 표현식 인덱스로 직접 해소된다
#
# 그래서 이 대조의 결론은 "PostgreSQL 이 빠르다"가 아니라
# "조용히 느려지는 자리가 어느 엔진에 몇 개 있는가"다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
Q(){  docker exec a22-pg psql -U postgres -d spoon -qAt -c "$1" 2>&1; }
QE(){ docker exec a22-pg psql -U postgres -d spoon -c "$1" 2>&1; }

for _ in $(seq 1 90); do [ "$(Q 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(Q 'SELECT 1')" = "1" ] || { echo "중단: a22-pg 가 쿼리를 받지 못합니다" >&2; exit 2; }

ROWS=${ROWS:-3000000}

# 계획과 실측을 한 번에. 스캔 방식과 시간만 뽑는다.
plan(){ # $1=SQL
  docker exec a22-pg psql -U postgres -d spoon -qAt \
    -c "EXPLAIN (ANALYZE, BUFFERS, TIMING ON) $1" 2>&1
}
scan_of(){ echo "$1" | grep -oE "(Seq Scan|Index Scan|Index Only Scan|Bitmap Heap Scan|Bitmap Index Scan|Parallel Seq Scan)" | head -1; }
ms_of(){   echo "$1" | grep -oE "Execution Time: [0-9.]+" | grep -oE "[0-9.]+"; }
# 최상위 Buffers 줄이 집계값이다. read= 가 없을 수 있으므로 선택적으로 둔다.
read_of(){ echo "$1" | grep -oE "shared hit=[0-9]+( read=[0-9]+)?" | head -1; }

report(){ # $1=라벨 $2=SQL
  local o s m
  o=$(plan "$2")
  if echo "$o" | grep -q "^ERROR:"; then
    echo "    $1: $(echo "$o" | grep -m1 '^ERROR:')"
    echo "$o" | grep -m1 "^HINT:" | sed 's/^/           /'
    return
  fi
  s=$(scan_of "$o"); m=$(ms_of "$o")
  printf "    %-22s %-18s %10s ms   %s\n" "$1" "${s:-?}" "${m:-?}" "$(read_of "$o")"
}

{
echo "# PostgreSQL 대조. $(Q 'SELECT version()' | cut -c1-45)"
echo "# orders ${ROWS}행. MySQL 쪽과 같은 규모, 같은 인덱스 구성."
echo

# ── 시드 ────────────────────────────────────────────────────────────────
echo "## 0) 시드"
Q "DROP TABLE IF EXISTS orders, order_legacy, order_legacy_fixed" >/dev/null
Q "CREATE TABLE orders (
     id bigserial PRIMARY KEY,
     order_no varchar(32) NOT NULL,
     user_id bigint NOT NULL,
     status_flag integer NOT NULL,
     amount integer NOT NULL,
     buyer_name varchar(64) NOT NULL,
     created_at timestamp NOT NULL)" >/dev/null
# created_at 은 timestamptz 가 아니라 timestamp 로 둔다.
# timestamptz 에서는 date() 가 TimeZone 에 좌우되는 STABLE 함수라 표현식 인덱스를 만들 수 없다.
Q "INSERT INTO orders (order_no, user_id, status_flag, amount, buyer_name, created_at)
   SELECT 'ORD' || lpad(i::text, 13, '0'),
          (i % 1000) + 1,
          (i % 512),
          1000 + (i % 5000),
          (ARRAY['김민준','이서연','박지호','최수아','정민준'])[(i % 5) + 1],
          timestamp '2026-01-01 00:00:00' + ((i % 864000) * interval '1 second')
     FROM generate_series(1,$ROWS) i" >/dev/null
Q "CREATE INDEX idx_order_no ON orders (order_no)" >/dev/null
Q "CREATE INDEX idx_user_created ON orders (user_id, created_at)" >/dev/null
Q "CREATE INDEX idx_buyer ON orders (buyer_name)" >/dev/null
Q "CREATE INDEX idx_created ON orders (created_at)" >/dev/null
Q "VACUUM ANALYZE orders" >/dev/null
echo "  행 수 = $(Q 'SELECT count(*) FROM orders'), 크기 = $(Q "SELECT pg_size_pretty(pg_total_relation_size('orders'))")"
echo

# ── 1) 암묵적 형변환 ────────────────────────────────────────────────────
echo "## 1) 암묵적 형변환"
echo "  MySQL: 조용히 풀스캔. type=ALL, 3,000,001행 훑고 1763.3ms (배수 3924)"
echo "  PostgreSQL:"
report "varchar = integer" "SELECT id, amount FROM orders WHERE order_no = 1500000"
report "varchar = varchar" "SELECT id, amount FROM orders WHERE order_no = 'ORD0000001500000'"
echo

# ── 2) 문자셋(콜레이션) 불일치 조인 ─────────────────────────────────────
echo "## 2) 콜레이션 불일치 조인"
echo "  MySQL: utf8mb4 와 latin1 비교가 인덱스를 배제. 3120.6ms (배수 75)"
Q "CREATE TABLE order_legacy (order_no varchar(32) COLLATE \"C\" PRIMARY KEY, memo varchar(200) NOT NULL)" >/dev/null
Q "CREATE TABLE order_legacy_fixed (order_no varchar(32) PRIMARY KEY, memo varchar(200) NOT NULL)" >/dev/null
Q "INSERT INTO order_legacy SELECT 'ORD' || lpad(i::text,13,'0'), 'm' FROM generate_series(1,600000) i" >/dev/null
Q "INSERT INTO order_legacy_fixed SELECT 'ORD' || lpad(i::text,13,'0'), 'm' FROM generate_series(1,600000) i" >/dev/null
Q "VACUUM ANALYZE order_legacy, order_legacy_fixed" >/dev/null
echo "  기본 콜레이션 = $(Q "SELECT datcollate FROM pg_database WHERE datname='spoon'")"
echo "  PostgreSQL:"
report "콜레이션 C vs 기본" "SELECT COUNT(*) FROM orders o JOIN order_legacy l ON o.order_no = l.order_no WHERE o.created_at >= '2026-01-02 00:00:00' AND o.created_at < '2026-01-02 00:10:00'"
report "콜레이션 일치"      "SELECT COUNT(*) FROM orders o JOIN order_legacy_fixed l ON o.order_no = l.order_no WHERE o.created_at >= '2026-01-02 00:00:00' AND o.created_at < '2026-01-02 00:10:00'"
echo

# ── 3) 인덱스 컬럼에 함수 적용 ──────────────────────────────────────────
echo "## 3) 인덱스 컬럼에 함수 적용"
echo "  MySQL: DATE(created_at) 이 인덱스를 못 씀. 배수 2 (결과 집합이 커서 배수가 작다)"
echo "         MySQL 8.0.13 부터 함수 인덱스가 있으므로 이 항목은 엔진 차이가 아니다."
echo "         A22 가 질의 재작성 쪽을 고른 선택의 차이다."
echo "  PostgreSQL:"
report "date() 적용, 인덱스 없음" "SELECT COUNT(*) FROM orders WHERE date(created_at) = '2026-01-02'"
report "범위로 고쳐 쓰기"          "SELECT COUNT(*) FROM orders WHERE created_at >= '2026-01-02' AND created_at < '2026-01-03'"
Q "CREATE INDEX idx_created_date ON orders (date(created_at))" >/dev/null
Q "ANALYZE orders" >/dev/null
echo "  → 표현식 인덱스를 만든다: CREATE INDEX ... ON orders (date(created_at))"
report "date() 적용, 인덱스 있음" "SELECT COUNT(*) FROM orders WHERE date(created_at) = '2026-01-02'"
echo

# ── 4) 선행 와일드카드 LIKE ─────────────────────────────────────────────
echo "## 4) 선행 와일드카드 LIKE"
echo "  MySQL: LIKE '%민준' 이 인덱스를 못 씀. 해소는 역순 컬럼을 따로 두는 것. 배수 5"
echo "  PostgreSQL:"
echo "  먼저 이 조건의 선택도를 밝힌다. buyer_name 이 5종뿐이라 '%민준' 은 1,200,000행,"
echo "  즉 40%를 고릅니다. 40%를 고르는 조건은 어떤 인덱스로도 빨라지지 않습니다."
Q "SELECT '    이름 ' || buyer_name || ' = ' || count(*) || '행' FROM orders GROUP BY buyer_name ORDER BY buyer_name"
report "LIKE '%민준' (40% 선택)" "SELECT COUNT(*) FROM orders WHERE buyer_name LIKE '%민준'"
Q "CREATE EXTENSION IF NOT EXISTS pg_trgm" >/dev/null
Q "CREATE INDEX idx_buyer_trgm ON orders USING gin (buyer_name gin_trgm_ops)" >/dev/null
Q "ANALYZE orders" >/dev/null
echo "  → pg_trgm GIN 인덱스를 만들어도 이 선택도에서는 플래너가 쓰지 않는다"
report "LIKE '%민준', GIN 있음"   "SELECT COUNT(*) FROM orders WHERE buyer_name LIKE '%민준'"
echo
echo "  선택도를 낮춰 다시 본다. order_no 는 300만 개가 전부 다르다."
report "LIKE '%9987', 인덱스 없음" "SELECT COUNT(*) FROM orders WHERE order_no LIKE '%9987'"
Q "CREATE INDEX idx_orderno_trgm ON orders USING gin (order_no gin_trgm_ops)" >/dev/null
Q "ANALYZE orders" >/dev/null
echo "  → pg_trgm GIN 인덱스를 만든다"
report "LIKE '%9987', GIN 있음"   "SELECT COUNT(*) FROM orders WHERE order_no LIKE '%9987'"
echo

# ── 5) 비트 연산 조건 ───────────────────────────────────────────────────
echo "## 5) 비트 연산 조건"
echo "  MySQL: (status_flag & 0x0100) 이 인덱스를 못 씀. 해소는 = 256 을 명시. 배수 22"
echo "  PostgreSQL:"
report "비트 연산, 인덱스 없음" "SELECT COUNT(*) FROM orders WHERE user_id = 1 AND (status_flag & 256) <> 0"
Q "CREATE INDEX idx_user_flag ON orders (user_id, (status_flag & 256))" >/dev/null
Q "ANALYZE orders" >/dev/null
echo "  → 표현식 인덱스를 만든다: CREATE INDEX ... ON orders (user_id, (status_flag & 256))"
report "비트 연산, 인덱스 있음" "SELECT COUNT(*) FROM orders WHERE user_id = 1 AND (status_flag & 256) <> 0"
echo

echo "## 정리"
echo "  조용히 느려지는 조건이 몇 개인가가 이 대조의 요점입니다."
echo "  각 조건 1회 실행이고, 절대 시간은 이 호스트에서만 성립합니다."
} 2>&1 | tee "$OUT/exp-pg.txt"
