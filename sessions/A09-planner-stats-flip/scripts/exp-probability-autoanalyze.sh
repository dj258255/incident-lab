#!/usr/bin/env bash
# README 의 "못 한 것" 세 개를 잡는다.
#
#   1) null_frac 이 1로 잡히는 정확한 확률을 계산하지 않았습니다
#      "단순 무작위 표본이라면 좀처럼 나오기 어려운 쪽인데 실측은 10회 중 1회입니다.
#       방향은 분명하지만 왜 곱이 예측하는 것보다 훨씬 자주 나오는지는 못 밝혔습니다."
#      시행을 10회에서 200회로 늘리고, 같은 조건의 이론 확률을 옆에 놓는다.
#      실측이 이론보다 높으면 ANALYZE 의 표본이 단순 무작위가 아니라는 뜻이다.
#      PostgreSQL 은 두 단계로 뽑는다. 블록을 먼저 고르고 그 안에서 행을 고른다.
#      값이 블록에 몰려 있으면 단순 무작위보다 "한 건도 못 잡을" 확률이 올라간다.
#
#   2) 한 컬럼만 target 을 올렸을 때의 비용을 재지 않았습니다
#      네 컬럼을 함께 올린 경우만 쟀다. ANALYZE 의 표본 크기는 컬럼별이 아니라
#      테이블 단위로 300 x (대상 컬럼 target 의 최댓값)이다. 그러면 한 컬럼만 올려도
#      표본 크기는 같아진다. 줄어드는 것이 있다면 표본이 아니라 저장되는 통계의 양이다.
#      그것이 실제로 얼마인지 잰다.
#
#   3) 자동 analyze 가 실제로 방아쇠가 되는 과정을 재현하지 않았습니다
#      ANALYZE 를 손으로 반복해 확률을 셌을 뿐이다. autovacuum_analyze_scale_factor 가
#      정한 시점에 그것이 걸리고 플랜이 뒤집히는 과정을 만든다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
CN=lab-a09-pg
TRIALS=${TRIALS:-200}

P(){ docker exec "$CN" psql -U lab -d ratelimit -X -qAt -c "$1" 2>&1; }
PT(){ docker exec "$CN" psql -U lab -d ratelimit -X -c "$1" 2>&1; }

for _ in $(seq 1 60); do [ "$(P 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(P 'SELECT 1')" = "1" ] || { echo "중단: $CN 이 쿼리를 받지 못합니다" >&2; exit 2; }

# 컨테이너를 새로 띄우면 테이블이 없다. 이 랩의 compose 는 scripts 를 마운트만 하고
# initdb 로 돌리지 않으므로 run.sh 가 00-seed.sql 을 따로 실행한다.
# 시드 없이 이 스크립트를 돌리면 모든 질의가 "relation does not exist" 를 돌려주고,
# 그 문자열이 숫자 자리에 그대로 들어가 "200회 중 0회" 같은 그럴듯한 값이 남는다.
# 없으면 만들고, 만든 뒤에도 없으면 멈춘다.
ROWS_NOW=$(P "SELECT COALESCE((SELECT count(*) FROM req_log), 0)" 2>/dev/null)
case "${ROWS_NOW:-0}" in
  ''|*[!0-9]*) ROWS_NOW=0 ;;
esac
if [ "$ROWS_NOW" -lt 1000000 ]; then
  echo "시드가 없습니다(${ROWS_NOW}행). 00-seed.sql 을 먼저 돌립니다. 몇 분 걸립니다."
  docker exec "$CN" psql -U lab -d ratelimit -X -q -v ON_ERROR_STOP=1 \
    -f /scripts/00-seed.sql > /dev/null 2>&1
  ROWS_NOW=$(P "SELECT COALESCE((SELECT count(*) FROM req_log), 0)" 2>/dev/null)
  case "${ROWS_NOW:-0}" in
    ''|*[!0-9]*) ROWS_NOW=0 ;;
  esac
fi
[ "$ROWS_NOW" -ge 1000000 ] || { echo "중단: req_log 가 ${ROWS_NOW}행입니다(기대 100만 이상)" >&2; exit 3; }
echo "시드 확인: req_log ${ROWS_NOW}행"

