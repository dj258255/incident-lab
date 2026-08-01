#!/usr/bin/env bash
# 이 세션이 "재지 않았음"으로 남긴 두 자리를 잰다.
#
# 1) COLLATE 명시로 스키마 변경을 대신할 수 있는가.
#    이 세션 표의 문자셋 줄에 "COLLATE 명시로 대신 될지는 재지 않았음"이라고 적었다.
#    쿼리 단위 우회는 한쪽에 함수를 씌우는 효과라 그쪽 인덱스를 못 쓰게 만들 수 있는데,
#    이 대비를 명시한 MySQL 공식 문장도 못 찾았다. 양쪽 다 근거가 없으니 잰다.
#
# 2) 암묵적 형변환의 방향이 대칭인가.
#    이 세션은 VARCHAR 컬럼을 숫자와 비교하는 쪽만 쟀다. Percona 는 반대 방향을
#    이렇게 적는다. "you can refer to integer column as a string in most cases and
#    MySQL will use the index." 그 말이 맞는지 본다.
#
# 배수가 아니라 **실행계획**을 본다. 인덱스를 타는가 안 타는가가 질문이다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
C=a22-collate; N=${N:-300000}

docker rm -f "$C" >/dev/null 2>&1
docker run -d --name "$C" -e MYSQL_ROOT_PASSWORD=lab -e MYSQL_DATABASE=lab mysql:8.4.3 >/dev/null
M(){ docker exec -i "$C" mysql -uroot -plab -N -B lab -e "$1" 2>&1; }
J(){ docker exec -i "$C" mysql -uroot -plab -B lab -e "$1" 2>&1; }
for _ in $(seq 1 90); do [ "$(M 'SELECT 1' | tail -1)" = "1" ] && break; sleep 2; done
[ "$(M 'SELECT 1' | tail -1)" = "1" ] || { echo "중단: MySQL 이 안 뜹니다" >&2; exit 2; }

M "CREATE TABLE orders(
     id INT PRIMARY KEY,
     order_no VARCHAR(32) CHARACTER SET utf8mb4 NOT NULL,
     amt INT NOT NULL, KEY idx_no (order_no)) ENGINE=InnoDB;
   CREATE TABLE legacy(
     order_no VARCHAR(32) CHARACTER SET latin1 NOT NULL PRIMARY KEY,
     memo VARCHAR(32)) ENGINE=InnoDB;
   CREATE TABLE nums(id INT PRIMARY KEY, code INT NOT NULL, KEY idx_code (code)) ENGINE=InnoDB;
   SET SESSION cte_max_recursion_depth=$((N+10));
   INSERT INTO orders SELECT n, CONCAT('ORD',LPAD(n,12,'0')), n%9999 FROM (
     WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<$N) SELECT n FROM s) q;
   INSERT INTO legacy SELECT CONCAT('ORD',LPAD(n,12,'0')), 'm' FROM (
     WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<$((N/10))) SELECT n FROM s) q;
   INSERT INTO nums SELECT n, n FROM (
     WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<$N) SELECT n FROM s) q;" >/dev/null

for t in orders legacy nums; do
  g=$(M "SELECT COUNT(*) FROM $t" | tail -1)
  [ "${g:-0}" -lt 1000 ] && { echo "중단: $t 적재가 ${g:-0}행입니다" >&2; docker rm -f "$C" >/dev/null; exit 2; }
done
M "ANALYZE TABLE orders, legacy, nums;" >/dev/null

