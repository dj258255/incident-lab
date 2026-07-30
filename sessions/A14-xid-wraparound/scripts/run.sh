#!/usr/bin/env bash
# XID wraparound의 세 구간을 순서대로 관측한다.
#
#   정상 → 경고(WARNING) → 읽기 전용(ERROR) → 복구
#
# 설계상 중요한 점이 넷 있다.
#
# 1) 원인은 vacuum을 끈 것이 아니다. wraparound 방지 autovacuum은 autovacuum=off
#    여도 반드시 돈다(이 랩에서 확인). 사고가 나는 것은 그 vacuum이 datfrozenxid를
#    전진시키지 못하게 막는 것이 있을 때다. 여기서는 버려진 prepared transaction을
#    쓴다. 재시작에도 살아남아 계속 xmin을 붙잡으므로 이 랩에 맞다.
#
# 2) 임계를 각각 가까이서 넘는다. 경고 직전으로 점프해 태워서 경고를 보고,
#    다시 정지 직전으로 점프해 태워서 정지를 본다. 21억 개를 다 태우면
#    반나절이 걸리고, 그렇다고 정지 임계를 이미 넘긴 디렉터리로 재시작하면
#    기동 과정이 끝나지 않는다(이 랩에서 확인). 두 점프 모두 정지 임계 아래에
#    착지하므로 재시작이 안전하다.
#
# 3) 임계 공식이 14에서 바뀌었다. 13 이하는 정지가 랩에서 100만 앞이고 경고가
#    정지에서 1,000만 앞이었다. 14부터 정지 300만, 경고는 랩에서 4,000만 앞이다.
#    Sentry 원문(2015년, 9.x)이 인용한 "100만 남으면 정지"는 지금 값이 아니다.
#
# 4) spoon 외의 데이터베이스를 먼저 동결해 둔다. 임계는 클러스터 전체에서
#    가장 오래된 datfrozenxid로 정해지므로, 그러지 않으면 경고 메시지가
#    엉뚱한 데이터베이스를 지목한다.
#
# 5) 복구는 수동으로 하지 않는다. 원인만 제거하고 기다린다. 그것이 PG17 문서가
#    지시하는 방식이고, 실제로 그렇게 복구되는지가 이 세션의 결론이다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
LOG="$OUT/timeline.txt"; : > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
# WARNING은 stderr로 오므로 값만 뽑을 때는 버린다.
N() { docker exec a14-pg psql -U postgres -d "${2:-spoon}" -qAt -c "$1" 2>/dev/null | grep -E '^-?[0-9]+$' | head -1; }
# 정지 상태에서는 txid_current()도 실패한다. 그것도 XID를 할당하기 때문이다.
# 관측에는 XID를 할당하지 않는 pg_current_snapshot()의 xmax를 쓴다.
XID() { N "SELECT pg_snapshot_xmax(pg_current_snapshot())::text::bigint"; }
Q() { docker exec a14-pg psql -U postgres -d spoon -qAt -c "$1" 2>&1; }
wait_up() { for _ in $(seq 1 90); do [ -n "$(N "SELECT 1")" ] && return 0; sleep 2; done; return 1; }

OLDEST=744
WRAP=$((OLDEST + 2147483648))
STOP=$((WRAP - 3000000))
WARN=$((WRAP - 40000000))
say "PostgreSQL $(N "SELECT current_setting('server_version_num')")"
say "oldestXid=$OLDEST  경고임계=$WARN  정지임계=$STOP  랩임계=$WRAP"
say "  (정지는 랩에서 300만 앞, 경고는 랩에서 4,000만 앞. PG14부터의 값이다)"

