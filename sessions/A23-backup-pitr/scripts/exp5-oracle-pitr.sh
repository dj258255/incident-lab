#!/usr/bin/env bash
# Oracle 시점 복구(RMAN UNTIL TIME).
#
# 앞서 "라이선스가 걸려 이 랩에서 실행할 수 없다"고 적었던 것이 SQL Server 에서 틀렸고,
# Oracle 도 Database Free 23ai 가 무료 공개돼 있다. 아카이브 로그 모드 전환이 필요해
# 미뤄 두었는데, 그 전환 자체가 이 세션의 소재이기도 하다.
#
# MySQL·PostgreSQL·SQL Server 와 갈리는 자리를 본다.
#   1) 아카이브 로그 모드가 꺼져 있으면 시점 복구가 성립하지 않는다
#      켜려면 데이터베이스를 mount 상태로 내렸다 올려야 한다. 무중단이 아니다
#   2) UNTIL TIME 은 그 시각 직전까지 복구한다
#   3) RESETLOGS 로 열면 그 뒤로 인케네이션이 갈린다
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
PW='Lab_Passw0rd1'
SQL(){ docker exec -i a23-oracle bash -lc "sqlplus -S / as sysdba" <<EOF 2>&1
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200 TRIMSPOOL ON
$1
EOF
}
SQLU(){ docker exec -i a23-oracle bash -lc "sqlplus -S lab/$PW@FREEPDB1" <<EOF 2>&1
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
$1
EOF
}
RMAN(){ docker exec -i a23-oracle bash -lc "rman target /" <<EOF 2>&1
$1
EOF
}

# sqlplus 출력은 앞에 탭이 붙는다. 공백만 보는 패턴으로는 못 잡는다.
# 준비 확인. 질의문에 없는 문자열이 결과로 나와야 성공으로 본다.
# 원래 SELECT 'PING' 을 던지고 출력에서 PING 을 찾았는데, 실패하면 sqlplus 가
# 질의문을 그대로 echo 하므로 그 안의 PING 이 매칭됐다. 인스턴스가 안 떠 있는데도
# 준비된 것으로 판정해 그대로 진행했고, 실험 전체가 ORA-01034 로 채워졌다.
# 문자열을 이어 붙이면 질의문에는 PING 이 없고 결과에만 나온다.
# 질의가 답하는 것만으로는 부족하다. 기동 중에는 인스턴스가 SYSDBA 질의를 받으면서도
# 데이터베이스가 MOUNTED 상태일 수 있고, 그때 SHUTDOWN IMMEDIATE 를 던지면
# ORA-01154(database busy) 가 난다. 실제로 그렇게 났다.
# 열려 있는지(READ WRITE)까지 확인한다.
ready(){
  SQL "SELECT 'PI'||'NG' FROM dual;" | grep -q "PING" || return 1
  SQL "SELECT open_mode FROM v\$database;" | grep -q "READ WRITE"
}
for _ in $(seq 1 120); do ready && break; sleep 5; done
ready || { echo "중단: a23-oracle 이 쿼리를 받지 못합니다" >&2; SQL "SELECT 1 FROM dual;" | head -5 >&2; exit 2; }

