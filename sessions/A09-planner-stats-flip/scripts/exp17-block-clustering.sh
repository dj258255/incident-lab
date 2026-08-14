#!/usr/bin/env bash
# A09 exp17 — 기본값 target=100 에서 null_frac=1 이 왜 자주 나는지.
#
# 남아 있던 물음. 41-sampling 은 target=100 에서 10회 중 1회를 봤고, 단순 무작위
# 표본으로 계산하면 0.25% 라 40배 차이였다. 그런데 10회는 확률을 재기에 너무 적어
# 신뢰구간이 [0.25%, 45%] 였다. 그래서 "못 밝혔다"로 남겼다.
#
# 여기서는 두 가지를 바꾼다.
#
#   1) 희귀 사건(null_frac=1)을 세지 않고 표본에 들어온 non-null 개수를 매 회 기록한다.
#      null_frac 하나로 개수가 복원된다: count = round(30000 * (1 - null_frac)).
#      개수의 분산은 회당 얻는 정보가 훨씬 많아 300회로도 모형이 갈린다.
#
#   2) 대조군을 만든다. 같은 2,400건을 물리적으로 흩뿌린 표를 하나 더 만든다.
#      시드가 non-null 을 표 맨 뒤에 붙여서 마지막 17블록에 몰려 있는데, 그것이
#      원인이라면 흩뿌린 쪽에서는 단순 무작위 예측과 맞아야 한다.
#
# PostgreSQL 의 ANALYZE 는 두 단계다(src/backend/commands/analyze.c).
#   Stage one selects up to targrows random blocks
#   Stage two ... uses the Vitter algorithm to create a random sample of targrows rows
# 같은 파일의 주석이 한계도 적어 둔다.
#   For large relations the number of different blocks represented by the sample
#   tends to be too small.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
CN=lab-a09-pg
TRIALS=${TRIALS:-300}

P(){ docker exec "$CN" psql -U lab -d ratelimit -X -qAt -c "$1" 2>&1; }

for _ in $(seq 1 60); do [ "$(P 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(P 'SELECT 1')" = "1" ] || { echo "중단: $CN 이 쿼리를 받지 못합니다" >&2; exit 2; }

ROWS=$(P "SELECT count(*) FROM req_log")
[ "${ROWS:-0}" = "12000000" ] || { echo "중단: req_log 가 ${ROWS}행입니다(기대 12000000)" >&2; exit 3; }

# ── 대조군: 같은 2,400건을 1,200만 행에 고르게 흩뿌린다 ──────────────────────
# 5,000행마다 하나. 블록당 약 185행이므로 non-null 사이 간격이 약 27블록이 되어
# non-null 이 든 블록이 2,400개가 된다. 집중형은 17개다.
echo "대조군 표를 만듭니다(1,200만 행). 몇 분 걸립니다."
P "DROP TABLE IF EXISTS req_log_spread" >/dev/null
P "CREATE TABLE req_log_spread (LIKE req_log)" >/dev/null
P "INSERT INTO req_log_spread (id, org_id, status_code, blocked_until)
   SELECT g, (g % 100) + 1,
          CASE WHEN g % 5000 = 0 THEN 429 ELSE 200 END,
          CASE WHEN g % 5000 = 0
               THEN TIMESTAMPTZ '2026-07-28 00:00:00+00' + ((g / 5000) || ' seconds')::interval
               ELSE NULL END
   FROM generate_series(1, 12000000) g" >/dev/null

P "DROP TABLE IF EXISTS a09_trial" >/dev/null
P "CREATE TABLE a09_trial (tbl text, run int, null_frac float8)" >/dev/null

set_target(){  # $1=표 $2=target. ANALYZE 표본은 표 단위로 300 x (컬럼 target 최댓값)
  P "ALTER TABLE $1
       ALTER COLUMN id            SET STATISTICS $2,
       ALTER COLUMN org_id        SET STATISTICS $2,
       ALTER COLUMN status_code   SET STATISTICS $2,
       ALTER COLUMN blocked_until SET STATISTICS $2" >/dev/null
}

