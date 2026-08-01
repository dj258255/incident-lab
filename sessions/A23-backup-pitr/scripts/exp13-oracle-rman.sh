#!/usr/bin/env bash
# Oracle 쪽을 판정 중심으로 채운다.
#
# 이 세션의 Oracle 은 UNTIL TIME 을 1회 돌린 수준이라 표면이라는 지적을 받았다.
# 반대로 아카이브 모드 전환 왕복은 3회나 쟀다. 비중이 반대라는 것도 맞는 지적이다.
#
# 시간은 안 잰다. 이 컨테이너는 ARM 에뮬레이션이라 절대값이 이 호스트의 것도 아니다.
# 대신 **판정**을 반복해서 잰다. 규모 곡선에서 확인했듯 판정은 규모와 환경을 덜 탄다.
#   1) UNTIL TIME 이 사고 직전 시점의 행 수를 되살리는가
#   2) UNTIL TIME 을 사고 이후로 주면 사고까지 함께 복구되는가
#   3) RESETLOGS 로 열면 인케네이션이 갈리고, 그 뒤 옛 시점으로 못 가는가
#   4) 그 상태에서 RESET DATABASE TO INCARNATION 으로 되돌아갈 수 있는가
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
C=a23-oracle; ROUNDS=${ROUNDS:-3}

# RESETLOGS 로 열면 CDB 만 열리고 PDB 는 MOUNTED 로 남는다. 그 상태에서 조회하면
# ORA-01109(database not open)가 나고, 다음 회차의 준비까지 연쇄로 실패한다.
# 열고 나서 **실제로 READ WRITE 인지 확인**한 뒤 진행한다.
open_pdb(){
  local i
  for i in $(seq 1 20); do
    SQL "ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;" >/dev/null 2>&1
    SQL "SELECT open_mode FROM v\$pdbs WHERE name='FREEPDB1';" | tr -d ' \r\n' | grep -q "READWRITE" && return 0
    sleep 3
  done
  return 1
}
SQL(){ docker exec -i "$C" bash -lc "sqlplus -S / as sysdba" <<EOF 2>&1
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 300 TRIMSPOOL ON
$1
EOF
}
RMAN(){ docker exec -i "$C" bash -lc "rman target /" <<EOF 2>&1
$1
EOF
}
ready(){ SQL "SELECT 'PI'||'NG' FROM dual;" | grep -q PING && SQL "SELECT open_mode FROM v\$database;" | grep -q "READ WRITE"; }
for _ in $(seq 1 200); do ready && break; sleep 5; done
ready || { echo "중단: a23-oracle 이 안 뜹니다" >&2; exit 2; }

# 아카이브 로그 모드가 아니면 PITR 자체가 성립하지 않는다
MODE=$(SQL "SELECT log_mode FROM v\$database;" | tr -d ' \r\n')
if [ "$MODE" != "ARCHIVELOG" ]; then
  echo "  아카이브 로그 모드가 $MODE 입니다. ARCHIVELOG 로 바꿉니다"
  SQL "SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;" >/dev/null 2>&1
  SQL "ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;" >/dev/null 2>&1
  MODE=$(SQL "SELECT log_mode FROM v\$database;" | tr -d ' \r\n')
  [ "$MODE" = "ARCHIVELOG" ] || { echo "중단: ARCHIVELOG 전환 실패($MODE)" >&2; exit 2; }
fi

