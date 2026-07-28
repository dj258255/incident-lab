#!/usr/bin/env bash
# A09 실험 전체를 순서대로 돌린다. 세션 디렉터리에서 `bash scripts/run.sh` 하나면 끝난다.
#
#   0.  환경 기동과 데이터 적재
#   1.  statistics target 1에서 ANALYZE를 null_frac이 1로 잡힐 때까지 돌린다
#   2.  그 상태에서 조인 쿼리 계측         -> 추정 1행 대 실제 2,400행
#   2b. 같은 target에서 샘플이 non-null을 딱 한 행 잡은 경우도 따로 계측
#   3.  statistics target 1000으로 올리고 ANALYZE 후 같은 쿼리 재계측
#   4.  대조군: 같은 오추정에서 안쪽이 싼 표를 만나면 어떻게 되는가
#   5.  샘플 사다리: target별로 ANALYZE를 반복해 null_frac=1이 나오는 빈도
#   6.  GoCardless 쪽: 물리적 행 순서만 다른 두 표의 n_distinct 비교
#
# 환경은 마지막에 살려 둔다. 정리는 docker compose down -v.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"
CN=lab-a09-pg
REPS="${REPS:-5}"
mkdir -p "$OUT"

PSQL()  { docker exec "$CN" psql -U lab -d ratelimit -X "$@"; }
PSQLQ() { docker exec "$CN" psql -U lab -d ratelimit -X -q -A -t "$@"; }

FLIP_SQL="SELECT count(*) FROM req_log r
          JOIN ip_rule i ON i.org_id = r.org_id AND i.rule_kind = 'burst'
         WHERE r.blocked_until IS NOT NULL;"
CTRL_SQL="SELECT count(*), max(p.rpm_limit) FROM req_log r
          JOIN org_plan p ON p.org_id = r.org_id
         WHERE r.blocked_until IS NOT NULL;"

# req_log의 모든 컬럼에 같은 statistics target을 건다.
# ANALYZE의 샘플 크기는 컬럼별이 아니라 테이블 단위로 300 x (분석 대상 컬럼 target의 최댓값)이다.
# 한 컬럼만 낮추면 나머지 컬럼의 기본값 100이 그대로 샘플 크기를 결정해 버린다.
set_target() {
  PSQL -q -c "ALTER TABLE req_log
                ALTER COLUMN id            SET STATISTICS $1,
                ALTER COLUMN org_id        SET STATISTICS $1,
                ALTER COLUMN status_code   SET STATISTICS $1,
                ALTER COLUMN blocked_until SET STATISTICS $1;"
}
null_frac() {
  PSQLQ -c "SELECT null_frac FROM pg_stats WHERE tablename='req_log' AND attname='blocked_until';"
}
est_rows() {
  PSQLQ -c "EXPLAIN SELECT id FROM req_log WHERE blocked_until IS NOT NULL;" \
    | grep -oE 'rows=[0-9]+' | head -1 | cut -d= -f2
}
# ANALYZE는 300행을 무작위로 뽑는다. 원하는 상태가 나올 때까지 다시 돌리고 횟수를 센다.
#   $1 = eq  -> null_frac이 1이 될 때까지
#   $1 = ne  -> null_frac이 1이 아닐 때까지
analyze_until() {
  local mode="$1" tries=0 nf
  while [ "$tries" -lt 200 ]; do
    PSQL -q -c "ANALYZE req_log;"
    tries=$((tries + 1))
    nf=$(null_frac)
    if [ "$mode" = eq ] && [ "$nf" = "1" ]; then break; fi
    if [ "$mode" = ne ] && [ "$nf" != "1" ]; then break; fi
  done
  ANALYZE_TRIES="$tries"
  ANALYZE_NF="$nf"
}