shape(){  # 표의 물리적 모양. non-null 이 몇 블록에 흩어져 있는지가 이 실험의 변수다
  local t=$1
  local pages nn nnp
  pages=$(P "SELECT relpages FROM pg_class WHERE relname='$t'")
  nn=$(P "SELECT count(*) FROM $t WHERE blocked_until IS NOT NULL")
  nnp=$(P "SELECT count(DISTINCT (ctid::text::point)[0]::int) FROM $t WHERE blocked_until IS NOT NULL")
  echo "$pages $nn $nnp"
}

run_trials(){  # $1=표. ANALYZE 를 TRIALS 회 돌리며 null_frac 을 남긴다
  local t=$1
  docker exec "$CN" psql -U lab -d ratelimit -X -q -c "
    DO \$\$
    DECLARE i int; nf float8;
    BEGIN
      FOR i IN 1..$TRIALS LOOP
        ANALYZE $t;
        SELECT null_frac INTO nf FROM pg_stats
         WHERE tablename='$t' AND attname='blocked_until';
        INSERT INTO a09_trial VALUES ('$t', i, nf);
      END LOOP;
    END \$\$;" 2>&1 | grep -v '^$'
}

{
echo "# 기본값 target=100 에서 null_frac=1 이 왜 자주 나는가"
echo "# PostgreSQL $(P 'SHOW server_version') · 시행 ${TRIALS}회 x 2조건"
echo

echo "## 두 표의 물리적 모양"
printf '  %-18s %10s %10s %14s\n' 표 힙블록 non-null "non-null이 든 블록"
for t in req_log req_log_spread; do
  set_target "$t" 100
  P "ANALYZE $t" >/dev/null
  read -r pages nn nnp <<<"$(shape "$t")"
  printf '  %-18s %10s %10s %14s\n' "$t" "$pages" "$nn" "$nnp"
  eval "PAGES_$t=$pages; NN_$t=$nn; NNP_$t=$nnp"
done
echo
echo "  같은 1,200만 행·같은 2,400건인데 non-null 이 든 블록 수만 다릅니다."
echo "  시드가 차단 요청 2,400건을 표 맨 뒤에 붙여서 집중형이 나왔습니다."
echo "  (실서비스의 차단 로그도 버스트로 몰려 들어오므로 이 모양 자체는 현실적입니다)"
echo

echo "## ANALYZE ${TRIALS}회씩"
for t in req_log req_log_spread; do
  echo -n "  $t 돌리는 중... "
  run_trials "$t"
  echo "완료"
done
echo

# ── 집계 ────────────────────────────────────────────────────────────────
echo "## 표본에 들어온 non-null 개수"
P "SELECT '  ' || rpad(tbl, 18)
       || lpad(round(avg((1 - null_frac) * 30000)::numeric, 2)::text, 8)
       || lpad(round(var_samp((1 - null_frac) * 30000)::numeric, 2)::text, 10)
       || lpad(min(round((1 - null_frac) * 30000))::text, 8)
       || lpad(max(round((1 - null_frac) * 30000))::text, 8)
       || lpad(count(*) FILTER (WHERE null_frac = 1)::text, 8)
   FROM a09_trial GROUP BY tbl ORDER BY tbl DESC"
echo "  (열: 표 · 평균 · 분산 · 최소 · 최대 · null_frac=1 회수)"
echo

echo "## 원자료"
P "COPY (SELECT tbl, run, null_frac FROM a09_trial ORDER BY tbl, run)
   TO STDOUT WITH CSV HEADER" > "$OUT/exp17-trials.csv"
echo "  results/exp17-trials.csv 에 ${TRIALS}회 x 2조건"
} 2>&1 | tee "$OUT/exp17-block-clustering.txt"

echo
echo "기록: $OUT/exp17-block-clustering.txt"