say ""
say "[1] 정상 상태"
# template0은 접속이 막혀 있어 vacuumdb가 건너뛴다. 임계는 클러스터 전체에서
# 가장 오래된 datfrozenxid로 정해지므로 여기를 빼면 복구가 끝나지 않는다.
freeze_all() {
  docker exec a14-pg psql -U postgres -qAt -c \
    "UPDATE pg_database SET datallowconn = true WHERE datname = 'template0'" >/dev/null 2>&1
  for db in postgres template1 template0 spoon; do
    docker exec a14-pg psql -U postgres -d "$db" -qAt -c "VACUUM FREEZE" >/dev/null 2>&1
  done
  docker exec a14-pg psql -U postgres -qAt -c \
    "UPDATE pg_database SET datallowconn = false WHERE datname = 'template0'" >/dev/null 2>&1
}
freeze_all
say "  age=$(N "SELECT age(datfrozenxid) FROM pg_database WHERE datname='spoon'")  쓰기=$(Q "INSERT INTO sponsor (live_id, amount) VALUES (1,1) RETURNING 'ok'" | head -1)"

say ""
say "[2] 동결을 막는 원인을 심는다: 버려진 prepared transaction"
Q "BEGIN; INSERT INTO sponsor (live_id, amount) VALUES (99,1); PREPARE TRANSACTION 'orphan-2020'" >/dev/null
say "  $(Q "SELECT 'gid='||gid||'  xid='||transaction FROM pg_prepared_xacts" | head -1)"

burn_until() {  # $1=목표 XID  $2=라벨
  local target="$1" label="$2" nx t0
  t0=$(date +%s)
  for _ in $(seq 1 400); do
    nx=$(XID); [ -n "$nx" ] || nx=0
    echo "$(( $(date +%s) - t0 )),$nx,$((WARN - nx)),$((STOP - nx))" >> "$OUT/burn.csv"
    [ "$nx" -ge "$target" ] && return 0
    docker exec a14-pg pgbench -U postgres -d spoon -n -f /scripts/burn.sql -c 16 -j 4 -T 3 >/dev/null 2>&1
    # 쓰기가 거부되기 시작하면 그 자리에서 멈춘다.
    if ! printf '%s' "$(Q "INSERT INTO sponsor (live_id, amount) VALUES (2,2) RETURNING 'ok'")" | grep -q '^ok$'; then
      return 1
    fi
  done
  return 2
}
: > "$OUT/burn.csv"; echo "elapsed_s,next_xid,to_warn,to_stop" >> "$OUT/burn.csv"

say ""
say "[3] 경고 임계 직전으로 점프한 뒤 태워서 경고를 넘는다"
bash "$ROOT/scripts/jump-xid.sh" $((WARN - 300000)) "$OLDEST" >>"$LOG" 2>&1
wait_up || { say "  기동 실패"; exit 1; }
say "  점프 직후 nextXid=$(XID)  (경고까지 $(( WARN - $(XID) ))개)"
burn_until "$WARN" warn || true
say "  경고 구간 진입: nextXid=$(XID)"
say "  서버가 남긴 문구:"
docker logs a14-pg 2>&1 | grep -A2 -m1 'must be vacuumed within' | sed 's/^/    /' | tee -a "$LOG"

say ""
say "[4] 정지 임계 직전으로 점프한 뒤 태워서 정지를 넘는다"
bash "$ROOT/scripts/jump-xid.sh" $((STOP - 400000)) "$OLDEST" >>"$LOG" 2>&1
wait_up || { say "  기동 실패"; exit 1; }
say "  점프 직후 nextXid=$(XID)  (정지까지 $(( STOP - $(XID) ))개)"
burn_until "$WRAP" stop; RC=$?
NX=$(XID)
if [ "$RC" = "1" ]; then
  say "  쓰기 거부: nextXid=$NX  (정지임계 $STOP 를 $((NX - STOP))개 넘음)"
  say "  클라이언트가 받은 문구:"
  Q "INSERT INTO sponsor (live_id, amount) VALUES (3,3)" | sed 's/^/    /' | tee -a "$LOG"
else
  say "  정지 지점에 닿지 못했다 (rc=$RC, nextXid=$NX)"
fi

