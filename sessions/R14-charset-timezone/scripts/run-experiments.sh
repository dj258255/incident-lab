#!/usr/bin/env bash
# 문자셋·타임존 지뢰 6종을 순서대로 밟고 출력을 원문으로 남긴다.
# 장애 하나를 재현하는 스크립트가 아니라 독립된 함정 여섯 개의 카탈로그다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"
mkdir -p "$OUT"

# 클라이언트 접속 문자셋을 반드시 명시한다. 명시하지 않으면 이 컨테이너의 mysql 클라이언트가
# latin1로 붙고, 이모지의 UTF-8 바이트가 latin1 문자 4개로 해석돼 "성공한 것처럼" 저장된다.
# 그 착시는 실험 6에서 따로 재현한다.
M() { docker exec r14-mysql mysql -uroot -plab spoon --default-character-set=utf8mb4 --comments -t -e "$1" 2>&1 | grep -v "Warning.*password"; }
MLATIN() { docker exec r14-mysql mysql -uroot -plab spoon --default-character-set=latin1 --comments -t -e "$1" 2>&1 | grep -v "Warning.*password"; }

echo "== 0. 기본값 확인 =="
M "SELECT @@version, @@character_set_server, @@collation_server; SELECT @@sql_mode\G" \
  | tee "$OUT/00-defaults.txt"

echo "== 1. utf8mb3에 이모지가 들어올 때 =="
{
  M "CREATE TABLE chat_mb3 (id INT AUTO_INCREMENT PRIMARY KEY, body TEXT) CHARACTER SET utf8mb3;"
  echo '--- strict(기본값)에서: 에러로 거부된다'
  M "INSERT INTO chat_mb3 (body) VALUES ('좋은 방송 😀 후원했어요');"
  echo '--- non-strict로 바꾸면: 에러 없이 이모지가 ?로 치환된다 (뒤 문자열은 살아남는다)'
  M "SET SESSION sql_mode=''; INSERT INTO chat_mb3 (body) VALUES ('좋은 방송 😀 후원했어요'); SHOW WARNINGS; SELECT id, body, CHAR_LENGTH(body) AS len FROM chat_mb3;"
  echo '--- WordPress 4.1.2(5.5/5.6 시절)라면 절단이라 닫는 태그가 날아간다. 8.4는 치환이라 남는다'
  M "SET SESSION sql_mode=''; INSERT INTO chat_mb3 (body) VALUES ('<b>공지</b> 😀 </b>닫는 태그는 여기 있었다'); SELECT body FROM chat_mb3 ORDER BY id DESC LIMIT 1;"
} | tee "$OUT/01-truncation.txt"

echo "== 2. 인덱스 키 길이 767바이트 =="
{
  echo '--- COMPACT + utf8mb4 VARCHAR(255) 인덱스: 767바이트 초과'
  M "CREATE TABLE t_compact (name VARCHAR(255), KEY(name)) CHARACTER SET utf8mb4 ROW_FORMAT=COMPACT;"
  echo '--- 같은 조건에서 191자로 줄이면 성공 (191 x 4 = 764바이트)'
  M "CREATE TABLE t_compact191 (name VARCHAR(255), KEY(name(191))) CHARACTER SET utf8mb4 ROW_FORMAT=COMPACT; SHOW CREATE TABLE t_compact191\G"
  echo '--- 기본 ROW_FORMAT(DYNAMIC)이면 3072바이트라 255자도 성공'
  M "CREATE TABLE t_dynamic (name VARCHAR(255), KEY(name)) CHARACTER SET utf8mb4; SELECT TABLE_NAME, ROW_FORMAT FROM information_schema.TABLES WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME LIKE 't_%';"
} | tee "$OUT/02-index-limit.txt"