set_target_all(){
  P "ALTER TABLE req_log
       ALTER COLUMN id            SET STATISTICS $1,
       ALTER COLUMN org_id        SET STATISTICS $1,
       ALTER COLUMN status_code   SET STATISTICS $1,
       ALTER COLUMN blocked_until SET STATISTICS $1" >/dev/null
}
set_target_one(){
  P "ALTER TABLE req_log
       ALTER COLUMN id            SET STATISTICS -1,
       ALTER COLUMN org_id        SET STATISTICS -1,
       ALTER COLUMN status_code   SET STATISTICS -1,
       ALTER COLUMN blocked_until SET STATISTICS $1" >/dev/null
}
null_frac(){ P "SELECT null_frac FROM pg_stats WHERE tablename='req_log' AND attname='blocked_until'"; }

{
echo "# null_frac=1 의 확률, 컬럼 하나만 올리는 비용, 자동 analyze"
echo "# PostgreSQL $(P 'SHOW server_version')"
echo

# ── 데이터의 실제 모양 ──────────────────────────────────────────────────
TOTAL=$(P "SELECT count(*) FROM req_log")
NONNULL=$(P "SELECT count(*) FROM req_log WHERE blocked_until IS NOT NULL")
PAGES=$(P "SELECT relpages FROM pg_class WHERE relname='req_log'")
# non-null 이 몇 개의 블록에 흩어져 있는지. 이것이 이론과 실측을 가르는 값이다.
NNPAGES=$(P "SELECT count(DISTINCT (ctid::text::point)[0]::int) FROM req_log WHERE blocked_until IS NOT NULL")
echo "## 데이터"
echo "  전체 ${TOTAL}행, non-null ${NONNULL}행, 힙 ${PAGES}블록"
echo "  non-null 이 들어 있는 블록 = ${NNPAGES}개"
echo

# ── 1) 확률 ─────────────────────────────────────────────────────────────
echo "## 1) target=1 에서 null_frac=1 이 나오는 빈도"
echo "  ANALYZE 를 ${TRIALS}회 돌립니다."
set_target_all 1
ZERO=0
: > "$OUT/prob-trials.csv"
echo "trial,null_frac" >> "$OUT/prob-trials.csv"
for i in $(seq 1 "$TRIALS"); do
  P "ANALYZE req_log" >/dev/null
  NF=$(null_frac)
  echo "$i,$NF" >> "$OUT/prob-trials.csv"
  [ "$NF" = "1" ] && ZERO=$((ZERO + 1))
done
echo "  실측: ${TRIALS}회 중 ${ZERO}회"
python3 - "$TOTAL" "$NONNULL" "$PAGES" "$NNPAGES" "$TRIALS" "$ZERO" <<'PY'
import sys, math
total, nonnull, pages, nnpages, trials, zero = (int(x) for x in sys.argv[1:7])
n = 300                      # target=1 이면 표본 300행
# 단순 무작위 표본이라면
p_simple = math.exp(n * math.log1p(-nonnull / total)) if nonnull < total else 0.0
print(f"  단순 무작위 표본이라면 = {p_simple:.3e}  ({p_simple*trials:.4f}회 기대)")
# PostgreSQL 의 표본은 두 단계다. 블록을 먼저 고르고 그 안에서 행을 고른다.
# 고르는 블록 수는 표본 행 수와 같은 300개다(acquire_sample_rows).
blocks = min(n, pages)
p_block = math.exp(blocks * math.log1p(-nnpages / pages)) if nnpages < pages else 0.0
print(f"  블록을 300개 고른다고 보면 = {p_block:.3e}  ({p_block*trials:.4f}회 기대)")
print(f"  실측 비율 = {zero/trials:.4f}")
print()
print("  읽는 법. PostgreSQL 의 ANALYZE 는 단순 무작위 표본이 아닙니다.")
print("  acquire_sample_rows 가 블록을 먼저 뽑고 그 블록들 안에서만 행을 고릅니다.")
print("  그래서 값이 소수의 블록에 몰려 있으면 '한 건도 못 잡을' 확률이 단순 무작위보다")
print("  크게 올라갑니다. 위 두 이론값의 자릿수 차이가 그 몫입니다.")
PY
echo

# ── 2) 컬럼 하나만 올릴 때 ──────────────────────────────────────────────
echo "## 2) 네 컬럼을 함께 올릴 때와 한 컬럼만 올릴 때"
echo "  ANALYZE 의 표본 크기는 테이블 단위로 300 x (대상 컬럼 target 의 최댓값)입니다."
echo "  그러면 한 컬럼만 올려도 표본은 같아집니다. 줄어드는 것이 있는지 봅니다."
echo
printf "  %-22s %10s %14s %12s %10s\n" "조건" "ANALYZE" "pg_statistic" "저장된 값" "null_frac"
for mode in "네 컬럼 모두:all" "blocked_until 만:one"; do
  label="${mode%%:*}"; kind="${mode##*:}"
  for t in 100 1000; do
    if [ "$kind" = "all" ]; then set_target_all "$t"; else set_target_one "$t"; fi
    T0=$(date +%s%N)
    P "ANALYZE req_log" >/dev/null
    T1=$(date +%s%N)
    # 저장된 통계의 양. MCV 와 히스토그램 원소 수를 합친다.
    VALS=$(P "SELECT COALESCE(SUM(COALESCE(array_length(most_common_vals::text::text[],1),0)
                            + COALESCE(array_length(histogram_bounds::text::text[],1),0)),0)
              FROM pg_stats WHERE tablename='req_log'")
    SZ=$(P "SELECT pg_total_relation_size('pg_statistic')")
    printf "  %-22s %9.2fs %13sB %12s %10s\n" \
      "$label target=$t" \
      "$(python3 -c "print(($T1-$T0)/1e9)")" \
      "$SZ" "${VALS:-0}" "$(null_frac)"
  done
