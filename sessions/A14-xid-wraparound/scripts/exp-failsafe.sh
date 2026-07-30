#!/usr/bin/env bash
# vacuum_failsafe_age 가 실제로 무엇을 아끼는지 시간으로 잰다.
#
# 이 세션은 failsafe 가 발동한 것을 관측했지만(README 10절) 그것이 없을 때
# 얼마나 더 걸리는지는 재지 않았다. 5만 행에서는 VACUUM 이 즉시 끝나 차이가
# 시간으로 드러나지 않기 때문이다. Sentry 병목의 정량화가 여기 걸려 있었다.
#
# 그래서 두 항목을 함께 처리한다.
#   거대 테이블            → 인덱스를 여러 개 붙여 인덱스 정리가 지배하게 만든다
#   vacuum_failsafe_age 대조 → 발동/미발동 두 조건을 나눠 잰다
#
# 함정이 하나 있다. vacuum_failsafe_age 를 0 으로 둬도 0 이 되지 않는다.
# 소스의 vacuum_xid_failsafe_check 가 쓰는 값은
#   Max(vacuum_failsafe_age, autovacuum_freeze_max_age * 1.05)
# 이다. 기본값 2억에서는 실효 하한이 2억 1천만이라 갓 만든 테이블(age 8)에서는
# 아무리 0 을 줘도 발동하지 않는다. 처음에 그렇게 돌려 두 조건이 같은 값을 냈다.
#
# 그래서 발동 조건을 이렇게 만든다.
#   autovacuum_freeze_max_age = 100000 (최소값)  → 실효 하한 105,000
#   XID 를 12만 개 태워 테이블 age 를 그 위로 올린다
#   테이블 단위 autovacuum_freeze_max_age 는 20억으로 올려 둔다
#     (그러지 않으면 wraparound 방지 autovacuum 이 먼저 동결해 age 가 리셋된다.
#      전역 GUC 는 failsafe 하한 계산에 쓰이고 테이블 파라미터는 autovacuum
#      대상 선정에 쓰이므로 둘을 다르게 둘 수 있다)
BURN=${BURN:-120000}
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
Q(){ docker exec a14-pg psql -U postgres -d spoon -qAt -c "$1" 2>&1; }

# autovacuum_freeze_max_age 는 postmaster 컨텍스트라 재기동이 필요하다.
# compose 가 FREEZE_MAX_AGE 로 파라미터화해 두었으므로 그 값으로 띄운다.
NEED=100000
CUR=$(Q "SHOW autovacuum_freeze_max_age" 2>/dev/null)
if [ "$CUR" != "$NEED" ]; then
  echo "autovacuum_freeze_max_age 를 $NEED 으로 두고 재기동합니다 (현재 ${CUR:-미기동})"
  (cd "$ROOT" && FREEZE_MAX_AGE=$NEED docker compose up -d --force-recreate >/dev/null 2>&1)
fi
for _ in $(seq 1 90); do [ "$(Q 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(Q 'SELECT 1')" = "1" ] || { echo "중단: a14-pg 가 쿼리를 받지 못합니다" >&2; exit 2; }
[ "$(Q 'SHOW autovacuum_freeze_max_age')" = "$NEED" ] || {
  echo "중단: autovacuum_freeze_max_age 가 $NEED 이 아닙니다($(Q 'SHOW autovacuum_freeze_max_age')). 이 실험은 성립하지 않습니다" >&2; exit 2; }

ROWS=${ROWS:-5000000}
NIDX=${NIDX:-5}

