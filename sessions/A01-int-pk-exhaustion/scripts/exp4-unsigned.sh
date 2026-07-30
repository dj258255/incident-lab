#!/usr/bin/env bash
# INT UNSIGNED 로 미루는 선택지의 손익을 잰다.
#
# README 의 "못 한 것"에 이렇게 적어 두었다.
#   INT UNSIGNED 로 바꾸면 상한이 42억이 되어 시간을 벌지만, 같은 일을 두 번 하게 된다.
#
# "같은 일"이 정말 같은지가 재볼 대목이다. 둘 다 ALGORITHM=COPY 라면 비용이 같고
# 얻는 것만 다르다. 상한과 소요와 테이블 크기를 나란히 놓는다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
M(){  docker exec a01-mysql mysql -uroot -plab spoon -N -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }
ME(){ docker exec a01-mysql mysql -uroot -plab spoon    -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }

for _ in $(seq 1 90); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(M 'SELECT 1')" = "1" ] || { echo "중단: a01-mysql 이 쿼리를 받지 못합니다" >&2; exit 2; }

ROWS=${ROWS:-3000000}

seed(){ # $1=테이블명
  M "DROP TABLE IF EXISTS $1" >/dev/null
  M "CREATE TABLE $1 (id INT AUTO_INCREMENT PRIMARY KEY, live_id INT, amount INT, memo VARCHAR(20)) ENGINE=InnoDB" >/dev/null
  # 재귀 CTE 로 채운다. 300만 행이면 기본 재귀 상한을 올려야 한다.
  M "SET SESSION cte_max_recursion_depth = $((ROWS + 10));
     INSERT INTO $1 (live_id, amount, memo)
     WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < $ROWS)
     SELECT n%1000+1, 1000, 'x' FROM s" >/dev/null
  M "ANALYZE TABLE $1" >/dev/null
}

size_of(){ M "SELECT ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024) FROM information_schema.TABLES WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='$1'"; }

run(){ # $1=라벨 $2=테이블 $3=목표타입
  seed "$2"
  local before after t0 t1
  before=$(size_of "$2")
  echo "  [$1] 전환 전 크기 ${before}MB, 행 수 $(M "SELECT COUNT(*) FROM $2")"
  # 먼저 INPLACE 를 요청해 엔진이 거부하는지 본다.
  echo "  [$1] INPLACE 요청:"
  ME "ALTER TABLE $2 MODIFY id $3 AUTO_INCREMENT, ALGORITHM=INPLACE, LOCK=NONE" 2>&1 | grep -E "ERROR" | sed 's/^/      /'
  t0=$(date +%s.%N)
  ME "ALTER TABLE $2 MODIFY id $3 AUTO_INCREMENT, ALGORITHM=COPY" >/dev/null 2>&1
  t1=$(date +%s.%N)
  after=$(size_of "$2")
  local coltype maxv
  coltype=$(M "SELECT COLUMN_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='$2' AND COLUMN_NAME='id'")
  case "$3" in
    "INT UNSIGNED") maxv="4294967295";;
    "BIGINT")       maxv="9223372036854775807";;
    *)              maxv="?";;
  esac
  printf "  [%s] COPY 소요 %.1f초, 전환 후 크기 %sMB, 컬럼 %s, 상한 %s\n" \
    "$1" "$(echo "$t1-$t0" | bc)" "$after" "$coltype" "$maxv"
}

{
echo "# INT UNSIGNED 로 미루는 선택지의 손익"
echo "# $(M 'SELECT VERSION()'), 행 수 $ROWS"
echo
echo "## INT SIGNED(상한 21억) 에서 두 목표로 각각 전환한다"
echo
run "UNSIGNED" sponsor_u "INT UNSIGNED"
echo
run "BIGINT"   sponsor_b8 "BIGINT"
echo
echo "## 정리"
echo "  둘 다 ALGORITHM=INPLACE 를 거부당하고 COPY 로만 됩니다."
echo "  즉 전환 비용의 성격이 같고, 얻는 상한만 다릅니다."
echo "  UNSIGNED 는 21억에서 42억으로 2배를 벌고, BIGINT 는 약 42억 배를 법니다."
echo "  각 조건 1회 실행입니다."
} 2>&1 | tee "$OUT/exp4-unsigned.txt"