done
echo
echo "  ANALYZE 소요가 두 조건에서 비슷하면 표본 크기가 같다는 뜻입니다."
echo "  저장된 값의 개수만 갈립니다. 컬럼을 고르는 것으로 아끼는 것은 스캔이 아니라"
echo "  통계의 양과 그것을 읽는 플래너의 시간입니다."
echo

# ── 2-b) 플래너 시간을 직접 잰다 ───────────────────────────────────────
# 2절이 "통계의 양과 그것을 읽는 플래너의 시간" 을 아낀다고 적어 놓고 플래너 시간은
# 안 쟀다. EXPLAIN 은 SUMMARY 로 Planning Time 을 돌려준다. 그 값을 target 을 바꿔
# 가며 중앙값으로 잡는다. 실행 시간이 섞이지 않게 ANALYZE 없이 EXPLAIN 만 돌린다.
echo "## 2-b) target 이 플래너 시간을 얼마나 늘리는가"
echo "  2절은 통계의 양이 준다고만 적었습니다. 플래너 시간을 직접 잽니다."
echo "  EXPLAIN 의 Planning Time 을 조건마다 ${PLAN_REPS:-9}회 재고 중앙값을 씁니다."
echo
PLAN_REPS=${PLAN_REPS:-9}
PLAN_SQL="SELECT count(*) FROM req_log r
          JOIN ip_rule i ON i.org_id = r.org_id AND i.rule_kind = 'burst'
          WHERE r.blocked_until IS NOT NULL"
