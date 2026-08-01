#!/usr/bin/env bash
# 복제본을 먼저 ALTER 하고 복제를 재개할 수 있는가.
#
# 이 세션은 한 방 ALTER 와 expand-contract 를 쟀다. Basecamp 가 2018-11-08 에 쓴 것은
# 둘 다 아니었다. 복제본을 서비스에서 빼서 그 위에서 ALTER 하고 역할을 맞바꿨다.
#   "We take the replica that out of service, we make the change, which blocks access
#    to the table, and then we put the replica back into service and then we swap roles."
#
# 그리고 그 자리에서 걸렸다.
#   "at first it didn't work ... the replica database could take all those two to three
#    hours of updates ... but it needed to be configured to do so. By default it wasn't."
#
# 소스가 INT 이고 복제본이 BIGINT 인 상태는 행 기반 복제의 attribute promotion 이다.
# MySQL 문서는 replica_type_conversions 가 비어 있으면 승격도 강등도 허용하지 않는다고
# 적는다. 그러면 ALTER 는 성공하고 복제가 멈춘다. 그것을 확인한다.
#
# 그들이 켠 설정의 이름은 밝혀지지 않았다. ALL_NON_LOSSY 대응은 문서에 근거한 추정이고,
# 이 실험은 그 추정이 실제로 성립하는지를 본다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
SRC=a01-src; REP=a01-rep; NET=a01-net; PW=lab