# EXPLAIN (ANALYZE, BUFFERS)를 REPS회 돌려 실행 시간을 모으고, 중앙값 회차의 플랜을 대표로 남긴다.
measure() {
  local prefix="$1" sql="$2"
  : > "$OUT/$prefix-times.txt"
  for i in $(seq 1 "$REPS"); do
    PSQL -q -c "EXPLAIN (ANALYZE, BUFFERS) $sql" > "$OUT/$prefix-run$i.txt" 2>&1
    local t
    t=$(grep -oE 'Execution Time: [0-9.]+' "$OUT/$prefix-run$i.txt" | grep -oE '[0-9.]+')
    printf '%s %s\n' "$i" "$t" >> "$OUT/$prefix-times.txt"
    echo "  [$prefix] $i회차 ${t} ms"
  done
  local med_i
  med_i=$(sort -k2 -n "$OUT/$prefix-times.txt" | awk -v n="$REPS" 'NR==int((n+1)/2){print $1}')
  cp "$OUT/$prefix-run$med_i.txt" "$OUT/$prefix-plan.txt"
  MEDIAN=$(sort -k2 -n "$OUT/$prefix-times.txt" | awk -v n="$REPS" 'NR==int((n+1)/2){print $2}')
  echo "  [$prefix] 중앙값 ${MEDIAN} ms (${REPS}회, ${med_i}회차 플랜을 $prefix-plan.txt)"
}

echo "== 0. 환경 기동 =="
( cd "$ROOT" && docker compose up -d )
for _ in $(seq 1 60); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$CN" 2>/dev/null)" = healthy ] && break
  sleep 2
done
PSQL -c "SELECT version();" | tee "$OUT/00-version.txt"
PSQL -c "SHOW default_statistics_target;" -c "SHOW shared_buffers;" \
     -c "SHOW max_parallel_workers_per_gather;" -c "SHOW autovacuum;" -c "SHOW jit;" \
     | tee -a "$OUT/00-version.txt"

echo
echo "== 0-1. 데이터 적재 =="
PSQL -v ON_ERROR_STOP=1 -f /scripts/00-seed.sql > "$OUT/00-seed.txt" 2>&1
tail -12 "$OUT/00-seed.txt"

echo
echo "== 1-0. 문제 컬럼 하나만 target 1로 낮춰 본다 =="
# 샘플 크기는 컬럼별이 아니라 테이블 단위로 정해진다. 이 단계는 그것을 눈으로 확인한다.
PSQL -q -c "ALTER TABLE req_log
              ALTER COLUMN id            SET STATISTICS -1,
              ALTER COLUMN org_id        SET STATISTICS -1,
              ALTER COLUMN status_code   SET STATISTICS -1,
              ALTER COLUMN blocked_until SET STATISTICS 1;"
{
  PSQL -c "ANALYZE req_log;"
  PSQL -c "SELECT attname, attstattarget FROM pg_attribute
             WHERE attrelid='req_log'::regclass AND attnum>0 ORDER BY attnum;"
  PSQL -c "SELECT attname, null_frac, n_distinct FROM pg_stats
             WHERE tablename='req_log' AND attname='blocked_until';"
  PSQL -c "EXPLAIN SELECT id FROM req_log WHERE blocked_until IS NOT NULL;"
} > "$OUT/09-one-column.txt" 2>&1
cat "$OUT/09-one-column.txt"

echo
echo "== 1. statistics target 1에서 ANALYZE (null_frac=1이 될 때까지) =="
set_target 1
analyze_until eq
echo "  ANALYZE ${ANALYZE_TRIES}회 만에 null_frac=${ANALYZE_NF}"
{
  echo "\$ ALTER TABLE req_log ALTER COLUMN ... SET STATISTICS 1;   -- 샘플 300행"
  echo "\$ ANALYZE req_log;                                          -- ${ANALYZE_TRIES}회째에 아래 상태"
  PSQL -c "SELECT attname, null_frac, n_distinct, array_length(histogram_bounds,1) AS hist
             FROM pg_stats WHERE tablename='req_log' ORDER BY attname;"
  echo "-- 실제 분포"
  PSQL -c "SELECT count(*) AS total, count(blocked_until) AS non_null,
                  1.0 - count(blocked_until)::numeric/count(*) AS real_null_frac
             FROM req_log;"
  echo "-- 플래너가 잡은 추정 행수"
  PSQL -c "EXPLAIN SELECT id FROM req_log WHERE blocked_until IS NOT NULL;"
} > "$OUT/10-stats-broken.txt" 2>&1
cat "$OUT/10-stats-broken.txt"
BROKEN_EST=$(est_rows)

