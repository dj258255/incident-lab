#!/usr/bin/env bash
# README 의 "못 한 것" 둘을 잡는다.
#
#   1) MDL 대조군이 1회 실행입니다
#      8절의 89ms 와 14,994ms 는 각각 한 번씩 잰 값이다. 한 번 잰 값으로 165배를
#      말하고 있다. A(DDL 없음)와 B(DDL 있음)를 각각 3회씩 다시 잰다.
#
#   2) OPTIMIZE TABLE 을 데이터가 든 상태에서 재지 못했습니다
#      8절의 205ms 는 앞 실험들이 파티션을 떨군 뒤라 사실상 빈 테이블을 재구축한
#      값이다. 회수 비용이 아니다. 데이터를 넣고 절반을 지운 표에서 다시 잰다.
#
# 조건마다 파티션을 하나씩 떨구므로, 시작 전에 필요한 만큼 파티션을 다시 만든다.
# 앞 실험이 떨궈 놓은 상태에서 그냥 돌리면 "떨굴 파티션이 없습니다" 로 조건이
# 통째로 빠지고, 그 자리에 물음표가 들어간 표가 남는다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
REPEAT=${REPEAT:-3}
OPT_ROWS=${OPT_ROWS:-2000000}

SQL(){ docker exec r17-mysql mysql -uroot -plab spoon -N -B -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }
SQLT(){ docker exec r17-mysql mysql -uroot -plab spoon -t -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }

for _ in $(seq 1 90); do [ "$(SQL 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(SQL 'SELECT 1')" = "1" ] || { echo "중단: r17-mysql 이 쿼리를 받지 못합니다" >&2; exit 2; }

parts(){ SQL "SELECT PARTITION_NAME FROM information_schema.PARTITIONS
              WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='watch_log_part'
                AND PARTITION_NAME IS NOT NULL AND PARTITION_NAME <> 'pmax'
              ORDER BY PARTITION_ORDINAL_POSITION"; }

nparts(){ parts | grep -c . ; }

hold(){ docker exec -d r17-mysql mysql -uroot -plab spoon -e \
          "START TRANSACTION; SELECT COUNT(*) FROM watch_log_part; DO SLEEP($1); COMMIT;"; }

timed_select(){
  local t0 t1
  t0=$(date +%s%N)
  SQL "SELECT COUNT(*) FROM watch_log_part WHERE created_at >= '2026-07-27';" >/dev/null
  t1=$(date +%s%N)
  python3 -c "print(f'{($t1-$t0)/1e6:.0f}')"
}

# 떨굴 파티션을 REPEAT 개 이상 확보한다. pmax 를 쪼개서 만든다.
ensure_parts(){
  local need="$1" have i base
  have=$(nparts)
  [ "$have" -ge "$need" ] && return 0
  echo "  파티션이 ${have}개뿐입니다. pmax 를 쪼개 ${need}개까지 채웁니다."
  for i in $(seq 1 $((need - have))); do
    base=$(date -v+${i}d '+%Y-%m-%d' 2>/dev/null || date -d "+${i} day" '+%Y-%m-%d')
    SQL "ALTER TABLE watch_log_part REORGANIZE PARTITION pmax INTO (
           PARTITION pz${i} VALUES LESS THAN (TO_DAYS('${base}')),
           PARTITION pmax VALUES LESS THAN MAXVALUE)" >/dev/null 2>&1
  done
  have=$(nparts)
  [ "$have" -ge "$need" ] || { echo "  중단: 파티션을 ${need}개까지 못 만들었습니다(현재 ${have}개)" >&2; return 1; }
  echo "  현재 파티션 ${have}개: $(parts | tr '\n' ' ')"
}