cleanup(){ docker rm -f "$SRC" "$REP" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
cleanup; docker network create "$NET" >/dev/null

docker run -d --name "$SRC" --network "$NET" -e MYSQL_ROOT_PASSWORD=$PW -e MYSQL_DATABASE=lab \
  mysql:8.4.3 --server-id=1 --log-bin=binlog --binlog-format=ROW --gtid-mode=ON \
  --enforce-gtid-consistency=ON >/dev/null
docker run -d --name "$REP" --network "$NET" -e MYSQL_ROOT_PASSWORD=$PW -e MYSQL_DATABASE=lab \
  mysql:8.4.3 --server-id=2 --log-bin=binlog --binlog-format=ROW --gtid-mode=ON \
  --enforce-gtid-consistency=ON >/dev/null

S(){ docker exec -i "$SRC" mysql -uroot -p$PW -N -B ${2:+-D $2} -e "$1" 2>&1; }
R(){ docker exec -i "$REP" mysql -uroot -p$PW -N -B ${2:+-D $2} -e "$1" 2>&1; }
wait_up(){ for _ in $(seq 1 90); do [ "$($1 'SELECT 1' 2>/dev/null | tail -1)" = "1" ] && return 0; sleep 2; done; return 1; }
wait_up S || { echo "중단: 소스가 안 뜹니다" >&2; cleanup; exit 2; }
wait_up R || { echo "중단: 복제본이 안 뜹니다" >&2; cleanup; exit 2; }

# 소스에 INT PK 테이블을 만들고 복제를 건다
S "CREATE TABLE lab.events(id INT AUTO_INCREMENT PRIMARY KEY, body VARCHAR(64)) ENGINE=InnoDB;" >/dev/null
# MySQL 8.4 는 mysql_native_password 를 기본 빌드에서 뺐다. 그것으로 CREATE USER 하면
# 실패하고, 그 실패를 버리면 복제가 안 붙은 채로 실험이 끝까지 돈다. 1차 시도가 그랬다.
CU=$(S "CREATE USER repl@'%' IDENTIFIED BY 'repl';
        GRANT REPLICATION SLAVE ON *.* TO repl@'%';")
echo "$CU" | grep -qi error && { echo "중단: 복제 계정 생성 실패: $CU" >&2; cleanup; exit 2; }
R "CHANGE REPLICATION SOURCE TO SOURCE_HOST='$SRC', SOURCE_USER='repl',
     SOURCE_PASSWORD='repl', SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1;
   START REPLICA;" >/dev/null
sleep 5
S "INSERT INTO lab.events(body) VALUES('before-1'),('before-2');" >/dev/null
sleep 3

io_state(){ R "SELECT SERVICE_STATE FROM performance_schema.replication_connection_status" | tail -1; }
sql_err(){ R "SELECT LAST_ERROR_NUMBER, LEFT(LAST_ERROR_MESSAGE,110) FROM performance_schema.replication_applier_status_by_worker" | tail -1; }
rep_rows(){ R "SELECT COUNT(*) FROM lab.events" | tail -1; }
rep_type(){ R "SELECT COLUMN_TYPE FROM information_schema.columns WHERE table_schema='lab' AND table_name='events' AND column_name='id'" | tail -1; }

run_case(){ # $1 = off|all_non_lossy
  local conv="$1"
  # 복제본을 초기 상태로 되돌린다
  R "STOP REPLICA; RESET REPLICA ALL;" >/dev/null 2>&1
  R "DROP TABLE IF EXISTS lab.events;" >/dev/null 2>&1
  R "RESET BINARY LOGS AND GTIDS;" >/dev/null 2>&1
  S "RESET BINARY LOGS AND GTIDS;" >/dev/null 2>&1
  S "TRUNCATE lab.events;" >/dev/null 2>&1
  R "CREATE TABLE lab.events(id INT AUTO_INCREMENT PRIMARY KEY, body VARCHAR(64)) ENGINE=InnoDB;" >/dev/null
  if [ "$conv" = off ]; then R "SET GLOBAL replica_type_conversions='';" >/dev/null
  else R "SET GLOBAL replica_type_conversions='ALL_NON_LOSSY';" >/dev/null; fi
  R "CHANGE REPLICATION SOURCE TO SOURCE_HOST='$SRC', SOURCE_USER='repl',
       SOURCE_PASSWORD='repl', SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1;
     START REPLICA;" >/dev/null
  sleep 4
  S "INSERT INTO lab.events(body) VALUES('pre-alter');" >/dev/null; sleep 3
  local pre; pre=$(rep_rows)
  # **여기서 조건이 섰는지 확인한다.** 복제가 안 붙으면 아래 모든 판정이
  # "에러 없음 / 0행"으로 나와서 성공과 구분이 안 된다. 1차 시도가 그 모양이었다.
  local srcn; srcn=$(S "SELECT COUNT(*) FROM lab.events" | tail -1)
  if [ "${pre:-0}" != "${srcn:-1}" ] || [ "${pre:-0}" = "0" ]; then
    echo "중단: ALTER 전에 복제가 안 붙었습니다(복제본 ${pre:-?}행, 소스 ${srcn:-?}행)." >&2
    echo "      IO: $(io_state)" >&2
    echo "      연결 에러: $(R "SELECT LAST_ERROR_NUMBER, LEFT(LAST_ERROR_MESSAGE,150) FROM performance_schema.replication_connection_status" | tail -1)" >&2
    echo "      적용 에러: $(sql_err)" >&2
    cleanup; exit 3
  fi

  # 1) 복제본을 서비스에서 뺀다 = 복제를 멈춘다
  R "STOP REPLICA SQL_THREAD;" >/dev/null
  # 2) 복제본에서만 ALTER 한다. 소스는 INT 그대로다
  R "ALTER TABLE lab.events MODIFY id BIGINT NOT NULL AUTO_INCREMENT;" >/dev/null
  local rt; rt=$(rep_type)
  # 3) 그 사이 소스에는 쓰기가 계속 들어온다 (Basecamp 의 2~3시간분)
  S "INSERT INTO lab.events(body) VALUES('during-1'),('during-2'),('during-3');" >/dev/null
  # 4) 복제를 재개한다. 여기가 걸린 자리다
  R "START REPLICA SQL_THREAD;" >/dev/null
  sleep 6

  local errno errmsg post
  errno=$(R "SELECT IFNULL(MAX(LAST_ERROR_NUMBER),0) FROM performance_schema.replication_applier_status_by_worker" | tail -1)
  errmsg=$(R "SELECT IFNULL(LEFT(MAX(LAST_ERROR_MESSAGE),400),'') FROM performance_schema.replication_applier_status_by_worker" | tail -1)
  post=$(rep_rows)
  echo "$conv|$rt|$pre|$post|$errno|$errmsg"
}

{
echo "# 복제본을 먼저 ALTER 하고 복제를 재개할 수 있는가"
echo "# 소스 MySQL $(S 'SELECT VERSION()' | tail -1) · 행 기반 복제 · GTID"
echo "# 소스는 INT 를 유지하고 복제본만 BIGINT 로 올린 상태에서 복제를 재개합니다."
echo
: > "$OUT/replica-first-alter.csv"
echo "replica_type_conversions,replica_col_type,rows_before,rows_after,error_no,error" >> "$OUT/replica-first-alter.csv"
for conv in off all_non_lossy; do
  IFS='|' read -r c rt pre post en em <<< "$(run_case "$conv")"
  LBL=$([ "$c" = off ] && echo "빈 값(기본)" || echo "ALL_NON_LOSSY")
  echo "## replica_type_conversions = $LBL"
  printf "  %-26s %s\n" "복제본 id 컬럼 타입" "$rt"
  printf "  %-26s %s행 → %s행 (소스는 6행)\n" "복제본 행 수" "$pre" "$post"
  if [ "${en:-0}" != "0" ]; then
    printf "  %-26s **%s** %s\n" "복제 적용 에러" "$en" "$em"
    printf "  %-26s %s\n" "판정" "**복제가 멈췄습니다.** 복제본이 소스를 못 따라갑니다"
  else
    printf "  %-26s 없음\n" "복제 적용 에러"
    printf "  %-26s 복제가 이어졌습니다\n" "판정"
  fi
  echo
  echo "$c,$rt,$pre,$post,$en,\"$em\"" >> "$OUT/replica-first-alter.csv"
done
echo "=================================================================="
echo "  소스 최종 행 수: $(S 'SELECT COUNT(*) FROM lab.events' | tail -1)"
echo "  소스 id 타입:    $(S "SELECT COLUMN_TYPE FROM information_schema.columns WHERE table_schema='lab' AND table_name='events' AND column_name='id'" | tail -1)"
} 2>&1 | tee "$OUT/exp6-replica-first-alter.txt"
cleanup
