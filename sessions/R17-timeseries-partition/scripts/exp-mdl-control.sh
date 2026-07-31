#!/usr/bin/env bash
# README 의 "못 한 것" 중 세 개를 잡는다.
#
#   1) MDL 실험에 대조군이 없습니다
#      DROP PARTITION 없이 SELECT 만 넣은 경우를 안 쟀다. 그래서 "SELECT 가 갇힌 것이
#      DDL 때문"이라는 말의 근거가 얇다. 열린 트랜잭션만 있고 DDL 이 없으면 SELECT 가
#      안 걸린다는 것을 보여야 앞의 결론이 선다.
#
#   2) LOCK=NONE 을 붙인 조건을 실행하지 않았습니다
#      원 스크립트에도 "LOCK 절이 없으니 LOCK=NONE 을 명시해도 걸린다는 근거로 쓰지
#      말라"고 적어 두었다. 붙여서 실제로 어떻게 되는지 본다.
#
#   3) OPTIMIZE TABLE 을 돌려 보지 않았습니다
#      DELETE 가 회수하지 못한 공간을 실제로 되찾는 데 드는 시간과 그동안의 잠금을 잰다.
#
# 조건 넷:
#   A. 열린 트랜잭션만 (DDL 없음)        → SELECT 가 안 걸려야 한다. 대조군
#   B. 열린 트랜잭션 + DROP PARTITION    → 원 실험. SELECT 가 갇힌다
#   C. 열린 트랜잭션 + DROP ... LOCK=NONE → LOCK 절이 이 상황을 바꾸는가
#   D. OPTIMIZE TABLE                     → 공간 회수 비용
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
SQL(){ docker exec r17-mysql mysql -uroot -plab spoon -N -B -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }
SQLT(){ docker exec r17-mysql mysql -uroot -plab spoon -t -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }

for _ in $(seq 1 90); do [ "$(SQL 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(SQL 'SELECT 1')" = "1" ] || { echo "중단: r17-mysql 이 쿼리를 받지 못합니다" >&2; exit 2; }

