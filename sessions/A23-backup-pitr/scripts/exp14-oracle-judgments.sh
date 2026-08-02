#!/usr/bin/env bash
# Oracle 시점 복구의 네 판정을 회차마다 같은 기준점에서 잰다.
#
# exp13 은 한 회차 안에서 네 판정을 이어 돌렸는데, 판정마다 들어가는
# ALTER DATABASE OPEN RESETLOGS 가 **인케네이션이라는 전역 상태**를 바꾼다.
# 앞 판정이 만든 계보 때문에 다음 판정의 기준점이 사라져서 유효 회차가 1개를 못 넘었다.
#
# 여기서는 사고 직후 상태의 데이터 파일과 컨트롤 파일을 **파일로 떠 두고**
# 판정마다 그 스냅숏으로 되돌린다. RMAN 의 인케네이션 관리에 기대지 않으므로
# 판정 사이에 상태가 새지 않는다. 아카이브 로그는 별도 경로라 그대로 남는다.
#
# 시간은 안 잰다. ARM 에뮬레이션이라 절대값이 이 호스트의 것이 아니다.
# 갈리는 것은 판정이고, 판정이 회차마다 같아야 인용할 수 있다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
C=a23-oracle; ROUNDS=${ROUNDS:-3}
DATA=/opt/oracle/oradata/FREE
SNAP=/opt/oracle/snap

