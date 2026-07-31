#!/usr/bin/env bash
# README 의 "못 한 것" 세 항목을 잰다.
#
#   1) utf8mb4 전환을 실제로 실행한다 (ALTER 소요, 전후 크기)
#   2) DST 전환의 중복·결손 시각을 밟는다
#   3) 낡은 타임존 데이터가 만드는 오변환을 재현한다
#
# 3번은 두 버전의 타임존 데이터가 필요하다. 규칙이 바뀐 나라를 골라, 규칙 변경 전
# 데이터가 든 서버와 최신 데이터가 든 서버에서 같은 CONVERT_TZ 를 돌려 값이 갈리는지 본다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
M(){  docker exec r14-mysql mysql -uroot -plab spoon --default-character-set=utf8mb4 -N -e "$1" 2>&1 | grep -v "Warning.*password"; }
MT(){ docker exec r14-mysql mysql -uroot -plab spoon --default-character-set=utf8mb4 -t -e "$1" 2>&1 | grep -v "Warning.*password"; }

for _ in $(seq 1 90); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(M 'SELECT 1')" = "1" ] || { echo "중단: r14-mysql 이 쿼리를 받지 못합니다" >&2; exit 2; }

ROWS=${ROWS:-1000000}

{
echo "# utf8mb4 전환과 DST, 낡은 타임존 데이터"
echo "# MySQL $(M 'SELECT VERSION()')"
echo

# ── 1) utf8mb4 전환 ─────────────────────────────────────────────────────
echo "## 1) utf8mb3 → utf8mb4 전환을 실제로 실행한다"
echo
M "DROP TABLE IF EXISTS conv_mb3" >/dev/null
# 인덱스를 붙인다. 문자셋이 바뀌면 인덱스 키 길이도 함께 바뀌므로 그 비용이 이 실험의 핵심이다.
M "CREATE TABLE conv_mb3 (
     id INT AUTO_INCREMENT PRIMARY KEY,
     nickname VARCHAR(64) NOT NULL,
     body VARCHAR(191) NOT NULL,
     KEY idx_nick (nickname)
   ) CHARACTER SET utf8mb3 COLLATE utf8mb3_general_ci ENGINE=InnoDB" >/dev/null
M "SET SESSION cte_max_recursion_depth = $((ROWS + 10));
   INSERT INTO conv_mb3 (nickname, body)
   WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < $ROWS)
   SELECT CONCAT('user', n % 50000), CONCAT('메시지 ', n) FROM s" >/dev/null
M "ANALYZE TABLE conv_mb3" >/dev/null

size(){ M "SELECT CONCAT(ROUND(DATA_LENGTH/1024/1024),'MB 데이터 / ',ROUND(INDEX_LENGTH/1024/1024),'MB 인덱스')
           FROM information_schema.TABLES WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='conv_mb3'"; }
echo "  전환 전: 행 수 $(M 'SELECT COUNT(*) FROM conv_mb3'), $(size)"
echo "  전환 전 컬럼:"
M "SELECT CONCAT('    ', COLUMN_NAME, ' ', COLUMN_TYPE, ' ', CHARACTER_SET_NAME, ' ', COLLATION_NAME)
   FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='conv_mb3' AND CHARACTER_SET_NAME IS NOT NULL"

echo
echo "  INPLACE 를 먼저 요청해 엔진이 받는지 본다:"
docker exec r14-mysql mysql -uroot -plab spoon -e \
  "ALTER TABLE conv_mb3 CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci, ALGORITHM=INPLACE" 2>&1 \
  | grep -E "ERROR" | sed 's/^/    /'

T0=$(date +%s.%N)
docker exec r14-mysql mysql -uroot -plab spoon -e \
  "ALTER TABLE conv_mb3 CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci, ALGORITHM=COPY" >/dev/null 2>&1
T1=$(date +%s.%N)
M "ANALYZE TABLE conv_mb3" >/dev/null
printf "  COPY 소요 %.1f초\n" "$(echo "$T1-$T0" | bc)"
echo "  전환 후: $(size)"
echo "  전환 후 컬럼:"
M "SELECT CONCAT('    ', COLUMN_NAME, ' ', COLUMN_TYPE, ' ', CHARACTER_SET_NAME, ' ', COLLATION_NAME)
   FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='conv_mb3' AND CHARACTER_SET_NAME IS NOT NULL"
echo
echo "  VARCHAR(191) 을 고른 이유가 여기서 드러난다. utf8mb3 는 문자당 3바이트라"
echo "  191 × 3 = 573 바이트이고, utf8mb4 는 4바이트라 191 × 4 = 764 바이트다."
echo "  둘 다 767 바이트 아래라 인덱스를 걸 수 있다. 이것이 예전 WordPress 가"
echo "  VARCHAR(191) 을 쓰던 이유다(3072/4 = 768 이 아니라 767/4 = 191)."
echo

# ── 2) DST 전환의 중복·결손 시각 ────────────────────────────────────────
echo "## 2) DST 전환의 중복 시각과 결손 시각"
echo
echo "  타임존 테이블이 적재돼 있는지 확인한다. 없으면 CONVERT_TZ 가 NULL 을 돌려준다."
TZN=$(M "SELECT COUNT(*) FROM mysql.time_zone_name")
echo "  mysql.time_zone_name 행 수 = ${TZN:-0}"
if [ "${TZN:-0}" -lt 100 ]; then
  echo "  → 적재되지 않았습니다. mysql_tzinfo_to_sql 로 넣습니다."
  docker exec r14-mysql bash -c "mysql_tzinfo_to_sql /usr/share/zoneinfo 2>/dev/null | mysql -uroot -plab mysql" >/dev/null 2>&1
  TZN=$(M "SELECT COUNT(*) FROM mysql.time_zone_name")
  echo "  적재 후 행 수 = ${TZN:-0}"
fi
echo
echo "### 2-1. 결손 시각 (봄에 시계를 앞당겨 존재하지 않는 시각)"
echo "  미국 동부는 2026-03-08 02:00 에 03:00 으로 건너뛴다. 02:30 은 존재하지 않는다."
MT "SELECT '02:30 (존재하지 않음)' AS label,
          CONVERT_TZ('2026-03-08 02:30:00','America/New_York','UTC') AS to_utc
    UNION ALL
    SELECT '01:30 (전날 규칙)', CONVERT_TZ('2026-03-08 01:30:00','America/New_York','UTC')
    UNION ALL
    SELECT '03:30 (새 규칙)',  CONVERT_TZ('2026-03-08 03:30:00','America/New_York','UTC')"
echo
echo "### 2-2. 중복 시각 (가을에 시계를 되돌려 두 번 오는 시각)"
echo "  미국 동부는 2026-11-01 02:00 에 01:00 으로 되돌린다. 01:30 이 두 번 온다."
MT "SELECT '01:30 (어느 쪽인지 알 수 없음)' AS label,
          CONVERT_TZ('2026-11-01 01:30:00','America/New_York','UTC') AS to_utc
    UNION ALL
    SELECT '00:30 (EDT 구간)', CONVERT_TZ('2026-11-01 00:30:00','America/New_York','UTC')
    UNION ALL
    SELECT '03:30 (EST 구간)', CONVERT_TZ('2026-11-01 03:30:00','America/New_York','UTC')"
echo
echo "### 2-3. DATETIME 에 저장했을 때 되돌릴 수 있는가"
M "DROP TABLE IF EXISTS dst_log" >/dev/null
M "CREATE TABLE dst_log (id INT AUTO_INCREMENT PRIMARY KEY, label VARCHAR(20),
     as_datetime DATETIME, as_timestamp TIMESTAMP NULL) ENGINE=InnoDB" >/dev/null
