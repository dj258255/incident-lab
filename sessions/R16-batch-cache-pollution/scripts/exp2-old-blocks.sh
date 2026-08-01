#!/usr/bin/env bash
# innodb_old_blocks_time 과 _pct 가 실제로 얼마나 막아 주는가.
#
# 이 세션은 방어의 값어치를 최저점이 아니라 회복 시간에서 찾았다. 그런데 매뉴얼과
# 벤치마크가 이 파라미터를 정반대로 평가한다.
#   매뉴얼: "is relatively small, and varies more with the workload"
#   Percona(2011): 512MB 풀에 4GB 덤프를 겹쳤더니 330 req/s 가 2 req/s 로 떨어졌고,
#                  old_blocks_time=1000 을 주자 325 req/s 로 돌아왔다
# 간극의 정체가 조건이라면(스캔이 풀보다 훨씬 클 때만 값어치가 있다), 같은 호스트에서
# 조건을 만들어 확인할 수 있다.
#
# 재는 것은 배치가 도는 동안 OLTP 조회가 초당 몇 건을 처리하는가다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
C=r16-oldblocks; POOL=${POOL:-256M}; HOT=${HOT:-150000}; # 1차 조건은 cold 373MB 에 풀 256M 이라 비율이 1.5배였다. Percona 가 165배를 잰
# 조건은 풀 512MB 에 스캔 4GB, 곧 8배다. 압력이 약하면 방어가 일할 자리도 없다.
# 비율을 키우고, 조건마다 REPS 회 반복해 노이즈와 신호를 가른다.
COLD=${COLD:-9000000}; REPS=${REPS:-3}

docker rm -f "$C" >/dev/null 2>&1
docker run -d --name "$C" -e MYSQL_ROOT_PASSWORD=lab -e MYSQL_DATABASE=lab mysql:8.4.3 \
  --innodb-buffer-pool-size=$POOL --innodb-buffer-pool-instances=1 >/dev/null
M(){ docker exec -i "$C" mysql -uroot -plab -N -B lab -e "$1" 2>/dev/null; }
for _ in $(seq 1 90); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(M 'SELECT 1')" = "1" ] || { echo "중단: MySQL 이 안 뜹니다" >&2; exit 2; }

M "CREATE TABLE hot(id INT PRIMARY KEY, pad CHAR(120)) ENGINE=InnoDB;
   CREATE TABLE cold(id INT PRIMARY KEY, pad CHAR(120)) ENGINE=InnoDB;
   SET SESSION cte_max_recursion_depth=$((COLD+10));
   INSERT INTO hot SELECT n, REPEAT('h',120) FROM (
     WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<$HOT) SELECT n FROM s) q;
   INSERT INTO cold SELECT n, REPEAT('c',120) FROM (
     WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<$COLD) SELECT n FROM s) q;" >/dev/null
M "ANALYZE TABLE hot, cold;" >/dev/null
HN=$(M "SELECT COUNT(*) FROM hot"); CN=$(M "SELECT COUNT(*) FROM cold")
if [ "${HN:-0}" -ne "$HOT" ] || [ "${CN:-0}" -ne "$COLD" ]; then
  echo "중단: 적재가 hot ${HN:-0} / cold ${CN:-0} 입니다(기대 $HOT / $COLD)" >&2
  docker rm -f "$C" >/dev/null; exit 2
fi
SZ(){ M "SELECT ROUND(DATA_LENGTH/1048576) FROM information_schema.tables WHERE table_schema='lab' AND table_name='$1'"; }
# OLTP 가 배치보다 훨씬 짧게 끝나면 두 부하가 겹치는 구간이 거의 없어서
# 파라미터가 일할 자리도 없다. 배치 한 바퀴와 비슷한 길이가 되게 잡는다.
QN=${QN:-1500000}
# 저장 프로시저를 쓰려다 접었다. mysql -e 는 입력을 세미콜론으로 쪼개서 프로시저 본문이
# 중간에 잘리고, 그 에러를 버리면 CALL 이 조용히 실패한다. 1차 시도에서 150만 건이
# 52ms 에 끝난 것으로 나온 이유다. 아무것도 안 돌고 있었다.
#
# 대신 무작위 키를 담은 probes 를 만들어 조인한다. 한 문장 안에서 hot 의 인덱스를
# QN 번 탐색하므로 세션도 하나이고 실제로 일도 한다.
M "DROP TABLE IF EXISTS probes;
   CREATE TABLE probes(i INT PRIMARY KEY, k INT NOT NULL) ENGINE=InnoDB;" >/dev/null
M "SET SESSION cte_max_recursion_depth=$((QN+10));
   INSERT INTO probes SELECT n, FLOOR(RAND()*$HOT)+1 FROM (
     WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<$QN) SELECT n FROM s) q;" >/dev/null
PN=$(M "SELECT COUNT(*) FROM probes")
if [ "${PN:-0}" -ne "$QN" ]; then
  echo "중단: probes 적재가 ${PN:-0}행입니다(기대 $QN)" >&2; docker rm -f "$C" >/dev/null; exit 2
fi
M "ANALYZE TABLE probes;" >/dev/null