echo
echo "== 2. 오추정 상태에서 조인 쿼리 계측 =="
measure "11-broken" "$FLIP_SQL"
BROKEN_MED="$MEDIAN"

echo
echo "== 2b. 같은 target 1에서 샘플이 non-null을 잡은 경우 =="
analyze_until ne
echo "  ANALYZE ${ANALYZE_TRIES}회 만에 null_frac=${ANALYZE_NF}"
HIT_TRIES="$ANALYZE_TRIES"; HIT_NF="$ANALYZE_NF"
{
  echo "\$ ANALYZE req_log;   -- 같은 statistics target 1, 샘플이 non-null을 잡은 회차 (${HIT_TRIES}회째)"
  PSQL -c "SELECT attname, null_frac, n_distinct FROM pg_stats
             WHERE tablename='req_log' AND attname='blocked_until';"
  PSQL -c "EXPLAIN SELECT id FROM req_log WHERE blocked_until IS NOT NULL;"
} > "$OUT/12-stats-broken-hit.txt" 2>&1
cat "$OUT/12-stats-broken-hit.txt"
HIT_EST=$(est_rows)
measure "13-broken-hit" "$FLIP_SQL"
HIT_MED="$MEDIAN"

echo
echo "== 3. statistics target 1000으로 올리고 ANALYZE 후 재계측 =="
set_target 1000
PSQL -c "ANALYZE req_log;"
{
  echo "\$ ALTER TABLE req_log ALTER COLUMN ... SET STATISTICS 1000;   -- 샘플 300,000행"
  echo "\$ ANALYZE req_log;"
  PSQL -c "SELECT attname, null_frac, n_distinct, array_length(histogram_bounds,1) AS hist
             FROM pg_stats WHERE tablename='req_log' ORDER BY attname;"
  echo "-- 플래너가 잡은 추정 행수"
  PSQL -c "EXPLAIN SELECT id FROM req_log WHERE blocked_until IS NOT NULL;"
} > "$OUT/20-stats-fixed.txt" 2>&1
cat "$OUT/20-stats-fixed.txt"
FIXED_NF=$(null_frac); FIXED_EST=$(est_rows)
measure "21-fixed" "$FLIP_SQL"
FIXED_MED="$MEDIAN"

echo
echo "== 4. 대조군: 같은 오추정, 안쪽이 싼 표 =="
set_target 1
analyze_until eq
echo "  null_frac=${ANALYZE_NF} (ANALYZE ${ANALYZE_TRIES}회)"
measure "30-ctrl-broken" "$CTRL_SQL"
CTRL_BROKEN="$MEDIAN"
set_target 1000
PSQL -q -c "ANALYZE req_log;"
measure "31-ctrl-fixed" "$CTRL_SQL"
CTRL_FIXED="$MEDIAN"

echo
echo "== 5. 샘플 사다리: target별 ANALYZE 반복 =="
: > "$OUT/41-sampling-summary.txt"
echo "target,sample_rows,run,null_frac,est_rows" > "$OUT/40-sampling.csv"
for T in 1 10 100 1000; do
  set_target "$T"
  case "$T" in 1|10) N=40 ;; 100) N=10 ;; *) N=5 ;; esac
  ZERO=0
  for i in $(seq 1 "$N"); do
    PSQL -q -c "ANALYZE req_log;"
    NF=$(null_frac); EST=$(est_rows)
    echo "$T,$((300 * T)),$i,$NF,$EST" >> "$OUT/40-sampling.csv"
    [ "$NF" = "1" ] && ZERO=$((ZERO + 1))
  done
  echo "target=$T sample=$((300 * T))행 null_frac=1 이 $N회 중 $ZERO회" | tee -a "$OUT/41-sampling-summary.txt"
