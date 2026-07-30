#!/usr/bin/env bash
# PostgreSQL PITR. 원 사례가 PostgreSQL인데 1차 재현은 MySQL만 했다.
#
# 조사에서 확인한 두 기본값을 실제로 밟는다.
#   recovery_target_action 기본 pause      → 목표에 닿아도 서버가 안 열린다
#   recovery_target_inclusive 기본 on      → 목표 시각의 트랜잭션이 포함된다
#
# 두 번째는 사정거리가 좁다. inclusive 는 목표 시각과 커밋 시각이 정확히 같은
# 트랜잭션 하나만 가른다. 목표가 커밋보다 조금이라도 뒤면 off 로 둬도 사고가 들어온다.
# 그래서 복구를 넷으로 나눠 그 경계를 직접 밟는다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
Q(){ docker exec a23-pg psql -U postgres -d spoon -qAt -c "$1" 2>/dev/null; }
RQ(){ docker exec -u postgres a23-pgrestore psql -d spoon -qAt -c "$1" 2>&1 | head -1; }

for _ in $(seq 1 90); do [ "$(Q 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(Q 'SELECT 1')" = "1" ] || { echo "중단: postgres가 쿼리를 받지 못합니다" >&2; exit 2; }
[ "$(Q 'SHOW track_commit_timestamp')" = "on" ] || { echo "중단: track_commit_timestamp 가 off 입니다" >&2; exit 2; }