SQL(){ docker exec -i "$C" bash -lc "sqlplus -S / as sysdba" <<EOF 2>&1
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 300 TRIMSPOOL ON
$1
EOF
}
RMAN(){ docker exec -i "$C" bash -lc "rman target /" <<EOF 2>&1
$1
EOF
}
num(){ echo "$1" | tr -d ' \r' | grep -E '^[0-9]+$' | head -1; }
ready(){ SQL "SELECT open_mode FROM v\$database;" | tr -d ' \r\n' | grep -q "READWRITE"; }
rows(){ num "$(SQL "SELECT COUNT(*) FROM c##sysbak.t;")"; }

# 사고 직후 상태로 되돌린다. 컨트롤 파일이 함께 돌아오므로 인케네이션 시야도 그때로 간다.
restore_snap(){
  SQL "SHUTDOWN IMMEDIATE;" >/dev/null 2>&1
  docker exec "$C" bash -lc "rm -rf $DATA && cp -a $SNAP $DATA" >/dev/null 2>&1
  SQL "STARTUP MOUNT;" >/dev/null 2>&1
}

# 목표 시점으로 복구하고 연다. 성공하면 행 수를, 막히면 에러 코드를 돌려준다.
recover_to(){ # $1 = SET UNTIL 절
  local o
  o=$(RMAN "RUN { SET $1; RESTORE DATABASE; RECOVER DATABASE; ALTER DATABASE OPEN RESETLOGS; }")
  local err; err=$(echo "$o" | grep -oE "RMAN-2020[0-9]|ORA-0[0-9]{4}" | head -1)
  if ready; then echo "OK|$(rows)"; else echo "ERR|${err:-알수없음}"; fi
}

for _ in $(seq 1 120); do ready && break; sleep 5; done
if ! ready; then
  echo "  READ WRITE 가 아닙니다. 컨트롤 파일부터 전체 복원으로 되돌립니다"
  RMAN "SHUTDOWN IMMEDIATE;
STARTUP NOMOUNT;
RESTORE CONTROLFILE FROM AUTOBACKUP;
ALTER DATABASE MOUNT;
RESTORE DATABASE;
RECOVER DATABASE;
ALTER DATABASE OPEN RESETLOGS;" >/dev/null 2>&1
  for _ in $(seq 1 60); do ready && break; sleep 5; done
fi
ready || { echo "중단: a23-oracle 을 READ WRITE 로 못 엽니다" >&2; exit 2; }

echo "run,judgment,detail,verdict" > "$OUT/oracle-judgments.csv"
{
echo "# Oracle 시점 복구의 네 판정을 ${ROUNDS}회 반복"
SQL "SELECT banner FROM v\$version WHERE ROWNUM=1;" | tr -s ' ' | sed 's/^/# /'
echo "# 판정마다 사고 직후 스냅숏으로 되돌려 같은 기준점에서 잽니다."
echo "# 시간은 안 적습니다. ARM 에뮬레이션이라 절대값이 이 호스트의 것이 아닙니다."
echo
printf "  %5s %-22s %-22s %-16s %s\n" "회차" "1 사고직전" "2 사고이후" "3 RESETLOGS뒤" "4 스냅숏복귀"
STABLE=1; PREV=""; VALID=0
for r in $(seq 1 "$ROUNDS"); do
  # 준비. 500행 → 백업 → 200행 추가 → 사고 직전 시각 → 삭제 → 사고 직후
  SQL "DROP USER c##sysbak CASCADE;" >/dev/null 2>&1
  MK=$(SQL "CREATE USER c##sysbak IDENTIFIED BY lab QUOTA UNLIMITED ON USERS CONTAINER=ALL;
GRANT CREATE SESSION, CREATE TABLE TO c##sysbak CONTAINER=ALL;
CREATE TABLE c##sysbak.t (id NUMBER PRIMARY KEY, v NUMBER);")
  echo "$MK" | grep -qi "^ORA-" && { echo "  회차 $r: 준비 실패 $(echo "$MK" | grep -m1 '^ORA-')"; continue; }
  SQL "BEGIN
  FOR i IN 1..500 LOOP INSERT INTO c##sysbak.t VALUES (i,i); END LOOP;
  COMMIT;
END;
/" >/dev/null 2>&1
  BASE=$(rows)
  [ "${BASE:-0}" -ne 500 ] && { echo "  회차 $r: 적재 ${BASE:-0}행(기대 500). 버립니다"; continue; }

  RMAN "BACKUP DATABASE PLUS ARCHIVELOG;" >/dev/null 2>&1
  SQL "BEGIN
  FOR i IN 501..700 LOOP INSERT INTO c##sysbak.t VALUES (i,i); END LOOP;
  COMMIT;
END;
/" >/dev/null 2>&1
  # **SET UNTIL TIME 은 초 단위이고 그 시각을 포함하지 않는다.** 커밋과 같은 초에
  # 시각을 찍으면 그 커밋이 빠져서 백업 시점 그대로가 나온다. 4초를 둔다.
  sleep 4
  SQL "ALTER SYSTEM ARCHIVE LOG CURRENT;" >/dev/null 2>&1
  SAFE_N=$(rows)
  SAFE_T=$(SQL "SELECT TO_CHAR(SYSDATE,'YYYY-MM-DD HH24:MI:SS') FROM dual;" | tr -d '\r' | xargs)
  [ "${SAFE_N:-0}" -ne 700 ] && { echo "  회차 $r: 사고 전이 ${SAFE_N:-0}행(기대 700). 버립니다"; continue; }

  sleep 4
  SQL "BEGIN
  DELETE FROM c##sysbak.t WHERE id > 500;
  COMMIT;
END;
/" >/dev/null 2>&1
  sleep 4
  SQL "ALTER SYSTEM ARCHIVE LOG CURRENT;" >/dev/null 2>&1
  AFTER=$(rows)
  ACC_T=$(SQL "SELECT TO_CHAR(SYSDATE,'YYYY-MM-DD HH24:MI:SS') FROM dual;" | tr -d '\r' | xargs)

  # 사고 직후 상태를 파일로 뜬다. 이것이 네 판정의 공통 기준점이다.
  SQL "SHUTDOWN IMMEDIATE;" >/dev/null 2>&1
  docker exec "$C" bash -lc "rm -rf $SNAP && cp -a $DATA $SNAP" >/dev/null 2>&1
  SNAPOK=$(docker exec "$C" bash -lc "[ -f $SNAP/system01.dbf ] && echo yes" 2>/dev/null | tr -d ' \r\n')
  [ "$SNAPOK" != yes ] && { echo "  회차 $r: 스냅숏 실패. 버립니다"; SQL "STARTUP;" >/dev/null 2>&1; continue; }

  # 1) 사고 직전 시점으로
  SQL "STARTUP MOUNT;" >/dev/null 2>&1
  IFS='|' read -r K1 D1 <<< "$(recover_to "UNTIL TIME \"TO_DATE('$SAFE_T','YYYY-MM-DD HH24:MI:SS')\"")"
  V1=$([ "$K1" = OK ] && [ "$D1" = "$SAFE_N" ] && echo 통과 || echo "걸림($D1)")

  # 3) **여기서 먼저 3번을 잰다.** 방금 RESETLOGS 로 열었으므로 그 앞으로 못 가야 한다.
  #    스냅숏으로 되돌리기 전에 재야 의미가 있다.
  SQL "SHUTDOWN IMMEDIATE;" >/dev/null 2>&1
  SQL "STARTUP MOUNT;" >/dev/null 2>&1
  IFS='|' read -r K3 D3 <<< "$(recover_to "UNTIL TIME \"TO_DATE('$SAFE_T','YYYY-MM-DD HH24:MI:SS')\"")"
  V3=$([ "$K3" = ERR ] && echo "막힘($D3)" || echo "안막힘($D3)")

  # 2) 사고 이후 시점으로. 스냅숏으로 되돌려 기준점을 맞춘다.
  restore_snap
  IFS='|' read -r K2 D2 <<< "$(recover_to "UNTIL TIME \"TO_DATE('$ACC_T','YYYY-MM-DD HH24:MI:SS')\"")"
  V2=$([ "$K2" = OK ] && [ "$D2" = "$AFTER" ] && echo 통과 || echo "걸림($D2)")

  # 4) 3번이 막힌 상태에서 스냅숏으로 되돌리면 다시 갈 수 있는가
  restore_snap
  IFS='|' read -r K4 D4 <<< "$(recover_to "UNTIL TIME \"TO_DATE('$SAFE_T','YYYY-MM-DD HH24:MI:SS')\"")"
  V4=$([ "$K4" = OK ] && [ "$D4" = "$SAFE_N" ] && echo 통과 || echo "걸림($D4)")

  printf "  %5s %-22s %-22s %-16s %s\n" "$r" "$V1" "$V2" "$V3" "$V4"
  for pair in "until_safe:$V1" "until_after:$V2" "old_after_resetlogs:$V3" "snapshot_return:$V4"; do
    echo "$r,${pair%%:*},\"${pair#*:}\",${pair#*:}" >> "$OUT/oracle-judgments.csv"
  done
  CUR="$V1|$V2|$V3|$V4"
  [ -n "$PREV" ] && [ "$CUR" != "$PREV" ] && STABLE=0
  PREV="$CUR"; VALID=$((VALID+1))
  SQL "ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;" >/dev/null 2>&1
done
echo
if [ "$VALID" -lt 2 ]; then
  echo "  **유효 회차가 ${VALID}개뿐입니다. 반복했다고 말할 수 없습니다.**"
elif [ "$STABLE" = 1 ]; then
  echo "  **${VALID}회차 판정이 모두 같습니다.** 시간을 못 재도 이 네 판정은 인용할 수 있습니다."
else
  echo "  **회차마다 판정이 갈립니다. 인용하면 안 됩니다.**"
fi
docker exec "$C" bash -lc "rm -rf $SNAP" >/dev/null 2>&1
} 2>&1 | tee "$OUT/exp14-oracle-judgments.txt"