done

echo
echo "== 6. GoCardless 쪽: 물리적 행 순서만 다른 두 표의 n_distinct =="
{
  echo "-- 두 표의 행 내용은 같다. payout_id 하나에 20행씩, 실제 distinct = 150,000."
  echo "-- clustered는 payout_id 순으로, shuffled는 흩어서 넣었다."
  for T in 1 10 100; do
    docker exec "$CN" psql -U lab -d ratelimit -X -q \
      -c "ALTER TABLE payout_txn_clustered ALTER COLUMN payout_id SET STATISTICS $T, ALTER COLUMN id SET STATISTICS $T, ALTER COLUMN amount SET STATISTICS $T;
          ALTER TABLE payout_txn_shuffled  ALTER COLUMN payout_id SET STATISTICS $T, ALTER COLUMN id SET STATISTICS $T, ALTER COLUMN amount SET STATISTICS $T;
          ANALYZE payout_txn_clustered, payout_txn_shuffled;"
    echo
    echo "-- statistics target = $T (샘플 $((300 * T))행)"
    PSQL -c "SELECT tablename, n_distinct, round(correlation::numeric,4) AS correlation
               FROM pg_stats WHERE attname='payout_id' ORDER BY tablename;"
    PSQL -c "EXPLAIN SELECT * FROM payout_txn_clustered WHERE payout_id = 777;"
    PSQL -c "EXPLAIN SELECT * FROM payout_txn_shuffled  WHERE payout_id = 777;"
  done
  echo "-- 실제 매칭 행수"
  PSQL -c "SELECT (SELECT count(*) FROM payout_txn_clustered WHERE payout_id=777) AS clustered,
                  (SELECT count(*) FROM payout_txn_shuffled  WHERE payout_id=777) AS shuffled;"
} > "$OUT/50-ndistinct.txt" 2>&1
cat "$OUT/50-ndistinct.txt"

echo
echo "== 7. 해소의 값: target별 ANALYZE 소요 시간과 통계 크기 =="
{
  echo "-- ANALYZE 소요 시간 (req_log 12,000,000행 / 507MB, psql \timing, target별 3회)"
  for T in 1 100 1000 10000; do
    set_target "$T"
    echo "target=$T (샘플 $((300 * T))행)"
    PSQL -q -c "\timing on" -c "ANALYZE req_log;" -c "ANALYZE req_log;" -c "ANALYZE req_log;" | grep -i time
    PSQLQ -c "SELECT '  pg_statistic 총 크기 = ' || pg_size_pretty(pg_total_relation_size('pg_statistic'))
                  || ', blocked_until 히스토그램 = ' || COALESCE(array_length(histogram_bounds,1)::text,'없음')
                  || ', null_frac = ' || null_frac
                FROM pg_stats WHERE tablename='req_log' AND attname='blocked_until';"
  done
} > "$OUT/60-analyze-cost.txt" 2>&1
cat "$OUT/60-analyze-cost.txt"

echo
echo "== 정리 =="
{
  echo "PostgreSQL 16.14, req_log 12,000,000행 중 non-null 2,400행(99.98% NULL), ${REPS}회 중앙값"
  echo "상태                        null_frac   추정행수   중앙값"
  echo "target 1, 샘플이 다 NULL    ${ANALYZE_NF:-1}           ${BROKEN_EST}          ${BROKEN_MED} ms"
  echo "target 1, non-null 1행 잡음 ${HIT_NF}   ${HIT_EST}      ${HIT_MED} ms"
  echo "target 1000                 ${FIXED_NF}     ${FIXED_EST}       ${FIXED_MED} ms"
  echo "대조군(org_plan) 오추정                             ${CTRL_BROKEN} ms"
  echo "대조군(org_plan) 해소                               ${CTRL_FIXED} ms"
} | tee "$OUT/90-summary.txt"

echo
echo "환경은 살아 있다. 정리하려면: cd $ROOT && docker compose down -v"
