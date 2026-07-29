#!/usr/bin/env bash
# 실험 1. 실수로 지운 테이블을 binlog로 사고 직전까지 되살린다.
#
# 타임라인
#   T0  풀백업(mysqldump)
#   T0~ 후원 500건이 더 들어온다 (백업에 없는 데이터)
#   T1  운영자가 실수로 DROP TABLE
#   T1~ 사고를 모른 채 다른 테이블에 쓰기가 계속된다
#
# 대조군: 백업만 복원하면 T0 이후가 통째로 사라진다(= 백업 주기가 곧 RPO 상한).
# 실험군: 백업 복원 + binlog를 사고 직전까지 적용하면 유실이 0이 된다.
#
# 복원은 원본이 아니라 별도 인스턴스(a23-restore)에서 한다. 두 가지 이유가 있다.
#   1. 사고 난 서버에 덤프를 되돌리면 GTID가 겹쳐 ERROR 3546으로 중단된다(실험 2)
#   2. 원본을 건드리지 않아야 복구가 실패해도 다시 시도할 수 있다
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"
mkdir -p "$OUT/dump"

SRC()  { docker exec a23-mysql    mysql -uroot -plab "$@" 2>/dev/null; }
SRCI() { docker exec -i a23-mysql mysql -uroot -plab "$@" 2>/dev/null; }   # 파이프 입력에는 -i가 필요하다
SRCQ() { docker exec a23-mysql    mysql -uroot -plab -N -B -e "$1" 2>/dev/null; }
DST()  { docker exec a23-restore    mysql -uroot -plab "$@" 2>/dev/null; }
DSTI() { docker exec -i a23-restore mysql -uroot -plab "$@" 2>/dev/null; }
DSTQ() { docker exec a23-restore    mysql -uroot -plab -N -B -e "$1" 2>/dev/null; }
log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$OUT/exp1.txt"; }
: > "$OUT/exp1.txt"

log "원본 초기화"
SRC -e "RESET BINARY LOGS AND GTIDS; DROP DATABASE IF EXISTS spoon; CREATE DATABASE spoon;"
SRC spoon -e "CREATE TABLE sponsor (id BIGINT AUTO_INCREMENT PRIMARY KEY, amount INT NOT NULL,
               created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3));
              CREATE TABLE audit_log (id BIGINT AUTO_INCREMENT PRIMARY KEY, msg VARCHAR(100));"

log "T0 이전 후원 1,000건 적재"
SRC spoon -e "INSERT INTO sponsor (amount) SELECT 1000 FROM
  (SELECT 1 a UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9 UNION SELECT 10) t1,
  (SELECT 1 a UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9 UNION SELECT 10) t2,
  (SELECT 1 a UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9 UNION SELECT 10) t3;"
BEFORE=$(SRCQ "SELECT COUNT(*) FROM spoon.sponsor")
log "T0 시점 행 수 $BEFORE"

# 풀백업. --single-transaction으로 일관된 스냅샷을, --source-data=2로 백업 시점 좌표를 주석에 남긴다.
log "T0 풀백업"
T_BK0=$(date +%s.%N)
docker exec a23-mysql mysqldump -uroot -plab --single-transaction --source-data=2 \
  --databases spoon > "$OUT/dump/full.sql" 2>/dev/null
T_BK1=$(date +%s.%N)
BK_SEC=$(echo "$T_BK1 - $T_BK0" | bc)
log "백업 소요 ${BK_SEC}초, 크기 $(du -h "$OUT/dump/full.sql" | cut -f1)"
COORD=$(grep -m1 "CHANGE REPLICATION SOURCE" "$OUT/dump/full.sql")
echo "$COORD" | tee -a "$OUT/exp1.txt"
BINFILE=$(echo "$COORD" | sed -n "s/.*SOURCE_LOG_FILE='\([^']*\)'.*/\1/p")
BINPOS=$(echo "$COORD" | sed -n "s/.*SOURCE_LOG_POS=\([0-9]*\).*/\1/p")