{
echo "# PostgreSQL PITR. 원 사례(GitLab 2017)와 같은 엔진으로 재현한다."
echo "# $(Q 'SELECT version()' | cut -c1-60)"
echo

# ── 1) 베이스 백업 ──────────────────────────────────────────────────────
Q "DROP TABLE IF EXISTS sponsor" >/dev/null
Q "CREATE TABLE sponsor (id bigserial PRIMARY KEY, live_id int, amount int, memo text)" >/dev/null
Q "INSERT INTO sponsor (live_id, amount, memo) SELECT (i%100)+1, 1000, 'before' FROM generate_series(1,1000) i" >/dev/null
echo "## 1) 베이스 백업 시점"
echo "  행 수 = $(Q 'SELECT count(*) FROM sponsor')"
docker exec -u postgres a23-pg bash -c 'rm -rf /basebackup/* && pg_basebackup -U postgres -D /basebackup -Fp -Xs -w -c fast' 2>&1 | sed 's/^/  /'
echo "  베이스 백업 완료: $(docker exec a23-pg bash -c 'ls /basebackup | wc -l')개 항목"
echo

# ── 2) 백업 뒤 정상 쓰기, 그다음 사고 ───────────────────────────────────
Q "INSERT INTO sponsor (live_id, amount, memo) SELECT (i%100)+1, 2000, 'after-backup' FROM generate_series(1,500) i" >/dev/null
Q "SELECT pg_switch_wal()" >/dev/null; sleep 1
SAFE_TS=$(Q "SELECT now()")
SAFE_N=$(Q "SELECT count(*) FROM sponsor")
echo "## 2) 사고 직전 (여기까지 살려야 한다)"
echo "  행 수 = $SAFE_N"
echo "  시각 = $SAFE_TS"
sleep 2

# 사고. 트랜잭션 안에서 XID를 잡아 둔다. 커밋 시각을 나중에 정확히 되찾기 위해서다.
ACC_XID=$(docker exec a23-pg psql -U postgres -d spoon -qAt \
  -c "BEGIN; DELETE FROM sponsor WHERE memo = 'after-backup'; SELECT pg_current_xact_id(); COMMIT;" 2>/dev/null | tr -d '[:space:]')
ACCIDENT_N=$(Q "SELECT count(*) FROM sponsor")
# now() 가 아니라 그 트랜잭션이 실제로 커밋된 시각이다. 이 구분이 이 실험의 핵심이다.
ACC_COMMIT_TS=$(Q "SELECT pg_xact_commit_timestamp('${ACC_XID}'::xid)")
ACC_LATE_TS=$(Q "SELECT pg_xact_commit_timestamp('${ACC_XID}'::xid) + interval '1 second'")
Q "SELECT pg_switch_wal()" >/dev/null; sleep 1
echo
echo "## 3) 사고 발생"
echo "  DELETE 후 행 수 = $ACCIDENT_N  (${SAFE_N}에서 $((SAFE_N - ACCIDENT_N))건 사라짐)"
echo "  사고 트랜잭션 XID = $ACC_XID"
echo "  사고 커밋 시각    = $ACC_COMMIT_TS   ← pg_xact_commit_timestamp 로 정확히 얻은 값"
echo "  1초 뒤 시각       = $ACC_LATE_TS   ← 눈대중으로 목표를 잡았을 때를 흉내낸다"

sleep 12
echo "  아카이브된 WAL = $(docker exec a23-pg bash -c 'ls /archive | wc -l')개"
echo

# ── 복구 공통 ───────────────────────────────────────────────────────────
restore_to() {  # $1=라벨  $2=recovery_target_time  $3=추가 설정
  docker rm -f a23-pgrestore >/dev/null 2>&1
  docker run -d --name a23-pgrestore --network "$(docker inspect a23-pg -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')" \
    -v a23-backup-pitr_a23base:/basebackup:ro -v a23-backup-pitr_a23archive:/archive:ro \
    -e POSTGRES_PASSWORD=lab -e PGDATA=/var/lib/postgresql/data \
    postgres:17.5 sleep infinity >/dev/null 2>&1
  sleep 2
  # 백업본은 root 소유 0600 이라 그대로는 postgres 가 못 읽는다. 복사한 뒤 소유를 넘긴다.
  docker exec -u root a23-pgrestore bash -c "
    rm -rf /var/lib/postgresql/data/* 2>/dev/null
    cp -r /basebackup/. /var/lib/postgresql/data/
    chmod 700 /var/lib/postgresql/data
    touch /var/lib/postgresql/data/recovery.signal
    cat >> /var/lib/postgresql/data/postgresql.conf <<CONF
restore_command = 'cp /archive/%f %p'
recovery_target_time = '$2'
$3
CONF
    chown -R postgres:postgres /var/lib/postgresql/data
    su postgres -c 'pg_ctl -D /var/lib/postgresql/data -l /tmp/pg.log start -w -t 90' >/dev/null 2>&1
    # promote 를 준 경우 승격이 끝날 때까지 기다린다. 안 기다리면 복구 중에 조회하게 된다.
    for i in \$(seq 1 60); do
      r=\$(su postgres -c \"psql -d spoon -qAt -c 'SELECT pg_is_in_recovery()'\" 2>/dev/null)
      [ \"\$r\" = \"f\" ] && break
      sleep 1
    done
    su postgres -c 'pg_ctl -D /var/lib/postgresql/data status' 2>&1 | head -1 | sed 's/^/    /'
  " 2>&1 | grep -v "^cp: "
}

# ── 복구 A: 기본값 그대로 (recovery_target_action 미지정) ────────────────
echo "## 4) 복구 A: recovery_target_action 을 지정하지 않음 (기본 pause)"
echo "  목표 시각 = $SAFE_TS (사고 직전)"
restore_to A "$SAFE_TS" ""
echo "  복구 서버에서 조회: $(RQ 'SELECT count(*) FROM sponsor')"
echo "  복구 로그의 마지막 줄:"
docker exec a23-pgrestore tail -4 /tmp/pg.log 2>&1 | grep -v "^cp: " | sed 's/^/    /'
echo "  pg_is_in_recovery = $(RQ 'SELECT pg_is_in_recovery()')"
echo "  → pg_wal_replay_resume() 을 불러 승격한다"
RQ "SELECT pg_wal_replay_resume()" >/dev/null; sleep 2
A_N=$(RQ 'SELECT count(*) FROM sponsor')
echo "  승격 후 행 수 = $A_N / pg_is_in_recovery = $(RQ 'SELECT pg_is_in_recovery()')"
echo

# ── 복구 B: 사고 커밋 시각을 정확히 목표로, inclusive 기본(on) ───────────
echo "## 5) 복구 B: 목표 = 사고 커밋 시각 정각, inclusive 기본값(on)"
restore_to B "$ACC_COMMIT_TS" "recovery_target_action = 'promote'"
B_N=$(RQ "SELECT count(*) FROM sponsor")
echo "  행 수 = $B_N"
docker exec a23-pgrestore grep -E "recovery stopping" /tmp/pg.log 2>/dev/null | tail -1 | sed 's/^/    /'
echo

# ── 복구 C: 같은 목표에 inclusive = off ─────────────────────────────────
echo "## 6) 복구 C: 같은 목표 시각에 recovery_target_inclusive = off"
restore_to C "$ACC_COMMIT_TS" "recovery_target_action = 'promote'
recovery_target_inclusive = off"
C_N=$(RQ "SELECT count(*) FROM sponsor")
echo "  행 수 = $C_N"
docker exec a23-pgrestore grep -E "recovery stopping" /tmp/pg.log 2>/dev/null | tail -1 | sed 's/^/    /'
echo

# ── 복구 D: 목표를 1초 늦게 잡고 inclusive = off ────────────────────────
echo "## 7) 복구 D: 목표를 1초 늦게 잡고 recovery_target_inclusive = off"
echo "  목표 시각 = $ACC_LATE_TS"
restore_to D "$ACC_LATE_TS" "recovery_target_action = 'promote'
recovery_target_inclusive = off"
D_N=$(RQ "SELECT count(*) FROM sponsor")
echo "  행 수 = $D_N"
echo

echo "## 정리"
printf "  %-34s %s행\n" "사고 전" "$SAFE_N"
printf "  %-34s %s행\n" "사고 후" "$ACCIDENT_N"
printf "  %-34s %s행\n" "복구 A 사고 직전 목표(pause)" "$A_N"
printf "  %-34s %s행\n" "복구 B 커밋 정각, inclusive=on" "$B_N"
printf "  %-34s %s행\n" "복구 C 커밋 정각, inclusive=off" "$C_N"
printf "  %-34s %s행\n" "복구 D 1초 늦게, inclusive=off" "$D_N"
echo
[ "$B_N" = "$ACCIDENT_N" ] && echo "  B: 기본값 on 은 목표 시각의 트랜잭션을 포함한다. 사고가 다시 적용됐다."
[ "$C_N" = "$SAFE_N" ]     && echo "  C: off 는 그 트랜잭션을 뺀다. 커밋 시각을 정확히 알 때만 통한다."
[ "$D_N" = "$ACCIDENT_N" ] && echo "  D: 목표가 1초만 늦어도 off 는 아무것도 막지 못한다. inclusive 는 정각 한 건만 가른다."
docker rm -f a23-pgrestore >/dev/null 2>&1
} 2>&1 | tee "$OUT/exp3-pg-pitr.txt"