# OLTP: 핫셋을 무작위로 단건 조회. 배치: 콜드 테이블을 통째로 훑는다.
# 1차 시도는 쿼리마다 docker exec 로 mysql 클라이언트를 띄웠다. 그 기동 비용이
# 29ms 라 전 조건이 34건/s 로 같아졌다. 재고 있던 것은 DB 가 아니라 docker 였다.
# 저장 프로시저로 한 세션 안에서 돈다.
oltp(){ M "SELECT SUM(LENGTH(h.pad)) FROM probes p STRAIGHT_JOIN hot h ON h.id = p.k" >/dev/null; }
batch(){ docker exec -i "$C" mysql -uroot -plab -N -B lab -e "SELECT COUNT(*), SUM(LENGTH(pad)) FROM cold" >/dev/null 2>&1; }

measure(){ # $1 = 라벨, $2 = old_blocks_time, $3 = old_blocks_pct, $4 = with_batch|alone
  local rep msl=() rdl=()
  for rep in $(seq 1 "$REPS"); do measure_once "$@"; msl+=("$MS_OUT"); rdl+=("$RD_OUT"); done
  local med_ms med_rd
  med_ms=$(printf '%s\n' "${msl[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
  med_rd=$(printf '%s\n' "${rdl[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
  printf "  %-36s 중앙 %6sms  디스크읽기 중앙 %6s쪽   (%s회: %s / %s)\n" \
    "$1" "$med_ms" "$med_rd" "$REPS" "$(IFS=,; echo "${msl[*]}")" "$(IFS=,; echo "${rdl[*]}")"
  echo "$1,$2,$3,$4,$med_ms,$med_rd" >> "$OUT/old-blocks.csv"
}
MS_OUT=0; RD_OUT=0
measure_once(){
  M "SET GLOBAL innodb_old_blocks_time=$2; SET GLOBAL innodb_old_blocks_pct=$3;" >/dev/null
  M "SELECT COUNT(*) FROM hot" >/dev/null    # 핫셋을 풀에 올린다
  local before after t0 t1 ms
  before=$(M "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads'")
  local hk0; hk0=$(M "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Handler_read_key'")
  if [ "$4" = with_batch ]; then ( while :; do batch; done ) & BPID=$!; fi
  t0=$(date +%s%N); oltp; t1=$(date +%s%N); ms=$(( (t1-t0)/1000000 ))
  if [ "$4" = with_batch ]; then
    kill $BPID 2>/dev/null; wait $BPID 2>/dev/null
    # 컨테이너 안에서 아직 도는 스캔이 있으면 다음 조건에 섞인다. 끊어 준다.
    M "SELECT IFNULL(GROUP_CONCAT(CONCAT('KILL ',ID) SEPARATOR ';'),'') FROM information_schema.processlist WHERE INFO LIKE '%FROM cold%'" >/dev/null
    for pid in $(M "SELECT ID FROM information_schema.processlist WHERE INFO LIKE '%FROM cold%'"); do
      M "KILL $pid" >/dev/null 2>&1
    done
    sleep 2
  fi
  after=$(M "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads'")
  local hk1; hk1=$(M "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Handler_read_key'")
  local did=$(( hk1 - hk0 ))
  [ "$ms" -lt 1 ] && ms=1
  # 실제로 인덱스를 몇 번 탐색했는지로 검산한다. QN 의 절반도 안 되면 안 돈 것이다.
  if [ "$did" -lt $(( QN / 2 )) ]; then
    echo "  **인덱스 탐색이 ${did}회뿐입니다(기대 $QN). 이 회차는 못 씁니다**"
    MS_OUT=0; RD_OUT=0; return
  fi
  MS_OUT=$ms; RD_OUT=$((after-before))
  echo "$1,$2,$3,$4,$ms,$((after-before))" >> "$OUT/old-blocks.csv"
}

echo "label,old_blocks_time,old_blocks_pct,mode,oltp_ms,pool_reads" > "$OUT/old-blocks.csv"
{
echo "# 배치 방어 파라미터가 실제로 얼마나 막아 주는가"
echo "# MySQL $(M 'SELECT VERSION()') · 버퍼 풀 $POOL · hot $(M "SELECT ROUND(DATA_LENGTH/1048576,1) FROM information_schema.tables WHERE table_schema='lab' AND table_name='hot'")MB / cold $(SZ cold)MB"
echo "# OLTP 는 저장 프로시저 안에서 핫셋 단건 조회를 $QN 번 돕니다."
echo "echo "# 조건마다 $REPS 회 반복해 중앙값을 씁니다. 회차 값도 함께 적습니다."
echo "# 스캔 대상이 버퍼 풀보다 커야 이 파라미터가 일할 자리가 생깁니다.""
echo
measure "배치 없음 (기준선)"              1000 37 alone
measure "배치 겹침, time=0 pct=37"        0    37 with_batch
measure "배치 겹침, time=1000 pct=37 (기본)" 1000 37 with_batch
measure "배치 겹침, time=1000 pct=5"      1000 5  with_batch
} 2>&1 | tee "$OUT/exp2-old-blocks.txt"
docker rm -f "$C" >/dev/null 2>&1