num(){ echo "$1" | tr -d ' \r' | grep -E '^[0-9]+$' | head -1; }
# 이 이미지는 멀티테넌트다. CDB 루트에서 CREATE USER 하면 ORA-65096 으로
# C## 접두사를 요구한다. 업무 테이블은 PDB 안에 두는 것이 실제 구성이기도 하니
# 세션을 FREEPDB1 로 옮겨 만든다. RMAN 의 CDB 복구가 그 PDB 데이터도 함께 되돌린다.
PSQL(){ SQL "ALTER SESSION SET CONTAINER=FREEPDB1;
$1"; }
rows(){ num "$(PSQL "SELECT COUNT(*) FROM sysbak.t;")"; }

echo "run,phase,rows,verdict" > "$OUT/oracle-rman.csv"
{
echo "# Oracle RMAN 시점 복구를 판정 중심으로 ${ROUNDS}회 반복"
SQL "SELECT banner FROM v\$version WHERE ROWNUM=1;" | tr -s ' ' | sed 's/^/# /'
echo "# 시간은 안 적습니다. ARM 에뮬레이션이라 절대값이 이 호스트의 것이 아닙니다."
echo "# 갈리는 것은 판정이고, 판정은 회차마다 같아야 인용할 수 있습니다."
echo
printf "  %5s %14s %14s %14s %14s\n" "회차" "사고전 복구" "사고후 복구" "옛시점 재복구" "인케네이션 복귀"
STABLE=1; PREV=""; VALID=0
for r in $(seq 1 "$ROUNDS"); do
  # 준비. 매 회차 새로 만든다.
  PSQL "DROP USER sysbak CASCADE;" >/dev/null 2>&1
  MK=$(PSQL "CREATE USER sysbak IDENTIFIED BY lab QUOTA UNLIMITED ON USERS;
GRANT CREATE SESSION, CREATE TABLE TO sysbak;
CREATE TABLE sysbak.t (id NUMBER PRIMARY KEY, v NUMBER);")
  echo "$MK" | grep -qi "^ORA-" && { echo "  회차 $r: 준비 실패 $(echo "$MK" | grep -m1 '^ORA-')"; continue; }
  PSQL "BEGIN FOR i IN 1..500 LOOP INSERT INTO sysbak.t VALUES (i, i); END LOOP; COMMIT; END;
/" >/dev/null 2>&1
  BEFORE=$(rows)
  [ "${BEFORE:-0}" -ne 500 ] && { echo "  회차 $r: 적재가 ${BEFORE:-0}행(기대 500). 버립니다"; continue; }

  RMAN "BACKUP DATABASE PLUS ARCHIVELOG;" >/dev/null 2>&1
  PSQL "BEGIN FOR i IN 501..700 LOOP INSERT INTO sysbak.t VALUES (i, i); END LOOP; COMMIT; END;
/" >/dev/null 2>&1
  # **백업 뒤에 생긴 리두를 아카이브해야 그 시점까지 복구할 수 있다.**
  # 1차 시도에서 사고 전 복구가 500행(백업 시점)에 멈춘 이유가 이것이다.
  SQL "ALTER SYSTEM ARCHIVE LOG CURRENT;" >/dev/null 2>&1
  SAFE_N=$(rows)
  SAFE_T=$(SQL "SELECT TO_CHAR(SYSDATE,'YYYY-MM-DD HH24:MI:SS') FROM dual;" | tr -d '\r' | xargs)
  sleep 12   # 초 단위 경계를 확실히 넘긴다
  PSQL "DELETE FROM sysbak.t WHERE id > 500; COMMIT;" >/dev/null 2>&1
  SQL "ALTER SYSTEM ARCHIVE LOG CURRENT;" >/dev/null 2>&1
  AFTER=$(rows)
  ACC_T=$(SQL "SELECT TO_CHAR(SYSDATE,'YYYY-MM-DD HH24:MI:SS') FROM dual;" | tr -d '\r' | xargs)

  # 1) 사고 직전 시점으로 복구
  RMAN "RUN { SHUTDOWN IMMEDIATE; STARTUP MOUNT;
  SET UNTIL TIME \"TO_DATE('$SAFE_T','YYYY-MM-DD HH24:MI:SS')\";
  RESTORE DATABASE; RECOVER DATABASE; ALTER DATABASE OPEN RESETLOGS; }" >/dev/null 2>&1
  open_pdb || echo "  회차 $r: PDB 가 안 열립니다(1단계)"
  R1=$(rows); V1=$([ "${R1:-0}" = "${SAFE_N:-x}" ] && echo 통과 || echo "걸림(${R1:-?})")

  # 2) 사고 이후 시점으로 복구하면 사고까지 함께 온다
  RMAN "RUN { SHUTDOWN IMMEDIATE; STARTUP MOUNT;
  SET UNTIL TIME \"TO_DATE('$ACC_T','YYYY-MM-DD HH24:MI:SS')\";
  RESTORE DATABASE; RECOVER DATABASE; ALTER DATABASE OPEN RESETLOGS; }" >/dev/null 2>&1
  open_pdb || echo "  회차 $r: PDB 가 안 열립니다(2단계)"
  R2=$(rows); V2=$([ "${R2:-0}" = "${AFTER:-x}" ] && echo 통과 || echo "걸림(${R2:-?})")

  # 3) RESETLOGS 로 인케네이션이 갈린 뒤 옛 시점으로 다시 가려 하면
  E3=$(RMAN "RUN { SHUTDOWN IMMEDIATE; STARTUP MOUNT;
  SET UNTIL TIME \"TO_DATE('$SAFE_T','YYYY-MM-DD HH24:MI:SS')\";
  RESTORE DATABASE; }" | grep -cE "RMAN-2004[0-9]|RMAN-06004|RMAN-20207|not found")
  V3=$([ "${E3:-0}" -gt 0 ] && echo "막힘" || echo "안막힘")

  # 4) 인케네이션을 되돌리면 갈 수 있다
  INC=$(RMAN "LIST INCARNATION OF DATABASE;" | awk '/FREE/{print $2}' | head -1)
  E4=$(RMAN "RESET DATABASE TO INCARNATION ${INC:-1};" | grep -ciE "RMAN-[0-9]+")
  V4=$([ "${E4:-0}" -eq 0 ] && echo 통과 || echo 걸림)

  SQL "ALTER DATABASE OPEN RESETLOGS;" >/dev/null 2>&1
  open_pdb || echo "  회차 $r: PDB 가 안 열립니다(정리 단계)"
  printf "  %5s %14s %14s %14s %14s\n" "$r" "$V1" "$V2" "$V3" "$V4"
  echo "$r,until_safe,${R1:-0},$V1" >> "$OUT/oracle-rman.csv"
  echo "$r,until_after,${R2:-0},$V2" >> "$OUT/oracle-rman.csv"
  echo "$r,old_after_resetlogs,0,$V3" >> "$OUT/oracle-rman.csv"
  echo "$r,reset_incarnation,0,$V4" >> "$OUT/oracle-rman.csv"
  CUR="$V1|$V2|$V3|$V4"
  [ -n "$PREV" ] && [ "$CUR" != "$PREV" ] && STABLE=0
  PREV="$CUR"; VALID=$((VALID+1))
done
echo
if [ "$VALID" -lt 2 ]; then
  echo "  **유효 회차가 ${VALID}개뿐입니다. 반복했다고 말할 수 없습니다.**"
  echo "  1회 값과 다를 바 없으므로 이 표는 인용하면 안 됩니다."
elif [ "$STABLE" = 1 ]; then
  echo "  **${VALID}회차 판정이 모두 같습니다.** 시간을 못 재도 이 네 판정은 인용할 수 있습니다."
else
  echo "  **회차마다 판정이 갈립니다. 인용하면 안 됩니다.**"
fi
} 2>&1 | tee "$OUT/exp13-oracle-rman.txt"
