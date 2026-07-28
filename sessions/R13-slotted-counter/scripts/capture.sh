#!/usr/bin/env bash
# reproduce.md에 붙일 콘솔 출력을 실제로 실행해서 받아 둔다.
# 문서에 손으로 옮겨 적으면 원문이 아니게 되고, 나중에 검증할 수도 없다.
#
# 주의: 측정이 도는 중에 실행하면 DB에 부하를 얹어 결과를 흔든다. 측정이 끝난 뒤에만 돌린다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results/capture"
mkdir -p "$OUT"

run() {  # run <파일명> <설명> <명령...>
  local name="$1" desc="$2"; shift 2
  { echo "\$ $*"; "$@" 2>&1; } > "$OUT/$name.txt"
  echo "저장 $name  ($desc)"
}

run env-docker   "컨테이너 상태"   docker compose -f "$ROOT/compose.yml" ps
run env-mysql    "MySQL 버전·설정" docker exec r13-mysql mysql -uroot -plab -t -e \
  "SELECT VERSION() AS version, @@innodb_buffer_pool_size AS buffer_pool,
          @@transaction_isolation AS isolation, @@innodb_flush_log_at_trx_commit AS flush_at_commit;"
run env-schema   "테이블 목록"     docker exec r13-mysql mysql -uroot -plab spoon -t -e \
  "SELECT TABLE_NAME, TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA='spoon' ORDER BY TABLE_NAME;"

# 갱신 유실을 애플리케이션 없이 DB 세션 두 개만으로 재현한다.
# 한 세션에서 순서만 흉내 내면 "이러면 이렇게 된다"는 설명일 뿐이라, 실제로 두 세션을 동시에 띄운다.
# 둘 다 값을 읽은 뒤 SLEEP으로 구간을 겹치게 만들고, 각자 읽은 값에 더해서 쓴다.
mysql_session() {  # mysql_session <더할 금액>
  docker exec -i r13-mysql mysql -uroot -plab spoon 2>&1 <<SQL
SELECT total INTO @v FROM demo_counter WHERE id = 1;
DO SLEEP(2);
UPDATE demo_counter SET total = @v + $1 WHERE id = 1;
SELECT CONCAT('세션이 읽은 값 ', @v, ', 쓴 값 ', @v + $1) AS log;
SQL
}

{
  echo '$ # 준비'
  docker exec -i r13-mysql mysql -uroot -plab spoon -t 2>&1 <<'SQL'
DROP TABLE IF EXISTS demo_counter;
CREATE TABLE demo_counter (id INT PRIMARY KEY, total INT NOT NULL) ENGINE=InnoDB;
INSERT INTO demo_counter VALUES (1, 5000);
SELECT total AS '시작값' FROM demo_counter WHERE id = 1;
SQL
  echo
  echo '$ # 세션 A(+3000)와 세션 B(+2000)를 동시에 실행'
  mysql_session 3000 & A=$!
  mysql_session 2000 & B=$!
  wait $A $B
  echo
  echo '$ # 결과'
  docker exec -i r13-mysql mysql -uroot -plab spoon -t 2>&1 <<'SQL'
SELECT total AS '최종값', 10000 AS '있어야 할 값', 10000 - total AS '사라진 금액'
FROM demo_counter WHERE id = 1;
DROP TABLE demo_counter;
SQL
} > "$OUT/lost-update-sql.txt"
echo "저장 lost-update-sql  (갱신 유실을 세션 2개로 재현)"

echo "완료: $OUT"
