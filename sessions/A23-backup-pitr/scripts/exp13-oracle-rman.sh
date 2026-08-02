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
if ! ready; then
  # 앞 회차가 RESETLOGS 뒤에 안 열고 끝나면 MOUNTED 에 남는다. 그 상태로 다음 실행을
  # 시작하면 "안 뜹니다"로 중단되고, 원인이 컨테이너가 아니라 앞 실행의 뒷정리다.
  # 스스로 회복시킨다.
  echo "  READ WRITE 가 아닙니다($(SQL "SELECT open_mode FROM v\$database;" | tr -d ' \r\n')). 여는 중"
  SQL "ALTER DATABASE OPEN;" >/dev/null 2>&1
  ready || SQL "ALTER DATABASE OPEN RESETLOGS;" >/dev/null 2>&1
  ready || { SQL "SHUTDOWN ABORT;
STARTUP;" >/dev/null 2>&1; }
  # 그래도 안 열리면 데이터파일이 앞 회차의 불완전 복구 상태에 걸려 있는 것이다.
  # 전체 복원으로 되돌린다. 앞 회차가 남긴 상태 때문에 다음 실행이 통째로
  # 중단되는 것을 여러 번 겪었다.
  if ! ready; then
    # ORA-01190 으로 막히는 경우가 있다. 컨트롤 파일과 데이터 파일의 계보가 어긋난
    # 상태이고, 데이터 파일만 복원해서는 안 풀린다. 컨트롤 파일부터 되돌린다.
    echo "  컨트롤 파일부터 전체 복원으로 되돌리는 중"
    RMAN "SHUTDOWN IMMEDIATE;
STARTUP NOMOUNT;
RESTORE CONTROLFILE FROM AUTOBACKUP;
ALTER DATABASE MOUNT;
RESTORE DATABASE;
RECOVER DATABASE;
ALTER DATABASE OPEN RESETLOGS;" >/dev/null 2>&1
    open_pdb >/dev/null 2>&1 || true
  fi
  for _ in $(seq 1 40); do ready && break; sleep 5; done
fi
ready || { echo "중단: a23-oracle 을 READ WRITE 로 못 엽니다" >&2; exit 2; }
open_pdb >/dev/null 2>&1 || true

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
# PDB 안에 두었더니 RESTORE/RECOVER 뒤 PDB 가 MOUNTED 로 남아 조회가 ORA-01109 로
# 막히고, 그 상태가 다음 회차의 준비까지 연쇄로 끌고 갔다. 복구 경로에서 PDB 를 빼고
# CDB 루트에 둔다. 멀티테넌트 루트는 공용 사용자에 C## 접두사를 요구하므로 그 이름을 쓴다.
# 이 실험이 보려는 것은 시점 복구의 판정이지 멀티테넌트 구조가 아니다.
PSQL(){ SQL "$1"; }
rows(){ num "$(SQL "SELECT COUNT(*) FROM c##sysbak.t;")"; }

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
  SQL "DROP USER c##sysbak CASCADE;" >/dev/null 2>&1
  MK=$(SQL "CREATE USER c##sysbak IDENTIFIED BY lab QUOTA UNLIMITED ON USERS CONTAINER=ALL;
GRANT CREATE SESSION, CREATE TABLE TO c##sysbak CONTAINER=ALL;
CREATE TABLE c##sysbak.t (id NUMBER PRIMARY KEY, v NUMBER);")
  echo "$MK" | grep -qi "^ORA-" && { echo "  회차 $r: 준비 실패 $(echo "$MK" | grep -m1 '^ORA-')"; continue; }
  SQL "BEGIN FOR i IN 1..500 LOOP INSERT INTO c##sysbak.t VALUES (i, i); END LOOP; COMMIT; END;
/" >/dev/null 2>&1
  BEFORE=$(rows)
  [ "${BEFORE:-0}" -ne 500 ] && { echo "  회차 $r: 적재가 ${BEFORE:-0}행(기대 500). 버립니다"; continue; }

  # 회차마다 **현재 인케네이션에서** 새로 백업한다. 앞 회차의 RESETLOGS 로 인케네이션이
  # 갈린 상태에서 옛 백업을 쓰려 하면 RMAN-20207 로 막힌다.
  BASE_INC=$(RMAN "LIST INCARNATION OF DATABASE;" | awk '/CURRENT/{print $2}' | tail -1)
  RMAN "BACKUP DATABASE PLUS ARCHIVELOG;" >/dev/null 2>&1
  SQL "BEGIN FOR i IN 501..700 LOOP INSERT INTO c##sysbak.t VALUES (i, i); END LOOP; COMMIT; END;
/" >/dev/null 2>&1
  # **RMAN 의 SET UNTIL TIME 은 초 단위이고 그 시각을 포함하지 않는다.**
  # 커밋과 같은 초에 시각을 찍으면 그 커밋이 빠져서 백업 시점 그대로가 나온다.
  # 사고 전 복구가 계속 500행(기대 700)이던 이유가 이것이었다. 같은 조건에서
  # SET UNTIL SCN 으로 주면 700행이 나오는 것으로 확인했다.
  # 커밋 뒤 몇 초 지난 시각을 잡는다.
  sleep 4
  SQL "ALTER SYSTEM ARCHIVE LOG CURRENT;" >/dev/null 2>&1
  SAFE_N=$(rows)
  SAFE_T=$(SQL "SELECT TO_CHAR(SYSDATE,'YYYY-MM-DD HH24:MI:SS') FROM dual;" | tr -d '\r' | xargs)
  SAFE_SCN=$(num "$(SQL "SELECT current_scn FROM v\$database;")")
  sleep 12   # 초 단위 경계를 확실히 넘긴다
  SQL "DELETE FROM c##sysbak.t WHERE id > 500; COMMIT;" >/dev/null 2>&1
  SQL "ALTER SYSTEM ARCHIVE LOG CURRENT;" >/dev/null 2>&1
  AFTER=$(rows)
  ACC_T=$(SQL "SELECT TO_CHAR(SYSDATE,'YYYY-MM-DD HH24:MI:SS') FROM dual;" | tr -d '\r' | xargs)

  # 1) 사고 직전 시점으로 복구
  RMAN "RUN { SHUTDOWN IMMEDIATE; STARTUP MOUNT;
  SET UNTIL TIME \"TO_DATE('$SAFE_T','YYYY-MM-DD HH24:MI:SS')\";
  RESTORE DATABASE; RECOVER DATABASE; ALTER DATABASE OPEN RESETLOGS; }" >/dev/null 2>&1
  open_pdb >/dev/null 2>&1 || true
  R1=$(rows); V1=$([ "${R1:-0}" = "${SAFE_N:-x}" ] && echo 통과 || echo "걸림(${R1:-?})")

  # 2) 사고 이후 시점으로 복구하면 사고까지 함께 온다
  #    **앞 단계의 RESETLOGS 로 인케네이션이 갈렸으므로 먼저 되돌린다.**
  #    안 되돌리면 ACC_T 가 새 인케네이션의 RESETLOGS 시각보다 앞이라 RMAN-20207 이
  #    나고, 그 실패가 다음 단계까지 연쇄로 끌고 간다. 1차 설계가 그랬다.
  RMAN "SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
RESET DATABASE TO INCARNATION ${BASE_INC:-1};" >/dev/null 2>&1
  RMAN "RUN { SHUTDOWN IMMEDIATE; STARTUP MOUNT;
  SET UNTIL TIME \"TO_DATE('$ACC_T','YYYY-MM-DD HH24:MI:SS')\";
  RESTORE DATABASE; RECOVER DATABASE; ALTER DATABASE OPEN RESETLOGS; }" >/dev/null 2>&1
  open_pdb >/dev/null 2>&1 || true
  R2=$(rows); V2=$([ "${R2:-0}" = "${AFTER:-x}" ] && echo 통과 || echo "걸림(${R2:-?})")

  # 3) RESETLOGS 로 인케네이션이 갈린 뒤 옛 시점으로 다시 가려 하면
  E3=$(RMAN "RUN { SHUTDOWN IMMEDIATE; STARTUP MOUNT;
  SET UNTIL TIME \"TO_DATE('$SAFE_T','YYYY-MM-DD HH24:MI:SS')\";
  RESTORE DATABASE; }" | grep -cE "RMAN-2004[0-9]|RMAN-06004|RMAN-20207|not found")
  V3=$([ "${E3:-0}" -gt 0 ] && echo "막힘" || echo "안막힘")

  # 4) 회차 시작 인케네이션으로 되돌린 뒤 같은 시점으로 다시 갈 수 있는가
  #    3) 이 막힌 상태에서 출발한다. 되돌리는 것이 그 막힘을 푸는가가 질문이다.
  R4=$(RMAN "SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
RESET DATABASE TO INCARNATION ${BASE_INC:-1};
RUN { SET UNTIL TIME \"TO_DATE('$SAFE_T','YYYY-MM-DD HH24:MI:SS')\";
  RESTORE DATABASE; RECOVER DATABASE; ALTER DATABASE OPEN RESETLOGS; }")
  E4=$(echo "$R4" | grep -c "database reset to incarnation")
  open_pdb >/dev/null 2>&1 || true
  R4N=$(rows)
  V4=$([ "${E4:-0}" -gt 0 ] && [ "${R4N:-0}" = "${SAFE_N:-x}" ] && echo 통과 || echo "걸림(${R4N:-?})")

  SQL "ALTER DATABASE OPEN RESETLOGS;" >/dev/null 2>&1
  open_pdb >/dev/null 2>&1 || true
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