{
echo "# MDL 대조군 반복과 데이터가 든 OPTIMIZE TABLE"
echo "# MySQL $(SQL 'SELECT VERSION()')"
echo

echo "=================================================================="
echo "## 1) MDL 대조군을 ${REPEAT}회씩"
echo "=================================================================="
ensure_parts "$REPEAT" || exit 3
: > "$OUT/mdl-repeat.csv"
echo "run,cond,ddl_wait_ms,select_ms" >> "$OUT/mdl-repeat.csv"

for run in $(seq 1 "$REPEAT"); do
  echo "### 회차 $run"

  # A. DDL 없이 열린 트랜잭션만
  hold 15
  sleep 2
  A_MS=$(timed_select)
  echo "  A 열린 트랜잭션만          SELECT ${A_MS}ms"
  echo "$run,A,,$A_MS" >> "$OUT/mdl-repeat.csv"
  sleep 15

  # B. 열린 트랜잭션 뒤에 DROP PARTITION
  PB=$(parts | head -1)
  if [ -z "$PB" ]; then
    echo "  B 떨굴 파티션이 없어 건너뜁니다"
    continue
  fi
  hold 15
  sleep 2
  ( T0=$(date +%s%N)
    SQL "ALTER TABLE watch_log_part DROP PARTITION $PB;" >/dev/null
    T1=$(date +%s%N)
    python3 -c "print(f'{($T1-$T0)/1e6:.0f}')" > "$OUT/mdl-repeat-b-${run}.txt" ) &
  DROPPER=$!
  sleep 3
  B_MS=$(timed_select)
  wait $DROPPER
  B_DROP=$(cat "$OUT/mdl-repeat-b-${run}.txt" 2>/dev/null)
  echo "  B 트랜잭션 + DROP($PB)  DDL ${B_DROP}ms  SELECT ${B_MS}ms"
  echo "$run,B,${B_DROP:-},${B_MS:-}" >> "$OUT/mdl-repeat.csv"
  sleep 13
done

echo
python3 - "$OUT/mdl-repeat.csv" <<'PY'
import csv, sys, collections, statistics
rows = collections.defaultdict(list)
ddl = collections.defaultdict(list)
for r in csv.DictReader(open(sys.argv[1], encoding='utf-8')):
    if r['select_ms']:
        rows[r['cond']].append(float(r['select_ms']))
    if r['ddl_wait_ms']:
        ddl[r['cond']].append(float(r['ddl_wait_ms']))
print(f"  {'조건':<28} {'SELECT 회차별':<26} {'중앙':>9} {'폭':>9}")
labels = {'A': 'A 열린 트랜잭션만', 'B': 'B 트랜잭션 + DROP'}
for k in ('A', 'B'):
    xs = rows.get(k, [])
    if not xs:
        continue
    print(f"  {labels[k]:<28} {str([int(x) for x in xs]):<26} "
          f"{statistics.median(xs):>8.0f}ms {max(xs)-min(xs):>8.0f}ms")
a, b = rows.get('A'), rows.get('B')
if a and b and statistics.median(a):
    print()
    print(f"  중앙값 배수 {statistics.median(b)/statistics.median(a):.0f}배")
if ddl.get('B'):
    xs = ddl['B']
    print(f"  DROP 자체 대기 회차별 {[int(x) for x in xs]} 중앙 {statistics.median(xs):.0f}ms")
PY

echo
echo "=================================================================="
echo "## 2) 데이터가 든 표에서 OPTIMIZE TABLE"
echo "=================================================================="
echo "  8절의 205ms 는 앞 실험이 파티션을 다 떨군 뒤라 빈 표를 재구축한 값입니다."
echo "  ${OPT_ROWS}행을 넣고 절반을 지운 표에서 다시 잽니다."

SQL "DROP TABLE IF EXISTS opt_bench" >/dev/null
SQL "CREATE TABLE opt_bench (
       id BIGINT AUTO_INCREMENT PRIMARY KEY,
       user_id BIGINT NOT NULL,
       payload VARCHAR(200) NOT NULL,
       created_at DATETIME(3) NOT NULL,
       KEY idx_user (user_id), KEY idx_created (created_at)
     ) ENGINE=InnoDB" >/dev/null
