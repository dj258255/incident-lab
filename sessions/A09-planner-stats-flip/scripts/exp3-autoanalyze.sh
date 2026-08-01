#!/usr/bin/env bash
# 자동 analyze 를 관측 창 안에 거는 조건을 찾는다.
# 7절에서 scale_factor 를 0.001 로 낮추고 12만 행을 넣었는데 last_autoanalyze 가
# 안 바뀌었다. 이유를 확인하지 못했다고 적었다. 무엇이 빠졌는지 짚는다.
#
# autovacuum 이 도는 조건은 셋이다. 데몬이 켜져 있어야 하고, 테이블별 설정이 맞아야
# 하고, **naptime 마다 도는 워커가 그 테이블을 집어야** 한다. 기본 naptime 은 60초다.
# 12만 행을 넣고 몇 초 안에 확인하면 아직 안 돈 것이 당연하다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
C=a09-aa; N=${N:-300000}

echo "condition,naptime,scale_factor,threshold,waited_s,autoanalyzed,n_mod_since" > "$OUT/autoanalyze.csv"
{
echo "# 자동 analyze 를 관측 창 안에 거는 조건"
echo
printf "  %-34s %8s %10s %14s\n" "조건" "대기(초)" "돌았는가" "n_mod_since_analyze"
for CASE in "60 0.001 50" "1 0.001 50" "1 0.0 0"; do
  set -- $CASE; NAP=$1; SF=$2; TH=$3
  docker rm -f "$C" >/dev/null 2>&1
  docker run -d --name "$C" -e POSTGRES_PASSWORD=lab -e POSTGRES_DB=lab postgres:17.5 \
    -c autovacuum=on -c autovacuum_naptime=${NAP}s -c log_autovacuum_min_duration=0 >/dev/null
  P(){ docker exec -i "$C" psql -U postgres -d lab -At -c "$1" 2>&1; }
  for _ in $(seq 1 90); do [ "$(P 'SELECT 1')" = "1" ] && break; sleep 2; done
  P "CREATE TABLE t(id serial PRIMARY KEY, v int);
     ALTER TABLE t SET (autovacuum_analyze_scale_factor=$SF, autovacuum_analyze_threshold=$TH);
     INSERT INTO t(v) SELECT g FROM generate_series(1,$N) g;
     ANALYZE t;" >/dev/null
  BEFORE=$(P "SELECT COALESCE(last_autoanalyze::text,'없음') FROM pg_stat_user_tables WHERE relname='t'")
  # 통계를 흔들 만큼 갱신한다
  P "UPDATE t SET v = v + 1 WHERE id <= $((N/2));" >/dev/null
  WAITED=0; GOT=없음
  for w in $(seq 1 24); do
    sleep 5; WAITED=$((WAITED+5))
    A=$(P "SELECT COALESCE(last_autoanalyze::text,'') FROM pg_stat_user_tables WHERE relname='t'")
    [ -n "$A" ] && [ "$A" != "$BEFORE" ] && { GOT="**돌았음**"; break; }
  done
  MOD=$(P "SELECT COALESCE(n_mod_since_analyze,0) FROM pg_stat_user_tables WHERE relname='t'")
  printf "  %-34s %8s %10s %14s\n" "naptime=${NAP}s scale=$SF thr=$TH" "$WAITED" "$GOT" "${MOD:-?}"
  echo "naptime=${NAP}s scale=$SF thr=$TH,$NAP,$SF,$TH,$WAITED,$GOT,${MOD:-0}" >> "$OUT/autoanalyze.csv"
  docker rm -f "$C" >/dev/null 2>&1
done
echo
echo "  autovacuum_naptime 기본값은 60초입니다. 갱신 직후 몇 초 안에 확인하면"
echo "  워커가 아직 한 바퀴도 안 돈 상태라 last_autoanalyze 가 당연히 그대로입니다."
} 2>&1 | tee "$OUT/exp3-autoanalyze.txt"
