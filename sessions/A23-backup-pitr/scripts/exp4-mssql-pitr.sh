#!/usr/bin/env bash
# SQL Server 시점 복구. 앞서 "라이선스가 걸려 이 랩에서 실행할 수 없다"고 적었는데
# 틀렸다. Developer 에디션이 mcr.microsoft.com/mssql/server 로 무료 공개돼 있고
# STOPAT 을 포함한 시점 복구가 그 에디션에 들어 있다. 그래서 잰다.
#
# MySQL 과 PostgreSQL 과 갈리는 자리를 본다.
#   1) 복구 모델이 FULL 이어야 로그 백업이 되고, 그래야 시점 복구가 가능하다
#      기본값이 데이터베이스마다 다르고 SIMPLE 이면 로그 백업 자체가 거부된다
#   2) STOPAT 은 그 시각까지 포함한다. 경계 포함 규칙이 PostgreSQL 의
#      recovery_target_inclusive 와 다르게 옵션이 아니라 고정이다
#   3) NORECOVERY 로 복원해야 뒤에 로그를 이어 붙일 수 있다. 빠뜨리면
#      데이터베이스가 열려 버리고 그 뒤 로그를 적용할 수 없다
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
PW='Lab_Passw0rd!'
Q(){  docker exec a23-mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$PW" -C -h -1 -W -Q "$1" 2>&1; }
# USE 를 쓰면 "Changed database context to ..." 가 첫 줄로 나와 값 파싱이 깨진다.
# -d 로 접속해 그 줄이 아예 없게 한다.
QD(){ docker exec a23-mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$PW" -C -h -1 -W -d "$1" -Q "$2" 2>&1; }
QE(){ docker exec a23-mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$PW" -C -Q "$1" 2>&1; }

for _ in $(seq 1 120); do [ "$(Q 'SELECT 1' | head -1)" = "1" ] && break; sleep 2; done
# 백업 디렉터리는 볼륨 마운트라 root 소유로 만들어진다. mssql(uid 10001)이 못 쓴다.
# A23 의 PostgreSQL 실험에서 /archive 로 같은 함정을 밟았다. 소유를 넘긴다.
docker exec -u root a23-mssql chown -R 10001:10001 /var/opt/mssql/backup 2>/dev/null || true
[ "$(Q 'SELECT 1' | head -1)" = "1" ] || { echo "중단: a23-mssql 이 쿼리를 받지 못합니다" >&2; exit 2; }

{
echo "# SQL Server 시점 복구(STOPAT)"
echo "# $(Q "SELECT @@VERSION" | head -1)"
echo "# 에디션: $(Q "SELECT SERVERPROPERTY('Edition')" | head -1)"
echo

echo "## 0) 준비"
Q "IF DB_ID('spoon') IS NOT NULL BEGIN ALTER DATABASE spoon SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE spoon; END" >/dev/null
Q "CREATE DATABASE spoon" >/dev/null
echo "  새 DB 의 기본 복구 모델 = $(Q "SELECT recovery_model_desc FROM sys.databases WHERE name='spoon'" | head -1)"
echo "  (model 데이터베이스를 물려받는다. SIMPLE 이면 로그 백업이 거부되어 시점 복구가 불가능하다)"
QD spoon "CREATE TABLE sponsor (id INT IDENTITY PRIMARY KEY, live_id INT, amount INT, memo VARCHAR(20))" >/dev/null
QD spoon "INSERT INTO sponsor (live_id, amount, memo) SELECT TOP 1000 (ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) % 100)+1, 1000, 'before' FROM sys.all_objects a CROSS JOIN sys.all_objects b" >/dev/null
echo "  행 수 = $(QD spoon "SELECT COUNT(*) FROM sponsor" | head -1)"

echo
echo "## 1) SIMPLE 에서 로그 백업을 시도한다"
Q "ALTER DATABASE spoon SET RECOVERY SIMPLE" >/dev/null
Q "BACKUP DATABASE spoon TO DISK='/var/opt/mssql/backup/full_simple.bak' WITH INIT" >/dev/null
QE "BACKUP LOG spoon TO DISK='/var/opt/mssql/backup/log_simple.trn' WITH INIT" | grep -iE "Msg|error|cannot|BACKUP LOG" | head -3 | sed 's/^/  /'
echo "  → SIMPLE 에서는 로그 백업이 거부되므로 시점 복구가 성립하지 않는다"

echo
echo "## 2) FULL 로 바꾸고 전체 백업"
Q "ALTER DATABASE spoon SET RECOVERY FULL" >/dev/null
echo "  복구 모델 = $(Q "SELECT recovery_model_desc FROM sys.databases WHERE name='spoon'" | head -1)"
QE "BACKUP DATABASE spoon TO DISK='/var/opt/mssql/backup/full.bak' WITH INIT" | grep -iE "^Msg" | head -2 | sed 's/^/  /'
docker exec a23-mssql test -s /var/opt/mssql/backup/full.bak || { echo "중단: 전체 백업 파일이 만들어지지 않았습니다" >&2; exit 3; }
echo "  전체 백업 완료 (행 수 $(QD spoon "SELECT COUNT(*) FROM sponsor" | head -1))"

echo
echo "## 3) 백업 뒤 정상 쓰기, 그다음 사고"
QD spoon "INSERT INTO sponsor (live_id, amount, memo) SELECT TOP 500 (ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) % 100)+1, 2000, 'after-backup' FROM sys.all_objects a CROSS JOIN sys.all_objects b" >/dev/null
SAFE_N=$(QD spoon "SELECT COUNT(*) FROM sponsor" | head -1)
# 사고 직전 시각. SQL Server 는 서버 시각을 쓰는 것이 안전하다.
SAFE_TS=$(Q "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)" | head -1)
echo "  사고 직전 행 수 = ${SAFE_N}, 시각 = $SAFE_TS"
sleep 2
QD spoon "DELETE FROM sponsor WHERE memo = 'after-backup'" >/dev/null
ACC_TS=$(Q "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)" | head -1)
ACC_N=$(QD spoon "SELECT COUNT(*) FROM sponsor" | head -1)
echo "  사고 후 행 수 = ${ACC_N}  (${SAFE_N}에서 $((SAFE_N - ACC_N))건 사라짐)"
echo "  사고 시각 = $ACC_TS"
QE "BACKUP LOG spoon TO DISK='/var/opt/mssql/backup/log.trn' WITH INIT" | grep -iE "^Msg" | head -2 | sed 's/^/  /'
docker exec a23-mssql test -s /var/opt/mssql/backup/log.trn || { echo "중단: 로그 백업 파일이 만들어지지 않았습니다" >&2; exit 3; }
echo "  로그 백업 완료 ($(docker exec a23-mssql stat -c %s /var/opt/mssql/backup/log.trn 2>/dev/null)바이트)"

restore() { # $1=라벨 $2=STOPAT 시각 또는 빈 문자열 $3=첫 복원에 NORECOVERY 를 줄지
  local label="$1" ts="$2" norec="$3" db="r_$1"
  Q "IF DB_ID('$db') IS NOT NULL BEGIN ALTER DATABASE $db SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE $db; END" >/dev/null
  local first="RESTORE DATABASE $db FROM DISK='/var/opt/mssql/backup/full.bak'
    WITH MOVE 'spoon' TO '/var/opt/mssql/data/$db.mdf',
         MOVE 'spoon_log' TO '/var/opt/mssql/data/${db}_log.ldf', REPLACE"
  if [ "$norec" = "yes" ]; then first="$first, NORECOVERY"; fi
  QE "$first" | grep -iE "^Msg|processed" | tail -1 | sed 's/^/    /'
  if [ -n "$ts" ]; then
    QE "RESTORE LOG $db FROM DISK='/var/opt/mssql/backup/log.trn' WITH STOPAT='$ts', RECOVERY" \
      | grep -iE "^Msg|processed|terminated|cannot" | head -2 | sed 's/^/    /'
  elif [ "$norec" = "yes" ]; then
    QE "RESTORE DATABASE $db WITH RECOVERY" | grep -iE "^Msg|RESTORE" | head -1 | sed 's/^/    /'
  fi
  local n st
  st=$(Q "SELECT state_desc FROM sys.databases WHERE name='$db'" | head -1)
  n=$(Q "USE $db; SELECT COUNT(*) FROM sponsor" 2>/dev/null | head -1)
  echo "    상태 $st, 행 수 ${n:-조회불가}"
}

echo
echo "## 4) 복구 A: NORECOVERY 를 빠뜨리고 전체 백업만 복원한다"
restore a "" "no"
echo "  → 백업 시점(1000행)으로 열렸고, 이 뒤에 로그를 이어 붙일 수 없다"
echo "    로그 적용 시도:"
QE "RESTORE LOG r_a FROM DISK='/var/opt/mssql/backup/log.trn' WITH STOPAT='$SAFE_TS', RECOVERY" | grep -iE "^Msg" | head -2 | sed 's/^/      /'

echo
echo "## 5) 복구 B: NORECOVERY 로 복원한 뒤 STOPAT 을 사고 직전으로"
restore b "$SAFE_TS" "yes"

echo
echo "## 6) 복구 C: STOPAT 을 사고 시각으로 (경계 포함 규칙)"
restore c "$ACC_TS" "yes"

echo
echo "## 정리"
printf "  %-40s %s행\n" "사고 전" "$SAFE_N"
printf "  %-40s %s행\n" "사고 후" "$ACC_N"
echo "  복구 A NORECOVERY 누락  → 로그를 이어 붙일 수 없음"
printf "  %-40s %s행\n" "복구 B STOPAT=사고 직전" "$(QD r_b "SELECT COUNT(*) FROM sponsor" 2>/dev/null | head -1)"
printf "  %-40s %s행\n" "복구 C STOPAT=사고 시각" "$(QD r_c "SELECT COUNT(*) FROM sponsor" 2>/dev/null | head -1)"
echo
echo "  각 조건 1회 실행입니다."
} 2>&1 | tee "$OUT/exp4-mssql-pitr.txt"
