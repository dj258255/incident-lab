#!/usr/bin/env bash
# LOCK=NONE 을 명시해도 MDL 대기에 걸리는가.
#
# 이 세션은 열린 트랜잭션 하나 때문에 DROP PARTITION 이 23.7초 기다리고 뒤에 선
# SELECT 가 20.7초 멈춘 것을 쟀다. 그런데 그때 실행문에 LOCK 절이 없었다.
# run-experiments.sh 주석에는 "LOCK=NONE 을 명시해도 MDL 대기에 걸린다"고 적었지만
# 실행문은 ALTER TABLE ... DROP PARTITION 뿐이었다. 근거 없이 적은 문장이다.
#
# 여기서 실제로 LOCK=NONE 을 붙여 본다. 온라인 DDL 이라도 시작과 끝에 배타 MDL 이
# 필요하다는 것이 공식 문서의 서술이니, 붙여도 같아야 한다. 다만 MySQL 이 DROP
# PARTITION 에 LOCK=NONE 을 아예 거부할 수도 있다. 그것도 결과다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
C=r17-locknone; HOLD=${HOLD:-20}

docker rm -f "$C" >/dev/null 2>&1
docker run -d --name "$C" -e MYSQL_ROOT_PASSWORD=lab -e MYSQL_DATABASE=lab mysql:8.4.3 >/dev/null
M(){ docker exec -i "$C" mysql -uroot -plab -N -B lab -e "$1" 2>&1; }
# 값 하나를 읽을 때 쓴다. 비밀번호 경고를 걸러야 상태 문자열 자리에 경고가 안 들어온다.
V(){ M "$1" | grep -vi "^mysql:.*Warning" | tail -1; }
for _ in $(seq 1 90); do [ "$(M 'SELECT 1'|tail -1)" = "1" ] && break; sleep 2; done
[ "$(M 'SELECT 1'|tail -1)" = "1" ] || { echo "중단: MySQL 이 안 뜹니다" >&2; exit 2; }

mk(){ # 파티션 테이블을 새로 만든다
  M "DROP TABLE IF EXISTS wl;
     CREATE TABLE wl(id BIGINT NOT NULL AUTO_INCREMENT, ts DATE NOT NULL, v INT,
       PRIMARY KEY(id, ts)) ENGINE=InnoDB
     PARTITION BY RANGE (TO_DAYS(ts)) (
       PARTITION p1 VALUES LESS THAN (TO_DAYS('2026-01-02')),
       PARTITION p2 VALUES LESS THAN (TO_DAYS('2026-01-03')),
       PARTITION p3 VALUES LESS THAN (TO_DAYS('2026-01-04')),
       PARTITION pmax VALUES LESS THAN MAXVALUE);
     INSERT INTO wl(ts,v) VALUES ('2026-01-01',1),('2026-01-02',2),('2026-01-03',3);" >/dev/null
  local n; n=$(V "SELECT COUNT(*) FROM wl")
  [ "${n:-0}" -ne 3 ] && { echo "중단: 적재 ${n:-0}행(기대 3)" >&2; return 1; }
  return 0
}

# 에러 메시지는 여러 줄이다(비밀번호 경고 + ERROR). 한 줄만 읽으면 경고를 보고
# "에러 없음"으로 판정한다. 1차 시도가 그래서 전 조건을 '통과'로 적었다.
# 시간은 파일로, 에러는 따로 돌려준다.
# sec=$(try_drop ...) 는 **서브셸**이라 함수 안에서 설정한 변수가 안 돌아온다.
# 1차 시도가 그래서 전 조건을 '통과'로 적었다. 결과를 파일로 넘긴다.
SECF=/tmp/r17.sec; ERRF2=/tmp/r17.err
try_drop(){ # $1 = 사용할 LOCK 절, $2 = 파티션 이름
  local lock="$1" part="$2" t0 t1
  t0=$(date +%s%N)
  M "ALTER TABLE wl DROP PARTITION $part $lock" | grep -i "^ERROR" | head -1 > "$ERRF2"
  t1=$(date +%s%N)
  echo "$(( (t1-t0)/1000000 ))ms" > "$SECF"
}

{
echo "# LOCK=NONE 을 명시해도 MDL 대기에 걸리는가"
echo "# MySQL $(M 'SELECT VERSION()'|tail -1)"
echo
echo "## 1. 문법이 받아들여지는가 (막는 트랜잭션 없음)"
for lock in "" "LOCK=NONE" "LOCK=SHARED" "ALGORITHM=INPLACE, LOCK=NONE"; do
  mk || exit 2
  try_drop "$lock" p1; sec=$(cat "$SECF")
  if [ -s "$ERRF2" ]; then
    printf "  %-28s **거부** %s\n" "${lock:-(절 없음)}" "$(cut -c1-110 < "$ERRF2")"
  else
    printf "  %-28s 통과 (%s)\n" "${lock:-(절 없음)}" "$sec"
  fi
done
echo
echo "## 2. 열린 트랜잭션이 있을 때 (${HOLD}초 보유)"
for lock in "" "LOCK=NONE"; do
  mk || exit 2
  # 읽기만 하고 커밋하지 않는 트랜잭션을 연다
  docker exec -d "$C" mysql -uroot -plab lab -e \
    "START TRANSACTION; SELECT COUNT(*) FROM wl; SELECT SLEEP($HOLD); COMMIT;"
  sleep 3
  HELD=$(V "SELECT COUNT(*) FROM performance_schema.metadata_locks WHERE OBJECT_NAME='wl' AND LOCK_STATUS='GRANTED'")
  if [ "${HELD:-0}" -lt 1 ]; then
    echo "  중단: 막는 트랜잭션이 MDL 을 안 쥐었습니다. 이 조건은 안 섰습니다" >&2; continue
  fi
  # DDL 을 백그라운드로 던지고, 그 뒤에 평범한 SELECT 를 세운다
  ( M "ALTER TABLE wl DROP PARTITION p1 $lock" > /tmp/r17-ddl.out 2>&1 ) &
  DDLPID=$!
  sleep 2
  # **막혀 있는 동안** 찍어야 한다. SELECT 가 끝난 뒤에 보면 이미 풀려 있다.
  WSTATE=$(V "SELECT IFNULL(GROUP_CONCAT(DISTINCT LOCK_TYPE),'(없음)') FROM performance_schema.metadata_locks WHERE OBJECT_NAME='wl' AND LOCK_STATUS='PENDING'")
  T0=$(date +%s%N); M "SELECT COUNT(*) FROM wl" >/dev/null; T1=$(date +%s%N)
  SELWAIT=$(( (T1-T0)/1000000 ))ms
  wait $DDLPID 2>/dev/null
  printf "  %-22s 대기 중인 MDL 종류 %s · 뒤에 선 SELECT %s\n" "${lock:-(절 없음)}" "${WSTATE:-(못 봄)}" "$SELWAIT"
  grep -qi error /tmp/r17-ddl.out && echo "      DDL 결과: $(grep -oiE 'ERROR [0-9]+.*' /tmp/r17-ddl.out | cut -c1-90)"
  sleep 3
done
} 2>&1 | tee "$OUT/exp3-lock-none.txt"
docker rm -f "$C" >/dev/null 2>&1
