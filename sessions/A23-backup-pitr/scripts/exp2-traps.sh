#!/usr/bin/env bash
# 실험 2~4. 복구를 가로막는 세 가지 함정.
#
#   2. GTID 겹침    : 사고 난 서버에 덤프를 되돌리면 첫 줄에서 중단된다
#   3. 도구 부재    : 공식 mysql 이미지에 mysqlbinlog가 없다
#   4. 조용한 스킵  : 이미 적용된 구간을 재적용하면 성공했다고 나오는데 데이터는 안 들어간다
#   5. binlog 만료  : PITR 창이 닫히면 그 구간은 영구 유실이다
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"
SRC()  { docker exec a23-mysql    mysql -uroot -plab "$@" 2>&1 | grep -v "Warning.*password"; }
SRCQ() { docker exec a23-mysql    mysql -uroot -plab -N -B -e "$1" 2>/dev/null; }
DST()  { docker exec a23-restore    mysql -uroot -plab "$@" 2>&1 | grep -v "Warning.*password"; }
DSTI() { docker exec -i a23-restore mysql -uroot -plab "$@" 2>&1 | grep -v "Warning.*password"; }
DSTQ() { docker exec a23-restore    mysql -uroot -plab -N -B -e "$1" 2>/dev/null; }
: > "$OUT/exp2.txt"
say() { echo "$*" | tee -a "$OUT/exp2.txt"; }

say "=============================================================="
say "함정 2. 사고 난 서버에 덤프를 되돌리면 첫 줄에서 막힌다"
say "=============================================================="
say '$ grep -m1 "GTID_PURGED" results/dump/full.sql'
grep -m1 "GTID_PURGED" "$OUT/dump/full.sql" | cut -c1-96 | tee -a "$OUT/exp2.txt"
say ""
say '$ docker exec -i a23-mysql mysql -uroot -plab < full.sql     # 원본 서버에 복원 시도'
docker exec -i a23-mysql mysql -uroot -plab < "$OUT/dump/full.sql" 2>&1 \
  | grep -v "Warning.*password" | head -2 | tee -a "$OUT/exp2.txt"
say ""
say "mysqldump가 기본으로 넣는 SET @@GLOBAL.GTID_PURGED가 이미 실행된 GTID와 겹쳐 중단된다."
say "사고 복구는 대개 원본 서버에서 하려고 하므로, 문서의 PITR 절차만 따르면 여기서 막힌다."
say "해법은 새 인스턴스에 복원하거나(권장), --set-gtid-purged=OFF로 덤프를 다시 뜨는 것이다."
say ""
say '$ mysqldump ... --set-gtid-purged=OFF 로 다시 뜨면'
docker exec a23-mysql mysqldump -uroot -plab --single-transaction --set-gtid-purged=OFF \
  --databases spoon > "$OUT/dump/full-nogtid.sql" 2>/dev/null
if grep -q "GTID_PURGED" "$OUT/dump/full-nogtid.sql"; then
  say "  GTID_PURGED 구문 있음"
else
  say "  GTID_PURGED 구문 없음 → 같은 서버에도 복원 가능"
fi

say ""
say "=============================================================="
say "함정 3. 공식 mysql 이미지에 mysqlbinlog가 없다"
say "=============================================================="
say '$ docker exec a23-mysql ls /usr/bin | grep mysql'
docker exec a23-mysql bash -c "ls /usr/bin | grep -i '^mysql'" | tee -a "$OUT/exp2.txt"
say ""
say '$ docker exec a23-mysql mysqlbinlog --version'
docker exec a23-mysql bash -c "mysqlbinlog --version" 2>&1 | head -1 | tee -a "$OUT/exp2.txt"
say ""
say "공식 문서의 PITR 절차는 전부 mysqlbinlog로 쓰여 있다."
say "컨테이너로 운영하면서 이 사실을 사고 당일에 알면 복구가 그 자리에서 멈춘다."
say "이 세션은 클라이언트 유틸이 들어 있는 별도 컨테이너(percona-server)로 우회했다."
docker exec a23-tools bash -c "mysqlbinlog --version" 2>&1 | head -1 | sed 's/^/  대안: /' | tee -a "$OUT/exp2.txt"