# 1차 시도는 EXPLAIN 을 파싱했는데 두 가지가 어긋났다. mysql -B 에 2>&1 을 걸어
# 비밀번호 경고가 1행에 끼어서 헤더를 못 걸렀고, 열 번호도 밀렸다.
# 실행계획 문자열 대신 **핸들러 카운터**로 본다. 인덱스를 탔는지 안 탔는지는
# 옵티마이저가 뭐라고 적었는가가 아니라 실제로 몇 행을 만졌는가로 갈린다.
# 캐싱을 안 지우면 뒤 조건이 앞 조건이 데워 놓은 버퍼 풀을 쓴다. 그러면 벽시계
# 차이가 접근 방식의 차이인지 캐시 상태의 차이인지 갈리지 않는다.
# 조건마다 컨테이너를 재시작해 버퍼 풀과 적응형 해시 인덱스를 비우고, 같은 방식으로
# 데운 뒤 잰다. 호스트 페이지 캐시는 이 방법으로 안 지워지므로 그 조건은 밝혀 둔다.
reset_cache(){
  docker restart "$C" >/dev/null
  for _ in $(seq 1 90); do [ "$(M 'SELECT 1' | tail -1)" = "1" ] && break; sleep 2; done
  # 전 조건에 똑같이 적용되는 웜업. 세 테이블을 같은 순서로 한 번씩 훑는다.
  M "SELECT COUNT(*) FROM orders; SELECT COUNT(*) FROM legacy; SELECT COUNT(*) FROM nums;" >/dev/null
}
probe(){ # $1 = 라벨, $2 = 쿼리
  local out t0 t1
  reset_cache
  t0=$(date +%s%N)
  out=$(docker exec -i "$C" mysql -uroot -plab -N -B lab -e "
    FLUSH STATUS;
    $2;
    SELECT CONCAT_WS('|',
      (SELECT VARIABLE_VALUE FROM performance_schema.session_status WHERE VARIABLE_NAME='Handler_read_key'),
      (SELECT VARIABLE_VALUE FROM performance_schema.session_status WHERE VARIABLE_NAME='Handler_read_next'),
      (SELECT VARIABLE_VALUE FROM performance_schema.session_status WHERE VARIABLE_NAME='Handler_read_rnd_next'));" 2>&1)
  t1=$(date +%s%N)
  if echo "$out" | grep -qi "^ERROR"; then
    printf "  %-34s **거부됨**\n" "$1"
    echo "$out" | grep -i "^ERROR" | head -1 | sed 's/^/        /'
    return
  fi
  local res cnt hk hn hr
  res=$(echo "$out" | grep -E '^[0-9]+\|[0-9]+\|[0-9]+$' | tail -1)
  cnt=$(echo "$out" | grep -vE '^[0-9]+\|[0-9]+\|[0-9]+$' | grep -vi warning | tail -1)
  IFS='|' read -r hk hn hr <<< "$res"
  printf '  %-34s %s\n' "$1" "$(printf '결과 %-6s 인덱스탐색 %-6s 인덱스순회 %-9s 풀스캔 %-8s %sms' \
    "${cnt:-?}건" "${hk:-?}" "${hn:-?}" "${hr:-?}" "$(( (t1-t0)/1000000 ))")"
}

{
echo "# COLLATE 우회와 형변환 방향"
echo "# MySQL $(M 'SELECT VERSION()' | tail -1) · orders $(M 'SELECT COUNT(*) FROM orders'|tail -1)행 / legacy $(M 'SELECT COUNT(*) FROM legacy'|tail -1)행 / nums $(M 'SELECT COUNT(*) FROM nums'|tail -1)행"
echo "# 인덱스를 탔는지는 핸들러 카운터로 봅니다. 풀스캔 값이 크면 못 탄 것입니다."
echo
echo "## 1. 문자셋 불일치 조인을 COLLATE 로 넘길 수 있는가"
echo
probe "(a) 아무것도 안 함" "SELECT COUNT(*) FROM orders o JOIN legacy l ON o.order_no = l.order_no"
probe "(b) COLLATE 를 명시" "SELECT COUNT(*) FROM orders o JOIN legacy l ON o.order_no = l.order_no COLLATE utf8mb4_0900_ai_ci"
probe "(c) CONVERT 로 맞춤" "SELECT COUNT(*) FROM orders o JOIN legacy l ON o.order_no = CONVERT(l.order_no USING utf8mb4)"
echo
echo "  legacy 를 utf8mb4 로 올린 뒤"
M "ALTER TABLE legacy CONVERT TO CHARACTER SET utf8mb4; ANALYZE TABLE legacy;" >/dev/null
probe "(d) 스키마를 통일" "SELECT COUNT(*) FROM orders o JOIN legacy l ON o.order_no = l.order_no"
echo
echo "   위 네 줄은 옵티마이저가 legacy(3만행)를 선두에 놓아 orders 의 인덱스만 씁니다."
echo "   어느 쪽 인덱스가 죽는지 보려면 orders 를 선두로 고정해 legacy 를 찾게 해야 합니다."
echo "   아래는 STRAIGHT_JOIN 으로 방향을 고정한 같은 질문입니다."
echo
M "DROP TABLE IF EXISTS legacy2;
   CREATE TABLE legacy2(order_no VARCHAR(32) CHARACTER SET latin1 NOT NULL PRIMARY KEY, memo VARCHAR(32)) ENGINE=InnoDB;
   INSERT INTO legacy2 SELECT order_no, memo FROM legacy;
   ANALYZE TABLE legacy2;" >/dev/null
L2=$(M "SELECT COUNT(*) FROM legacy2" | tail -1)
if [ "${L2:-0}" -lt 1000 ]; then
  echo "  중단: legacy2 적재가 ${L2:-0}행입니다. 아래 비교는 조건이 안 섰습니다"
else
probe "(e) 방향 고정, 아무것도 안 함" "SELECT STRAIGHT_JOIN COUNT(*) FROM orders o JOIN legacy2 l ON o.order_no = l.order_no"
probe "(f) 방향 고정, CONVERT" "SELECT STRAIGHT_JOIN COUNT(*) FROM orders o JOIN legacy2 l ON CONVERT(l.order_no USING utf8mb4) = o.order_no"
M "ALTER TABLE legacy2 CONVERT TO CHARACTER SET utf8mb4; ANALYZE TABLE legacy2;" >/dev/null
probe "(g) 방향 고정, 스키마 통일" "SELECT STRAIGHT_JOIN COUNT(*) FROM orders o JOIN legacy2 l ON o.order_no = l.order_no"
fi
echo
echo "## 2. 형변환의 방향이 대칭인가"
echo "   orders.order_no 는 VARCHAR, nums.code 는 INT 입니다. 둘 다 값 150000 이 있습니다."
echo
probe "(a) 문자열컬럼 = 숫자리터럴" "SELECT COUNT(*) FROM orders WHERE order_no = 150000"
probe "(b) 숫자컬럼 = 문자열리터럴" "SELECT COUNT(*) FROM nums WHERE code = '150000'"
probe "(c) 문자열컬럼 = 문자열(대조)" "SELECT COUNT(*) FROM orders WHERE order_no = 'ORD000000150000'"
probe "(d) 숫자컬럼 = 숫자(대조)" "SELECT COUNT(*) FROM nums WHERE code = 150000"
} 2>&1 | tee "$OUT/exp2-collate-and-direction.txt"
docker rm -f "$C" >/dev/null 2>&1