say ""
say "[5] 정지 상태에서 되는 것과 안 되는 것"
say "  SELECT      : $(Q "SELECT count(*)||' 행' FROM sponsor" | grep -E '행$' | head -1)"
say "  INSERT      : $(Q "INSERT INTO sponsor (live_id, amount) VALUES (3,3)" | grep -iE '^(ERROR|INSERT)' | head -1)"
say "  DELETE      : $(Q "DELETE FROM sponsor WHERE id = 1" | grep -iE '^(ERROR|DELETE)' | head -1)"
say "  읽기전용 TX : $(Q "BEGIN READ ONLY; SELECT count(*) FROM sponsor; COMMIT" | grep -E '^[0-9]+$' | head -1) 행"
say "  VACUUM      : $(Q "VACUUM FREEZE sponsor" | grep -iE '^(ERROR|WARNING|VACUUM)' | head -1)"
say "  (문서: 진행 중 트랜잭션은 계속되고 읽기 전용만 시작할 수 있다. VACUUM은 정상 동작한다)"

say ""
say "[6] 원인을 그대로 두고 전체 VACUUM FREEZE"
Q "VACUUM FREEZE" >/dev/null 2>&1
say "  age=$(N "SELECT age(datfrozenxid) FROM pg_database WHERE datname='spoon'")   내려가지 않는다"
say "  공식 문서가 지목하는 세 용의자:"
say "    prepared xacts: $(N "SELECT count(*) FROM pg_prepared_xacts") 건  $(Q "SELECT 'xid='||transaction||' age='||age(transaction) FROM pg_prepared_xacts" | head -1)"
say "    장기 트랜잭션 : $(N "SELECT count(*) FROM pg_stat_activity WHERE backend_xid IS NOT NULL OR backend_xmin IS NOT NULL") 건"
say "    복제 슬롯     : $(N "SELECT count(*) FROM pg_replication_slots") 건"

say ""
say "[7] 원인을 제거하고 다시"
Q "ROLLBACK PREPARED 'orphan-2020'" >/dev/null 2>&1
Q "VACUUM FREEZE" >/dev/null 2>&1
say "  spoon만 동결한 뒤 age=$(N "SELECT age(datfrozenxid) FROM pg_database WHERE datname='spoon'")"
say "  그런데 쓰기는: $(Q "INSERT INTO sponsor (live_id, amount) VALUES (4,4) RETURNING 'ok'" | grep -E '^ok$|^ERROR' | head -1)"
say "  임계를 붙잡고 있는 것은 다른 데이터베이스다:"
docker exec a14-pg psql -U postgres -qAt -c \
  "SELECT '    '||datname||' age='||age(datfrozenxid) FROM pg_database ORDER BY age(datfrozenxid) DESC" 2>/dev/null | tee -a "$LOG"
say ""
say "[8] 손대지 않고 기다린다"
say "  wraparound 방지 autovacuum이 스스로 처리하는지 본다. 수동 VACUUM도,"
say "  단일 사용자 모드도 쓰지 않는다. PG17 문서가 그러지 말라고 명시한다."
for i in 1 2 3 4 5 6 7 8; do
  sleep 20
  ST=$(docker exec a14-pg psql -U postgres -qAt -c \
    "SELECT string_agg(datname||'='||age(datfrozenxid), ' ' ORDER BY age(datfrozenxid) DESC) FROM pg_database" 2>/dev/null)
  say "  +$((i * 20))초: $ST"
  printf '%s' "$(Q "INSERT INTO sponsor (live_id, amount) VALUES (4,4) RETURNING 'ok'")" | grep -q '^ok$' && { say "  쓰기 재개됨"; break; }
done
say ""
say "  autovacuum이 남긴 failsafe 기록 (PG14에 추가된 vacuum_failsafe_age):"
docker logs a14-pg 2>&1 | grep -m3 'as a failsafe after' | sed 's/^/    /' | tee -a "$LOG"
say "  최종: $(docker exec a14-pg psql -U postgres -qAt -c "SELECT string_agg(datname||'='||age(datfrozenxid), ' ' ORDER BY age(datfrozenxid) DESC) FROM pg_database" 2>/dev/null)"
say "  쓰기: $(Q "INSERT INTO sponsor (live_id, amount) VALUES (5,5) RETURNING 'ok'" | grep -E '^ok$|^ERROR' | head -1)"
say ""
say "타임라인 원문 results/timeline.txt, 태우기 곡선 results/burn.csv"