# 조건 하나를 처음부터 만들어 VACUUM 을 잰다.
# 죽은 튜플을 새로 만들어야 인덱스 정리에 실제 작업이 생긴다.
run_case() { # $1=라벨  $2=vacuum_failsafe_age
  local label="$1" fs="$2"
  Q "DROP TABLE IF EXISTS big" >/dev/null
  Q "CREATE TABLE big (id bigserial PRIMARY KEY, a int, b int, c int, d int, memo text)" >/dev/null
  Q "INSERT INTO big (a,b,c,d,memo)
     SELECT i, i%1000, i%97, i%7, repeat('x', 40) FROM generate_series(1,$ROWS) i" >/dev/null
  for n in $(seq 1 "$NIDX"); do
    case $n in
      1) Q "CREATE INDEX big_i1 ON big (a)" >/dev/null;;
      2) Q "CREATE INDEX big_i2 ON big (b)" >/dev/null;;
      3) Q "CREATE INDEX big_i3 ON big (c)" >/dev/null;;
      4) Q "CREATE INDEX big_i4 ON big (d)" >/dev/null;;
      5) Q "CREATE INDEX big_i5 ON big (a, b, c)" >/dev/null;;
    esac
  done
  # 이 테이블을 autovacuum 대상에서 뺀다. 전역 GUC 는 그대로 두어야 하한 계산이 낮게 남는다.
  Q "ALTER TABLE big SET (autovacuum_freeze_max_age = 2000000000, autovacuum_enabled = false)" >/dev/null
  Q "VACUUM (ANALYZE) big" >/dev/null
  # 죽은 튜플을 만든다. 20% 를 지우면 인덱스마다 그만큼 정리 대상이 생긴다.
  Q "DELETE FROM big WHERE id % 5 = 0" >/dev/null
  # XID 를 태워 age 를 실효 하한 위로 올린다. 쓰기 서브트랜잭션마다 XID 하나를 쓴다.
  Q "DROP TABLE IF EXISTS xidburn; CREATE TABLE xidburn (i int)" >/dev/null
  Q "DO \$\$ BEGIN FOR i IN 1..$BURN LOOP BEGIN INSERT INTO xidburn VALUES (i); EXCEPTION WHEN OTHERS THEN NULL; END; END LOOP; END \$\$" >/dev/null
  local size dead
  size=$(Q "SELECT pg_size_pretty(pg_total_relation_size('big'))")
  dead=$(Q "SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='big'")
  local age fmax eff
  age=$(Q "SELECT age(relfrozenxid) FROM pg_class WHERE relname='big'")
  fmax=$(Q "SHOW autovacuum_freeze_max_age")
  eff=$(( fs > fmax * 105 / 100 ? fs : fmax * 105 / 100 ))
  echo "  [$label] 크기 $size, 인덱스 ${NIDX}개, 죽은 튜플 ${dead}개"
  echo "  [$label] vacuum_failsafe_age=$fs, autovacuum_freeze_max_age=$fmax → 실효 하한 $eff"
  echo "  [$label] 테이블 age = $age  ($([ "$age" -gt "$eff" ] && echo "하한을 넘음 → 발동 예상" || echo "하한 미달 → 미발동 예상"))"

  # VACUUM VERBOSE 를 파일로 받아 시간과 인덱스 스캔 횟수를 뽑는다.
  local t0 t1 log
  t0=$(date +%s.%N)
  log=$(docker exec a14-pg psql -U postgres -d spoon \
        -c "SET vacuum_failsafe_age = $fs" \
        -c "VACUUM (VERBOSE, INDEX_CLEANUP AUTO) big" 2>&1)
  t1=$(date +%s.%N)
  printf "  [%s] VACUUM 소요 %.2f초\n" "$label" "$(echo "$t1-$t0" | bc)"
  echo "$log" | grep -iE "index scans|failsafe|bypassing|index \"big_|removable" | head -8 | sed 's/^/      /'
  echo "$log" > "$OUT/failsafe-$label.txt"

  # 거래 조건의 반대쪽. 인덱스 정리를 건너뛰면 그 인덱스로 도는 조회가 얼마를 더 내는가.
  # 같은 조회를 세 번 돌려 중앙값을 쓴다. 첫 회는 캐시 상태가 달라 흔들린다.
  local m1 m2 m3 med
  for k in 1 2 3; do
    eval "m$k=\$(docker exec a14-pg psql -U postgres -d spoon -qAt \
      -c \"EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM big WHERE b = 500\" 2>&1 \
      | grep -oE 'Execution Time: [0-9.]+' | grep -oE '[0-9.]+')"
  done
  med=$(printf '%s\n%s\n%s\n' "$m1" "$m2" "$m3" | sort -n | sed -n 2p)
  local bufs
  bufs=$(docker exec a14-pg psql -U postgres -d spoon -qAt \
    -c "EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM big WHERE b = 500" 2>&1 \
    | grep -oE "shared hit=[0-9]+( read=[0-9]+)?" | head -1)
  echo "  [$label] 그 뒤 big_i2 를 타는 조회: 중앙값 ${med}ms (3회: $m1, $m2, $m3), $bufs"
}

{
echo "# vacuum_failsafe_age 가 아끼는 것을 시간으로 잰다"
echo "# $(Q 'SELECT version()' | cut -c1-45)"
echo "# big ${ROWS}행, 보조 인덱스 ${NIDX}개, 20% 삭제"
echo "# maintenance_work_mem = $(Q 'SHOW maintenance_work_mem'), vacuum_cost_delay = $(Q 'SHOW vacuum_cost_delay')"
echo "# autovacuum = $(Q 'SHOW autovacuum'), autovacuum_freeze_max_age = $(Q 'SHOW autovacuum_freeze_max_age')"
echo "# XID 를 ${BURN}개 태워 테이블 age 를 실효 하한 위로 올립니다."
echo
echo "## 조건 A: failsafe 미발동 (16억. 실효 하한이 16억이 되어 age 12만으로는 못 넘는다)"
run_case A 1600000000
echo
echo "## 조건 B: failsafe 발동 (0 을 주면 실효 하한이 105,000 이 되어 age 12만이 넘는다)"
run_case B 0
echo
echo "## 정리"
echo "  A 는 인덱스를 전부 훑어 정리하고 B 는 그것을 건너뜁니다."
echo "  건너뛰는 대신 인덱스에 죽은 항목이 남으므로 조회가 그만큼 손해를 봅니다."
echo "  failsafe 는 wraparound 를 막기 위해 그 손해를 감수하는 장치입니다."
echo "  각 조건 1회 실행입니다."
} 2>&1 | tee "$OUT/exp-failsafe.txt"