SQL "INSERT INTO opt_bench (user_id, payload, created_at)
     SELECT n % 100000, REPEAT(MD5(n), 4), NOW(3) - INTERVAL (n % 86400) SECOND FROM (
       SELECT @r := @r + 1 AS n FROM information_schema.COLUMNS c1,
         information_schema.COLUMNS c2, information_schema.COLUMNS c3,
         (SELECT @r := 0) r LIMIT ${OPT_ROWS}
     ) t" >/dev/null 2>&1

N=$(SQL "SELECT COUNT(*) FROM opt_bench")
case "${N:-}" in ''|*[!0-9]*) N=0 ;; esac
[ "$N" -gt 0 ] || { echo "  중단: opt_bench 가 비어 있습니다" >&2; exit 4; }
SQL "ANALYZE TABLE opt_bench" >/dev/null 2>&1
read -r SZ0 FREE0 <<< "$(SQL "SELECT ROUND((DATA_LENGTH+INDEX_LENGTH)/1048576),
                                     ROUND(DATA_FREE/1048576)
                              FROM information_schema.TABLES
                              WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='opt_bench'")"
echo "  적재 ${N}행, 크기 ${SZ0}MB, DATA_FREE ${FREE0}MB"

DEL=$(SQL "DELETE FROM opt_bench WHERE id % 2 = 0; SELECT ROW_COUNT()")
SQL "ANALYZE TABLE opt_bench" >/dev/null 2>&1
read -r SZ1 FREE1 <<< "$(SQL "SELECT ROUND((DATA_LENGTH+INDEX_LENGTH)/1048576),
                                     ROUND(DATA_FREE/1048576)
                              FROM information_schema.TABLES
                              WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='opt_bench'")"
echo "  ${DEL}행 삭제 후 크기 ${SZ1}MB, DATA_FREE ${FREE1}MB"
echo "  DELETE 는 크기를 안 줄입니다. 지운 자리가 DATA_FREE 로 남습니다."

# OPTIMIZE 가 도는 동안 일반 SELECT 가 갇히는지 같이 본다.
( T0=$(date +%s%N)
  SQLT "OPTIMIZE TABLE opt_bench;" > "$OUT/optimize-loaded-out.txt" 2>&1
  T1=$(date +%s%N)
  python3 -c "print(f'{($T1-$T0)/1e6:.0f}')" > "$OUT/optimize-loaded-ms.txt" ) &
OPT=$!
sleep 1
t0=$(date +%s%N)
SQL "SELECT COUNT(*) FROM opt_bench WHERE user_id < 1000" >/dev/null
t1=$(date +%s%N)
D_MS=$(python3 -c "print(f'{($t1-$t0)/1e6:.0f}')")
wait $OPT
OPT_MS=$(cat "$OUT/optimize-loaded-ms.txt" 2>/dev/null)
SQL "ANALYZE TABLE opt_bench" >/dev/null 2>&1
read -r SZ2 FREE2 <<< "$(SQL "SELECT ROUND((DATA_LENGTH+INDEX_LENGTH)/1048576),
                                     ROUND(DATA_FREE/1048576)
                              FROM information_schema.TABLES
                              WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='opt_bench'")"
N2=$(SQL "SELECT COUNT(*) FROM opt_bench")
echo
echo "  OPTIMIZE TABLE 소요 = ${OPT_MS}ms"
echo "  그동안 들어온 일반 SELECT = ${D_MS}ms"
echo "  실행 후 크기 ${SZ2}MB, DATA_FREE ${FREE2}MB, 행 수 ${N2}"
echo "  MySQL 이 뭐라고 답했는지:"
grep -iE "note|status|OK|does not support" "$OUT/optimize-loaded-out.txt" | head -4 | sed 's/^/    /'
echo
echo "  8절의 빈 표 205ms 와 나란히 놓으면 회수 비용이 행 수에 붙는다는 것이 보입니다."
echo
echo "  1) 은 조건마다 ${REPEAT}회, 2) 는 1회 실행입니다."
} 2>&1 | tee "$OUT/exp-mdl-repeat-and-optimize.txt"