plan_ms(){
  P "EXPLAIN (COSTS OFF, SUMMARY ON) $PLAN_SQL" \
    | grep -i "Planning Time" | grep -oE "[0-9.]+" | head -1
}
: > "$OUT/planner-time.csv"
echo "target,rep,planning_ms,stat_bytes,stat_values" >> "$OUT/planner-time.csv"
printf "  %10s %28s %12s %14s %12s\n" "target" "회차별 Planning Time" "중앙" "pg_statistic" "저장된 값"
for t in 1 10 100 1000 10000; do
  set_target_all "$t"
  P "ANALYZE req_log" >/dev/null
  SZ=$(P "SELECT pg_total_relation_size('pg_statistic')")
  VALS=$(P "SELECT COALESCE(SUM(COALESCE(array_length(most_common_vals::text::text[],1),0)
                          + COALESCE(array_length(histogram_bounds::text::text[],1),0)),0)
            FROM pg_stats WHERE tablename='req_log'")
  VS=""
  for r in $(seq 1 "$PLAN_REPS"); do
    MS=$(plan_ms)
    case "${MS:-}" in ''|*[!0-9.]*) MS=0 ;; esac
    echo "$t,$r,$MS,${SZ:-0},${VALS:-0}" >> "$OUT/planner-time.csv"
    VS="$VS $MS"
  done
  MED=$(echo $VS | tr ' ' '\n' | grep -v '^$' | sort -g | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
  printf "  %10s %28s %10sms %13sB %12s\n" "$t" "[$(echo $VS | tr ' ' ',' | cut -c1-26)]" \
    "${MED:-?}" "${SZ:-?}" "${VALS:-?}"
done
echo
echo "  플래너는 조건마다 통계를 읽어 선택도를 계산합니다. MCV 목록과 히스토그램이"
echo "  길수록 그 계산이 오래 걸립니다. 위 표의 증가분이 target 을 올리는 값입니다."
echo "  질의 하나의 플래닝이므로, 초당 수천 건이 도는 서버에서는 이 값에 그만큼 곱합니다."
echo

# ── 3) 자동 analyze 가 방아쇠가 되는 과정 ───────────────────────────────
echo "## 3) 자동 analyze 가 플랜을 뒤집는 순간"
echo "  손으로 ANALYZE 를 돌린 것이 아니라, autovacuum 이 정한 시점에 걸리게 합니다."
set_target_all 1
# 임계값을 낮춰 쓰기 몇 건으로 걸리게 한다. 기본값 0.1 은 이 테이블에서 수십만 행이다.
P "ALTER TABLE req_log SET (autovacuum_analyze_scale_factor = 0.001,
                            autovacuum_analyze_threshold = 50)" >/dev/null
P "ALTER SYSTEM SET autovacuum_naptime = '5s'" >/dev/null
P "SELECT pg_reload_conf()" >/dev/null
echo "  autovacuum_analyze_scale_factor=0.001, threshold=50, naptime=5s"
BEFORE=$(P "SELECT COALESCE(last_autoanalyze::text,'없음') FROM pg_stat_user_tables WHERE relname='req_log'")
echo "  직전 last_autoanalyze = $BEFORE"

# 플랜이 뒤집힐 때까지 쓰기를 넣고 기다린다. 관측 창을 넉넉히 둔다.
FLIPPED=0
for round in $(seq 1 24); do
  P "INSERT INTO req_log (org_id, status_code, blocked_until)
     SELECT (random()*1000)::int, 200, NULL FROM generate_series(1, 5000)" >/dev/null
  sleep 5
  AFTER=$(P "SELECT COALESCE(last_autoanalyze::text,'없음') FROM pg_stat_user_tables WHERE relname='req_log'")
  if [ "$AFTER" != "$BEFORE" ]; then
    NF=$(null_frac)
    EST=$(P "EXPLAIN SELECT id FROM req_log WHERE blocked_until IS NOT NULL" \
          | grep -oE 'rows=[0-9]+' | head -1 | cut -d= -f2)
    echo "  ${round}번째 묶음 뒤에 autoanalyze 가 걸렸습니다."
    echo "    last_autoanalyze = $AFTER"
    echo "    null_frac = $NF, 추정 행 수 = $EST (실제 non-null = ${NONNULL})"
    FLIPPED=1
    BEFORE="$AFTER"
    if [ "$NF" = "1" ]; then
      echo "    **자동 analyze 가 null_frac 을 1로 잡았습니다.** 사람이 아무것도 안 했는데"
      echo "    플래너의 추정이 바뀌는 순간이 이것입니다."
      break
    fi
  fi
done
[ "$FLIPPED" = "1" ] || echo "  관측 창 안에 autoanalyze 가 걸리지 않았습니다."
echo
echo "  플랜을 조건마다 확인합니다:"
PT "EXPLAIN (COSTS ON) SELECT count(*) FROM req_log r
    JOIN ip_rule i ON i.org_id = r.org_id AND i.rule_kind = 'burst'
    WHERE r.blocked_until IS NOT NULL" | head -12 | sed 's/^/    /'

# 설정을 되돌린다. 다음 실행이 이 값을 물려받으면 안 된다.
P "ALTER TABLE req_log RESET (autovacuum_analyze_scale_factor, autovacuum_analyze_threshold)" >/dev/null
P "ALTER SYSTEM RESET autovacuum_naptime" >/dev/null
P "SELECT pg_reload_conf()" >/dev/null
echo
echo "  설정을 되돌렸습니다. 각 조건 1회 실행이고 1절만 ${TRIALS}회입니다."
} 2>&1 | tee "$OUT/exp-probability-autoanalyze.txt"