log "T0 이후 후원 500건 (백업에 없는 데이터)"
for _ in $(seq 1 500); do echo "INSERT INTO sponsor (amount) VALUES (2000);"; done | SRCI spoon
AFTER_T0=$(SRCQ "SELECT COUNT(*) FROM spoon.sponsor")
log "사고 직전 행 수 $AFTER_T0"

sleep 1
log "T1 사고: DROP TABLE sponsor"
SRC spoon -e "DROP TABLE sponsor;"
sleep 1
log "T1 이후 다른 테이블에 쓰기가 계속됨 (사고를 아직 모른다)"
for i in $(seq 1 50); do echo "INSERT INTO audit_log (msg) VALUES ('after-incident-$i');"; done | SRCI spoon

# binlog를 컨테이너 밖으로 꺼낸다. 백업 대상에 binlog가 포함돼야 하는 이유다.
docker exec a23-mysql bash -c "cat /var/lib/mysql/$BINFILE" > "$OUT/dump/incident.binlog"
log "binlog 확보 $BINFILE ($(du -h "$OUT/dump/incident.binlog" | cut -f1)), 백업 시점 좌표 $BINPOS"

# ── 대조군: 백업만 복원 ──
log "대조군: 복구 인스턴스에 백업만 복원"
DST -e "RESET BINARY LOGS AND GTIDS; DROP DATABASE IF EXISTS spoon;"
T_R0=$(date +%s.%N)
DSTI < "$OUT/dump/full.sql"
T_R1=$(date +%s.%N)
R_SEC=$(echo "$T_R1 - $T_R0" | bc)
ONLY_DUMP=$(DSTQ "SELECT COUNT(*) FROM spoon.sponsor")
log "복원 소요 ${R_SEC}초, 행 수 $ONLY_DUMP → 유실 $((AFTER_T0 - ONLY_DUMP))건"

# ── 사고 위치 찾기 ──
# 공식 문서가 안내하는 방식 그대로다. 다만 mysql:8.4 이미지에는 mysqlbinlog가 없어
# 클라이언트 유틸이 들어 있는 별도 컨테이너를 쓴다(실험 3).
docker exec a23-tools bash -c "mysqlbinlog --base64-output=DECODE-ROWS -v /dump/incident.binlog" \
  > "$OUT/binlog-decoded.txt" 2>/dev/null
DROP_POS=$(awk '/^# at /{p=$3} /DROP TABLE/{print p; exit}' "$OUT/binlog-decoded.txt")
log "DROP TABLE 이벤트 시작 위치 $DROP_POS"
grep -B3 -m1 -A1 "DROP TABLE" "$OUT/binlog-decoded.txt" | tee -a "$OUT/exp1.txt"

# ── 실험군: 백업 + binlog를 사고 직전까지 ──
log "실험군: 백업 복원 후 binlog를 $BINPOS ~ $DROP_POS 구간만 적용"
DST -e "RESET BINARY LOGS AND GTIDS; DROP DATABASE IF EXISTS spoon;"
DSTI < "$OUT/dump/full.sql"
T_B0=$(date +%s.%N)
docker exec a23-tools bash -c \
  "mysqlbinlog --start-position=$BINPOS --stop-position=$DROP_POS /dump/incident.binlog > /dump/recover.sql"
DSTI < "$OUT/dump/recover.sql"
T_B1=$(date +%s.%N)
B_SEC=$(echo "$T_B1 - $T_B0" | bc)
RECOVERED=$(DSTQ "SELECT COUNT(*) FROM spoon.sponsor")
log "binlog 추출·적용 소요 ${B_SEC}초, 행 수 $RECOVERED → 유실 $((AFTER_T0 - RECOVERED))건"

{
  echo
  echo "요약 (사고 직전 정답 ${AFTER_T0}건)"
  printf "  %-26s %8s건   유실 %s건\n" "백업만 복원" "$ONLY_DUMP" "$((AFTER_T0 - ONLY_DUMP))"
  printf "  %-26s %8s건   유실 %s건\n" "백업 + binlog PITR" "$RECOVERED" "$((AFTER_T0 - RECOVERED))"
  echo
  echo "  RTO 분해   백업 ${BK_SEC}초 / 덤프 복원 ${R_SEC}초 / binlog 적용 ${B_SEC}초"
} | tee -a "$OUT/exp1.txt"