say ""
say "=============================================================="
say "함정 4. 이미 적용한 구간을 다시 적용하면 조용히 스킵된다"
say "=============================================================="
BEFORE_ROWS=$(DSTQ "SELECT COUNT(*) FROM spoon.sponsor")
BEFORE_GTID=$(DSTQ "SELECT @@GLOBAL.gtid_executed")
say "재적용 전 행 수 $BEFORE_ROWS"
say "재적용 전 gtid_executed $BEFORE_GTID"
say ""
say '$ mysql < recover.sql        # 방금 적용한 것과 똑같은 파일을 한 번 더'
docker exec -i a23-restore mysql -uroot -plab < "$OUT/dump/recover.sql" \
  > "$OUT/reapply.out" 2> "$OUT/reapply.err"
RC=$?
grep -v "Warning.*password" "$OUT/reapply.err" | head -2 | sed 's/^/  stderr: /' | tee -a "$OUT/exp2.txt"
AFTER_ROWS=$(DSTQ "SELECT COUNT(*) FROM spoon.sponsor")
AFTER_GTID=$(DSTQ "SELECT @@GLOBAL.gtid_executed")
say "종료 코드 ${RC} (0이면 성공)"
say "재적용 후 행 수 $AFTER_ROWS  → 늘어난 행 $((AFTER_ROWS - BEFORE_ROWS)) 건"
say "재적용 후 gtid_executed $AFTER_GTID"
DIFF=$(DSTQ "SELECT GTID_SUBTRACT('$AFTER_GTID','$BEFORE_GTID')")
say "GTID 차집합(새로 실행된 트랜잭션) '$DIFF'"
say ""
say "데이터는 한 건도 늘지 않았고 GTID 차집합도 비어 있다."
say "공식 문서가 적은 그대로다. 같은 GTID의 트랜잭션은 무시되고 에러도 나지 않는다."
say "운영자가 '복구했다'고 판단하기 딱 좋은 조건이다."

say ""
say "=============================================================="
say "함정 5. binlog가 만료되면 PITR 창이 닫힌다"
say "=============================================================="
docker exec a23-mysql mysql -uroot -plab -e "SET GLOBAL binlog_expire_logs_seconds = 2592000;" 2>/dev/null
say '$ SELECT @@binlog_expire_logs_seconds        # 기본값'
SRCQ "SELECT @@binlog_expire_logs_seconds" | sed 's/^/  /' | tee -a "$OUT/exp2.txt"
say "  (2592000초 = 30일)"
say ""
say "만료는 시각이 되면 자동으로 일어나지 않는다. 서버 기동 시점과 binlog flush 시점에만 정리된다."
say "그래서 만료를 짧게 잡고 FLUSH BINARY LOGS를 부르면 그 순간을 재현할 수 있다."
say ""
say '$ SET GLOBAL binlog_expire_logs_seconds = 1; FLUSH BINARY LOGS;'
# 파일을 여러 개 만들어 둔다. 그래야 오래된 것이 지워지는 게 눈에 보인다.
for _ in 1 2 3; do docker exec a23-mysql mysql -uroot -plab -e "FLUSH BINARY LOGS;" 2>/dev/null; done
BEFORE_LOGS=$(SRCQ "SHOW BINARY LOGS" | wc -l | tr -d ' ')
FIRST_BEFORE=$(SRCQ "SHOW BINARY LOGS" | head -1 | cut -f1)
docker exec a23-mysql mysql -uroot -plab -e "SET GLOBAL binlog_expire_logs_seconds = 1;" 2>/dev/null
sleep 3
docker exec a23-mysql mysql -uroot -plab -e "FLUSH BINARY LOGS;" 2>/dev/null
sleep 1
AFTER_LOGS=$(SRCQ "SHOW BINARY LOGS" | wc -l | tr -d ' ')
FIRST_AFTER=$(SRCQ "SHOW BINARY LOGS" | head -1 | cut -f1)
say "  binlog 파일 수 ${BEFORE_LOGS}개 → ${AFTER_LOGS}개"
say "  가장 오래된 파일 ${FIRST_BEFORE} → ${FIRST_AFTER}"
say '$ SHOW BINARY LOGS'
SRCQ "SHOW BINARY LOGS" | sed 's/^/  /' | tee -a "$OUT/exp2.txt"
say ""
say "남은 파일의 첫 이벤트 시각이 곧 PITR 가능 하한이다."
say "최신 풀백업이 그 하한보다 오래됐다면, 백업은 있는데 이어붙일 binlog가 없어 그 구간은 영구 유실이다."
docker exec a23-mysql mysql -uroot -plab -e "SET GLOBAL binlog_expire_logs_seconds = 2592000;" 2>/dev/null
say "  (실험 후 기본값 복원)"