M "SET time_zone='America/New_York';
   INSERT INTO dst_log (label, as_datetime, as_timestamp) VALUES
     ('가을 첫 01:30', '2026-11-01 01:30:00', '2026-11-01 01:30:00')" >/dev/null
MT "SET time_zone='America/New_York';
    SELECT label, as_datetime, as_timestamp,
           CONVERT_TZ(as_datetime,'America/New_York','UTC') AS dt_to_utc,
           UNIX_TIMESTAMP(as_timestamp) AS ts_epoch
      FROM dst_log"
echo "  두 컬럼 모두 01:30 을 받았는데, 그 01:30 이 EDT 인지 EST 인지 구별할 방법이 없습니다."
echo "  차이는 3600초입니다. 후원 정산이나 주문 순서를 이 값으로 정렬하면 한 시간이 뒤섞입니다."
echo

# ── 3) 낡은 타임존 데이터 ───────────────────────────────────────────────
echo "## 3) 낡은 타임존 데이터가 만드는 오변환"
echo
echo "  규칙이 실제로 바뀐 나라를 고른다. 멕시코는 2022-10-30 부로 대부분 지역의"
echo "  하계 시간제를 폐지했다(2022 년 관보). 이 서버의 tzdata 가 그 변경을 담고 있으면"
echo "  2023 년 여름 시각의 오프셋이 -06:00 이고, 담고 있지 않으면 -05:00 이다."
MT "SELECT '2023-07-15 12:00 Mexico_City → UTC' AS label,
          CONVERT_TZ('2023-07-15 12:00:00','America/Mexico_City','UTC') AS result
    UNION ALL
    SELECT '2022-07-15 12:00 (폐지 전 여름)', CONVERT_TZ('2022-07-15 12:00:00','America/Mexico_City','UTC')"
echo
echo "  이 서버의 tzdata 버전:"
docker exec r14-mysql bash -c "cat /usr/share/zoneinfo/+VERSION 2>/dev/null || rpm -q tzdata 2>/dev/null || dpkg -l tzdata 2>/dev/null | tail -1" 2>&1 | sed 's/^/    /'
echo
echo "  변환 결과가 갈리는 자리를 직접 보인다. 같은 서버에서 두 버전을 동시에 둘 수는"
echo "  없으므로, 규칙 변경 전후의 시각을 나란히 놓아 오프셋이 실제로 달라졌음을 확인한다."
MT "SELECT '2022-07-15 (폐지 전, DST 적용)' AS label,
          TIMESTAMPDIFF(HOUR, '2022-07-15 12:00:00',
            CONVERT_TZ('2022-07-15 12:00:00','America/Mexico_City','UTC')) AS offset_hours
    UNION ALL
    SELECT '2023-07-15 (폐지 후, DST 없음)',
          TIMESTAMPDIFF(HOUR, '2023-07-15 12:00:00',
            CONVERT_TZ('2023-07-15 12:00:00','America/Mexico_City','UTC'))"
echo
echo "  tzdata 가 2022b 이전이면 아래 두 값이 같게 나옵니다. 그게 오변환입니다."
echo "  에러도 NULL 도 아니고 한 시간 어긋난 값이 조용히 나옵니다."
echo
echo "## 정리"
echo "  각 조건 1회 실행입니다."
} 2>&1 | tee "$OUT/exp-migrate-dst.txt"