echo "== 3. CONVERT_TZ의 조용한 NULL =="
{
  M "CREATE TABLE sponsor_utc (id INT AUTO_INCREMENT PRIMARY KEY, amount INT, paid_at_utc DATETIME);
     INSERT INTO sponsor_utc (amount, paid_at_utc) VALUES
       (10000,'2026-07-27 14:30:00'),(5000,'2026-07-27 15:10:00'),
       (30000,'2026-07-27 16:05:00'),(9000,'2026-07-28 01:00:00');"
  echo '--- 공식 Docker 이미지는 타임존 테이블이 이미 적재돼 있다 (문서의 기본 서술과 다른 점)'
  M "SELECT COUNT(*) AS tz_rows FROM mysql.time_zone_name;"
  echo '--- tarball·rpm 설치 직후 상태를 만들기 위해 타임존 테이블을 비운다'
  M "TRUNCATE mysql.time_zone; TRUNCATE mysql.time_zone_name; TRUNCATE mysql.time_zone_transition; TRUNCATE mysql.time_zone_transition_type;"
  docker restart r14-mysql >/dev/null && sleep 15   # 타임존 캐시를 비우기 위해 재시작
  echo '--- 미적재 상태: 에러가 아니라 집계가 통째로 NULL 한 줄이 된다'
  M "SELECT COUNT(*) AS tz_rows FROM mysql.time_zone_name;
     SELECT DATE(CONVERT_TZ(paid_at_utc,'UTC','Asia/Seoul')) AS kst_day, SUM(amount) AS daily_sum
     FROM sponsor_utc GROUP BY kst_day;"
  echo '--- mysql_tzinfo_to_sql로 적재하면 같은 쿼리가 정상 집계된다'
  docker exec r14-mysql bash -c "mysql_tzinfo_to_sql /usr/share/zoneinfo 2>/dev/null | mysql -uroot -plab mysql" 2>&1 | grep -v "Warning.*password" || true
  M "SELECT COUNT(*) AS tz_rows FROM mysql.time_zone_name;
     SELECT DATE(CONVERT_TZ(paid_at_utc,'UTC','Asia/Seoul')) AS kst_day, SUM(amount) AS daily_sum
     FROM sponsor_utc GROUP BY kst_day;"
} | tee "$OUT/03-convert-tz.txt"

echo "== 4. TIMESTAMP와 DATETIME의 타임존 동작 =="
{
  M "CREATE TABLE ts_vs_dt (id INT AUTO_INCREMENT PRIMARY KEY, ts TIMESTAMP, dt DATETIME);
     SET SESSION time_zone='Asia/Seoul';
     INSERT INTO ts_vs_dt (ts, dt) VALUES ('2026-07-28 21:00:00','2026-07-28 21:00:00');"
  echo '--- 서울 세션에서 저장한 값을 뉴욕 세션에서 읽으면: TIMESTAMP만 변한다'
  M "SET SESSION time_zone='America/New_York'; SELECT ts, dt FROM ts_vs_dt;"
  echo '--- TIMESTAMP 상한(2038-01-19 03:14:07 UTC) 초과'
  M "SET SESSION time_zone='+00:00'; INSERT INTO ts_vs_dt (ts, dt) VALUES ('2038-01-19 03:14:08','2038-01-19 03:14:08');"
} | tee "$OUT/04-timestamp.txt"

echo "== 5. 이모지가 깨질 때 무엇까지 같이 깨지나 =="
{
  echo '--- 한글·한자·일본어는 utf8mb3(3바이트)로 충분하다. 깨지는 것은 4바이트 보충 평면이다'
  M "SET SESSION sql_mode='';
     CREATE TABLE lang_test (src VARCHAR(20), body TEXT) CHARACTER SET utf8mb3;
     INSERT INTO lang_test VALUES
       ('한국어','후원 감사합니다'), ('日本語','ありがとう'), ('中文','谢谢大家'),
       ('이모지','감사 🙏 합니다'), ('한자확장B','𠀋 은 4바이트다');
     SELECT src, body, CHAR_LENGTH(body) AS len FROM lang_test;"
} | tee "$OUT/05-languages.txt"

echo "== 6. 접속 문자셋이 만드는 이중 인코딩 착시 =="
{
  echo '--- latin1로 접속한 클라이언트가 이모지를 넣으면: 에러 없이 성공한 것처럼 보인다'
  MLATIN "CREATE TABLE mojibake (body TEXT) CHARACTER SET utf8mb3;
          INSERT INTO mojibake VALUES ('후원 😀 감사');
          SELECT body FROM mojibake;"
  echo '--- 같은 데이터를 utf8mb4 접속으로 읽으면: 깨진 문자열이 드러난다'
  M "SELECT body, HEX(LEFT(body,4)) AS first_bytes FROM mojibake;"
} | tee "$OUT/06-mojibake.txt"

echo "실험 종료"