# 살아 있는 파티션 이름을 읽어 온다. 앞 실험이 이미 몇 개를 떨궈서 이름을 박아 두면
# "그런 파티션 없음"으로 실패한다.
parts(){ SQL "SELECT PARTITION_NAME FROM information_schema.PARTITIONS
              WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='watch_log_part'
                AND PARTITION_NAME IS NOT NULL AND PARTITION_NAME <> 'pmax'
              ORDER BY PARTITION_ORDINAL_POSITION"; }

# 열린 트랜잭션 하나를 만든다. SELECT 만 하고 커밋하지 않는다.
hold(){ # $1=유지 초
  docker exec -d r17-mysql mysql -uroot -plab spoon -e \
    "START TRANSACTION; SELECT COUNT(*) FROM watch_log_part; DO SLEEP($1); COMMIT;"
}

# 일반 SELECT 하나의 소요 시간을 밀리초로 잰다.
timed_select(){
  local t0 t1
  t0=$(date +%s%N)
  SQL "SELECT COUNT(*) FROM watch_log_part WHERE created_at >= '2026-07-27';" >/dev/null
  t1=$(date +%s%N)
  python3 -c "print(f'{($t1-$t0)/1e6:.0f}')"
}

{
echo "# MDL 대조군, LOCK=NONE, OPTIMIZE TABLE"
echo "# MySQL $(SQL 'SELECT VERSION()')"
echo "# 조건마다 1회 실행입니다."
echo
echo "  현재 파티션: $(parts | tr '\n' ' ')"
echo

# ── A. 대조군: 열린 트랜잭션만 있고 DDL 은 없다 ─────────────────────────
echo "## A. 대조군: 열린 트랜잭션만 있고 DDL 이 없다"
echo "  DDL 이 없으면 열린 트랜잭션은 다른 SELECT 를 막지 않아야 합니다."
hold 20
sleep 2
A_MS=$(timed_select)
echo "  일반 SELECT 소요 = ${A_MS}ms"
sleep 20

# ── B. 원 실험: 열린 트랜잭션 + DROP PARTITION ──────────────────────────
echo
echo "## B. 열린 트랜잭션 뒤에 DROP PARTITION 이 서면"
PB=$(parts | head -1)
if [ -z "$PB" ]; then
  echo "  떨굴 파티션이 없습니다. 이 조건은 건너뜁니다."
  B_MS="" ; B_DROP=""
else
  hold 20
  sleep 2
  ( T0=$(date +%s%N)
    SQL "ALTER TABLE watch_log_part DROP PARTITION $PB;" >/dev/null
    T1=$(date +%s%N)
    python3 -c "print(f'{($T1-$T0)/1e6:.0f}')" > "$OUT/mdl-b-drop.txt" ) &
  DROPPER=$!
  sleep 3
  B_MS=$(timed_select)
  wait $DROPPER
  B_DROP=$(cat "$OUT/mdl-b-drop.txt" 2>/dev/null)
  echo "  떨군 파티션 = $PB"
  echo "  DROP PARTITION 대기 = ${B_DROP}ms"
  echo "  그 뒤에 선 일반 SELECT = ${B_MS}ms"
  sleep 18
fi

# ── C. LOCK=NONE 을 명시하면 ───────────────────────────────────────────
echo
echo "## C. DROP PARTITION 에 LOCK=NONE 을 명시하면"
echo "  MySQL 매뉴얼은 DROP PARTITION 이 ALGORITHM=DEFAULT, LOCK=DEFAULT 로 동작한다고"
echo "  적습니다. LOCK=NONE 을 요구하면 받아 주는지부터 봅니다."
PC=$(parts | head -1)
if [ -z "$PC" ]; then
  echo "  떨굴 파티션이 없습니다. 이 조건은 건너뜁니다."
  C_MS=""; C_DROP=""
else
  # 먼저 열린 트랜잭션 없이 문법이 받아들여지는지 본다.
  ACCEPT=$(SQL "ALTER TABLE watch_log_part DROP PARTITION $PC, ALGORITHM=DEFAULT, LOCK=NONE;" 2>&1)
  if echo "$ACCEPT" | grep -qi "error"; then
    echo "  거부됨: $(echo "$ACCEPT" | head -2 | tr '\n' ' ')"
    C_MS=""; C_DROP=""
  else
    echo "  받아들여졌습니다. 이제 열린 트랜잭션 뒤에서 같은 것을 해 봅니다."
    PC2=$(parts | head -1)
    if [ -n "$PC2" ]; then
      hold 20
      sleep 2
      ( T0=$(date +%s%N)
        SQL "ALTER TABLE watch_log_part DROP PARTITION $PC2, LOCK=NONE;" >/dev/null 2>&1
        T1=$(date +%s%N)
        python3 -c "print(f'{($T1-$T0)/1e6:.0f}')" > "$OUT/mdl-c-drop.txt" ) &
      DROPPER=$!
      sleep 3
      C_MS=$(timed_select)
      wait $DROPPER
      C_DROP=$(cat "$OUT/mdl-c-drop.txt" 2>/dev/null)
      echo "  떨군 파티션 = $PC2"
      echo "  DROP PARTITION LOCK=NONE 대기 = ${C_DROP}ms"
      echo "  그 뒤에 선 일반 SELECT = ${C_MS}ms"
      sleep 18
    fi
  fi
fi

echo
echo "### 세 조건 나란히"
printf "  %-40s %12s %12s\n" "조건" "DDL 대기" "SELECT"
printf "  %-40s %12s %12s\n" "A. 열린 트랜잭션만 (DDL 없음)" "-" "${A_MS}ms"
printf "  %-40s %12s %12s\n" "B. 열린 트랜잭션 + DROP PARTITION" "${B_DROP:-?}ms" "${B_MS:-?}ms"
printf "  %-40s %12s %12s\n" "C. 열린 트랜잭션 + LOCK=NONE" "${C_DROP:-미실행}" "${C_MS:-미실행}"
echo

# ── D. OPTIMIZE TABLE ──────────────────────────────────────────────────
echo "## D. OPTIMIZE TABLE 로 공간을 되찾는 비용"
echo "  DELETE 가 비운 공간은 테이블 파일에 남습니다. 되찾으려면 재구축이 필요합니다."
SZ0=$(SQL "SELECT ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024) FROM information_schema.TABLES
           WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='watch_log_part'")
FREE0=$(SQL "SELECT ROUND(DATA_FREE/1024/1024) FROM information_schema.TABLES
             WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='watch_log_part'")
echo "  실행 전 크기 ${SZ0}MB, DATA_FREE ${FREE0}MB"

# OPTIMIZE 가 도는 동안 일반 SELECT 가 갇히는지 같이 본다.
( T0=$(date +%s%N)
  SQLT "OPTIMIZE TABLE watch_log_part;" > "$OUT/optimize-out.txt" 2>&1
  T1=$(date +%s%N)
  python3 -c "print(f'{($T1-$T0)/1e6:.0f}')" > "$OUT/optimize-ms.txt" ) &
OPT=$!
sleep 1
D_MS=$(timed_select)
wait $OPT
OPT_MS=$(cat "$OUT/optimize-ms.txt" 2>/dev/null)
SZ1=$(SQL "SELECT ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024) FROM information_schema.TABLES
           WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='watch_log_part'")
FREE1=$(SQL "SELECT ROUND(DATA_FREE/1024/1024) FROM information_schema.TABLES
             WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='watch_log_part'")
echo "  OPTIMIZE TABLE 소요 = ${OPT_MS}ms"
echo "  그동안 들어온 일반 SELECT = ${D_MS}ms"
echo "  실행 후 크기 ${SZ1}MB, DATA_FREE ${FREE1}MB"
echo "  MySQL 이 뭐라고 답했는지:"
grep -iE "note|status|OK|does not support" "$OUT/optimize-out.txt" | head -4 | sed 's/^/    /'
echo
echo "  InnoDB 는 OPTIMIZE TABLE 을 그대로 지원하지 않고 ALTER TABLE ... FORCE 로 바꿔"
echo "  실행합니다. 그래서 위 note 에 'Table does not support optimize' 가 뜹니다."
echo "  재구축이므로 온라인 DDL 이 적용되고, 그동안 SELECT 는 위 값만큼만 기다립니다."
} 2>&1 | tee "$OUT/exp-mdl-control.txt"