{
echo "# Oracle 시점 복구(RMAN UNTIL TIME)"
SQL "SELECT banner FROM v\$version WHERE ROWNUM=1;" | tr -s ' ' | sed 's/^/# /'
echo

# ── 1) 아카이브 로그 모드 ────────────────────────────────────────────────
echo "## 1) 아카이브 로그 모드가 꺼져 있으면 시점 복구가 성립하지 않는다"
MODE=$(SQL "SELECT log_mode FROM v\$database;" | tr -d ' \r\n')
echo "  현재 log_mode = $MODE"
if [ "$MODE" != "ARCHIVELOG" ]; then
  echo "  → NOARCHIVELOG 다. 이 상태에서 RMAN 이 무엇을 말하는지 본다:"
  RMAN "RUN { SET UNTIL TIME \"SYSDATE-1/24\"; RESTORE DATABASE; }" \
    | grep -iE "RMAN-|ORA-" | head -3 | sed 's/^/    /'
  echo
  echo "  → 켠다. 데이터베이스를 내렸다 mount 로 올려야 한다. **무중단이 아니다.**"
  T0=$(date +%s)
  SQL "SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;" | grep -iE "ORA-|altered|Database" | head -6 | sed 's/^/    /'
  T1=$(date +%s)
  echo "    전환에 걸린 시간 = $((T1 - T0))초 (그동안 데이터베이스가 닫혀 있다)"
  echo "  전환 후 log_mode = $(SQL "SELECT log_mode FROM v\$database;" | tr -d ' \r\n')"
else
  echo "  → 이 이미지는 ARCHIVELOG 로 출고됩니다. 켜는 과정을 밟지 못했습니다."
  echo "    다른 엔진과 갈리는 자리는 남습니다. 끄고 켜려면 데이터베이스를 mount 로"
  echo "    내렸다 올려야 하고 그동안 닫혀 있습니다. MySQL 의 log-bin 과 PostgreSQL 의"
  echo "    archive_mode 도 재기동이 필요하지만, PostgreSQL 은 archive_mode 만 켜면"
  echo "    되는 데 비해 Oracle 은 데이터베이스를 mount 상태로 두는 단계가 더 있습니다."
fi
echo

# ── 2) 데이터 준비 ──────────────────────────────────────────────────────
echo "## 2) 데이터와 백업"
SQL "ALTER SESSION SET CONTAINER=FREEPDB1;
DROP USER lab CASCADE;
CREATE USER lab IDENTIFIED BY $PW;
GRANT CONNECT, RESOURCE, UNLIMITED TABLESPACE TO lab;" >/dev/null 2>&1
SQLU "CREATE TABLE sponsor (id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        live_id NUMBER, amount NUMBER, memo VARCHAR2(20));
INSERT INTO sponsor (live_id, amount, memo)
  SELECT MOD(LEVEL,100)+1, 1000, 'before' FROM dual CONNECT BY LEVEL <= 1000;
COMMIT;" >/dev/null 2>&1
echo "  행 수 = $(SQLU 'SELECT COUNT(*) FROM sponsor;' | tr -d ' \r\n')"
RMAN "BACKUP DATABASE PLUS ARCHIVELOG;" | grep -iE "Starting backup|Finished backup|RMAN-|ORA-" | head -4 | sed 's/^/  /'
echo

# ── 3) 사고 ─────────────────────────────────────────────────────────────
echo "## 3) 백업 뒤 정상 쓰기, 그다음 사고"
SQLU "INSERT INTO sponsor (live_id, amount, memo)
  SELECT MOD(LEVEL,100)+1, 2000, 'after-backup' FROM dual CONNECT BY LEVEL <= 500;
COMMIT;" >/dev/null 2>&1
SAFE_N=$(SQLU 'SELECT COUNT(*) FROM sponsor;' | tr -d ' \r\n')
# 목표 시각을 잡기 전에 로그를 떨어뜨린다. 안 그러면 그 시점의 리두가 아직
# 현재 로그에만 있어 UNTIL TIME 이 백업 시점까지만 되돌아간다.
SQL "ALTER SYSTEM ARCHIVE LOG CURRENT;" >/dev/null 2>&1
sleep 2
SAFE_TS=$(SQL "SELECT TO_CHAR(SYSTIMESTAMP,'YYYY-MM-DD HH24:MI:SS') FROM dual;" | tr -d '\r' | sed 's/^ *//;s/ *$//')
echo "  사고 직전 행 수 = $SAFE_N, 시각 = $SAFE_TS"
sleep 3
# sqlplus 는 한 줄에 두 문장을 두면 뒤엣것을 놓친다. 처음에 그렇게 두어
# DELETE 가 커밋되지 않았고 "사고 후 1500행"이라는 틀린 값이 나왔다.
SQLU "DELETE FROM sponsor WHERE memo = 'after-backup';
COMMIT;" >/dev/null 2>&1
ACC_N=$(SQLU 'SELECT COUNT(*) FROM sponsor;' | tr -d ' \r\n')
echo "  사고 후 행 수 = $ACC_N"
[ "${ACC_N:-0}" = "1000" ] || { echo "  중단: 사고가 만들어지지 않았습니다(기대 1000, 실제 ${ACC_N:-?})" >&2; exit 3; }
# 아카이브 로그를 강제로 떨어뜨려 복구 재료를 확보한다.
SQL "ALTER SYSTEM ARCHIVE LOG CURRENT;" >/dev/null 2>&1
RMAN "BACKUP ARCHIVELOG ALL;" | grep -iE "Finished backup|RMAN-|ORA-" | head -2 | sed 's/^/  /'
echo

# ── 4) UNTIL TIME 복구 ──────────────────────────────────────────────────
echo "## 4) RMAN UNTIL TIME 으로 사고 직전까지 되돌린다"
echo "  목표 시각 = $SAFE_TS"
RMAN "RUN {
  SHUTDOWN IMMEDIATE;
  STARTUP MOUNT;
  SET UNTIL TIME \"TO_DATE('$SAFE_TS','YYYY-MM-DD HH24:MI:SS')\";
  RESTORE DATABASE;
  RECOVER DATABASE;
  ALTER DATABASE OPEN RESETLOGS;
}" | grep -iE "Starting restore|Finished restore|Starting recover|Finished recover|RESETLOGS|RMAN-|ORA-" | head -10 | sed 's/^/    /'
sleep 5
SQL "ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;" >/dev/null 2>&1
FIN=$(SQLU 'SELECT COUNT(*) FROM sponsor;' | tr -d ' \r\n')
echo "  복구 후 행 수 = ${FIN:-조회실패}"
echo

echo "## 5) RESETLOGS 가 남긴 것"
SQL "SELECT incarnation#||' '||status||' '||resetlogs_change# FROM v\$database_incarnation ORDER BY incarnation#;" | sed 's/^/    /'
echo "  RESETLOGS 로 열면 인케네이션이 갈립니다. 그 시점 이후의 옛 아카이브 로그는"
echo "  새 인케네이션에 적용할 수 없고, 되돌아가려면 RESET DATABASE TO INCARNATION 이"
echo "  필요합니다. MySQL 과 PostgreSQL 에는 이 개념이 없습니다."
echo

echo "## 정리"
printf "  %-28s %s행\n" "사고 전" "$SAFE_N"
printf "  %-28s %s행\n" "사고 후" "$ACC_N"
printf "  %-28s %s행\n" "UNTIL TIME 복구 후" "${FIN:-?}"
echo "  각 조건 1회 실행입니다."
} 2>&1 | tee "$OUT/exp5-oracle-pitr.txt"
