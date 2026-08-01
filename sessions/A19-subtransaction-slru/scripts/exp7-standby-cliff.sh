#!/usr/bin/env bash
# 스탠바이 절벽을 다시 시도한다.
#
# 5절의 실패에는 원인이 하나 분명하게 적혀 있다. sp70 조건에서 클라이언트 넷이
# **겹치는 행 락 70개**를 잡아 서로 막았고 쓰기가 초당 0.68건이었다. 데드락까지 났다.
# ASSIGNMENT 레코드가 나올 수 있는 유일한 조건이었는데 정작 쓰기량이 없었다.
#
# 고치는 지점은 하나다. **클라이언트마다 자기 키 범위를 준다.** 그러면 서브트랜잭션
# 70개를 쓰면서도 서로 안 막는다. 64를 넘겨야 XLOG_XACT_ASSIGNMENT 가 나오고,
# 그게 나와야 스탠바이가 스냅샷을 suboverflowed 로 표시한다.
#
# 캐싱: 조건마다 **두 컨테이너를 모두 재시작**하고 같은 방식으로 데운다. 조건 순서가
# 결과를 만들지 않게 한다. SLRU 카운터도 조건마다 초기화한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
PRI=a19-pri; STB=a19-stb; NET=a19-net; PW=lab
ROWS=${ROWS:-200000}; WRITERS=${WRITERS:-4}; SUBTX=${SUBTX:-200}; SECS=${SECS:-30}
RATE_SLEEP=${RATE_SLEEP:-0.5}   # 쓰기 트랜잭션 사이 대기. 조건 간 쓰기량을 맞추는 손잡이

cleanup(){ docker rm -f "$PRI" "$STB" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
trap cleanup EXIT
cleanup; docker network create "$NET" >/dev/null

P(){ docker exec -i "$PRI" psql -U postgres -d lab -At -c "$1" 2>&1; }
S(){ docker exec -i "$STB" psql -U postgres -d lab -At -c "$1" 2>&1; }
up(){ for _ in $(seq 1 90); do [ "$($1 'SELECT 1' 2>/dev/null)" = "1" ] && return 0; sleep 2; done; return 1; }

docker run -d --name "$PRI" --network "$NET" -e POSTGRES_PASSWORD=$PW -e POSTGRES_DB=lab postgres:17.5 \
  -c wal_level=replica -c max_wal_senders=8 -c max_replication_slots=8 -c hot_standby=on \
  -c hot_standby_feedback=off -c shared_buffers=256MB -c max_connections=200 >/dev/null
up P || { echo "중단: 프라이머리가 안 뜹니다" >&2; exit 2; }

P "CREATE TABLE t(id int PRIMARY KEY, v int NOT NULL DEFAULT 0, pad text);
   INSERT INTO t SELECT g, 0, repeat('x',60) FROM generate_series(1,$ROWS) g;
   CREATE EXTENSION IF NOT EXISTS pg_prewarm;" >/dev/null
[ "$(P "SELECT COUNT(*) FROM t")" = "$ROWS" ] || { echo "중단: 적재 실패" >&2; exit 2; }
# 기본 pg_hba.conf 는 replication 을 로컬에만 허용한다. 원격 basebackup 이 그래서
# 막히고, 그 실패를 못 보면 "스탠바이가 안 뜬다"까지만 보인다.
docker exec "$PRI" bash -c "echo 'host replication all all trust' >> /var/lib/postgresql/data/pg_hba.conf"
P "SELECT pg_reload_conf();" >/dev/null
P "SELECT pg_create_physical_replication_slot('sb');" >/dev/null

# 스탠바이를 베이스백업으로 만든다
docker run -d --name "$STB" --network "$NET" -e PGPASSWORD=$PW --entrypoint sleep postgres:17.5 infinity >/dev/null
BB=$(docker exec "$STB" bash -c "rm -rf /var/lib/postgresql/data/* &&
  pg_basebackup -h $PRI -U postgres -D /var/lib/postgresql/data -R -S sb -X stream -c fast &&
  chown -R postgres:postgres /var/lib/postgresql/data && chmod 700 /var/lib/postgresql/data" 2>&1)
if ! docker exec "$STB" test -f /var/lib/postgresql/data/standby.signal; then
  echo "중단: 베이스백업이 실패했습니다" >&2; echo "$BB" | tail -3 >&2; exit 2
fi
docker exec -u postgres -d "$STB" bash -c "postgres -D /var/lib/postgresql/data -c hot_standby=on -c shared_buffers=256MB -c max_connections=200 > /tmp/pg.log 2>&1"
up S || { echo "중단: 스탠바이가 안 뜹니다" >&2; docker exec "$STB" tail -5 /tmp/pg.log >&2 2>/dev/null; exit 2; }
[ "$(S "SELECT pg_is_in_recovery()")" = "t" ] || { echo "중단: 스탠바이가 복구 모드가 아닙니다" >&2; exit 2; }

# 캐시 상태를 조건마다 같게 만든다. 재시작 뒤 같은 방식으로 데운다.
prep(){
  docker restart "$PRI" >/dev/null; up P || return 1
  docker restart "$STB" >/dev/null
  docker exec -u postgres -d "$STB" bash -c "postgres -D /var/lib/postgresql/data -c hot_standby=on -c shared_buffers=256MB -c max_connections=200 > /tmp/pg.log 2>&1"
  up S || { echo "  스탠바이 기동 실패: $(docker exec "$STB" tail -3 /tmp/pg.log 2>/dev/null)"; return 1; }
  P "SELECT pg_prewarm('t'); SELECT pg_stat_reset(); SELECT pg_stat_reset_slru();" >/dev/null
  S "SELECT pg_prewarm('t'); SELECT pg_stat_reset(); SELECT pg_stat_reset_slru();" >/dev/null
  return 0
}

# 쓰기 클라이언트. **키 범위를 클라이언트마다 나눈다.** 5절 실패의 원인이 겹침이었다.
writer(){ # $1 = 인덱스, $2 = use_subtx
  # local 한 줄에서 방금 선언한 변수를 산술에 쓰면 set -u 아래서 unbound 로 깨진다.
  local idx="$1" sub="$2" RATE_SLEEP="$RATE_SLEEP"
  local lo=$(( (idx-1) * (ROWS/WRITERS) + 1 ))
  docker exec -i "$PRI" bash -c "
    RATE_SLEEP=$RATE_SLEEP
    end=\$(( \$(date +%s) + $SECS ))
    while [ \$(date +%s) -lt \$end ]; do
      {
        echo 'BEGIN;'
        for i in \$(seq 1 $SUBTX); do
          [ '$sub' = yes ] && echo \"SAVEPOINT s\$i;\"
          echo \"UPDATE t SET v=v+1 WHERE id=\$(( $lo + i ));\"
        done
        echo 'COMMIT;'
      } | psql -U postgres -d lab -q >/dev/null 2>&1
      # **쓰기 속도를 고정한다.** 안 하면 조건마다 프라이머리 쓰기량이 10배씩 달라져
      # 스탠바이 처리량 비교가 성립하지 않는다. 1차 증폭 회차가 그랬다.
      # 가장 느린 조건(D)이 따라올 수 있는 속도로 맞춘다.
      sleep $RATE_SLEEP
    done" 2>/dev/null &
}

# 스탠바이 읽기. 최근 갱신된 행을 훑어 가시성 검사를 강제한다.
sb_read(){
  docker exec -i "$STB" bash -c "
    RATE_SLEEP=$RATE_SLEEP
    end=\$(( \$(date +%s) + $SECS )); n=0
    while [ \$(date +%s) -lt \$end ]; do
      psql -U postgres -d lab -At -c 'SELECT count(*) FROM t WHERE v > 0' >/dev/null 2>&1
      n=\$((n+1))
    done; echo \$n" 2>/dev/null
}

slru(){ $1 "SELECT COALESCE(blks_read,0)||'/'||COALESCE(blks_hit,0) FROM pg_stat_slru WHERE name='subtransaction'"; }
# 1차 시도의 카운터는 0 을 돌려줬는데 같은 조건에서 스탠바이 SLRU 히트가 1.4억이었다.
# 오버플로 없이는 pg_subtrans 를 볼 이유가 없으니 카운터가 틀린 것이다.
# 세그먼트 목록을 셸에서 조립하다 깨졌다. 디렉터리를 통째로 넘긴다.
assign(){
  docker exec "$PRI" bash -c '
    n=0
    for f in $(ls /var/lib/postgresql/data/pg_wal | grep -E "^[0-9A-F]{24}$" | tail -5); do
      c=$(pg_waldump /var/lib/postgresql/data/pg_wal/$f 2>/dev/null | grep -c ASSIGNMENT)
      n=$((n+c))
    done
    echo $n' 2>/dev/null | tr -d ' ' | tail -1
}

run(){ # $1=라벨 $2=long_tx(yes/no) $3=subtx(yes/no)
  prep || { echo "  $1: 준비 실패"; return; }
  local LP=""
  if [ "$2" = yes ]; then
    docker exec -d "$PRI" psql -U postgres -d lab -c \
      "BEGIN; SELECT txid_current(); SELECT pg_sleep($((SECS+10))); COMMIT;"
    sleep 3
    local held; held=$(P "SELECT COUNT(*) FROM pg_stat_activity WHERE state='idle in transaction' OR (state='active' AND query LIKE '%pg_sleep%')")
    [ "${held:-0}" -lt 1 ] && echo "  $1: 주의, 긴 트랜잭션이 안 섰습니다"
  fi
  for w in $(seq 1 $WRITERS); do writer "$w" "$3"; done
  local n; n=$(sb_read)
  wait 2>/dev/null
  sleep 2
  local sr; sr=$(slru S); local asg; asg=$(assign)
  local wr; wr=$(P "SELECT SUM(n_tup_upd) FROM pg_stat_user_tables WHERE relname='t'")
  local lagsec; lagsec=$(S "SELECT COALESCE(ROUND(EXTRACT(epoch FROM now()-pg_last_xact_replay_timestamp())),0)")
  printf "  %-26s 스탠바이 %6s회  프라이머리 UPDATE %8s  ASSIGNMENT %5s  스탠바이 subtrans(읽기/히트) %s  지연 %s초\n" \
    "$1" "${n:-0}" "${wr:-0}" "${asg:-0}" "${sr:-없음}" "${lagsec:-?}"
  echo "$1,$2,$3,${n:-0},${wr:-0},${asg:-0},${sr:-0/0}" >> "$OUT/standby-cliff.csv"
}

echo "label,long_tx,subtx,standby_reads,primary_updates,wal_assignment,standby_subtrans" > "$OUT/standby-cliff.csv"
{
echo "# 스탠바이 절벽 재시도"
echo "# PostgreSQL $(P 'SHOW server_version') · 프라이머리 + 스트리밍 스탠바이 · t $ROWS 행"
echo "# 쓰기 클라이언트 $WRITERS, 트랜잭션당 서브트랜잭션 $SUBTX, 각 조건 ${SECS}초"
echo "# 5절 실패의 원인이던 행 락 겹침을 없앴습니다. 클라이언트마다 자기 키 범위를 씁니다."
echo "# 조건마다 두 컨테이너를 재시작하고 같은 방식으로 데워 캐시 상태를 맞춥니다."
echo
run "A 기준선(둘 다 없음)"       no  no
run "B 롱TX만"                   yes no
run "C 서브TX만"                 no  yes
run "D 롱TX + 서브TX (GitLab)"   yes yes
echo
python3 - "$OUT/standby-cliff.csv" <<'CHK'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding='utf-8')))
w = [int(r['primary_updates'] or 0) for r in rows]
if w and min(w) > 0:
    spread = (max(w) - min(w)) * 100 // max(w)
    print(f"  프라이머리 쓰기량 {min(w)}에서 {max(w)}, 폭 {spread}%")
    if spread > 25:
        print("  **폭이 25%를 넘습니다. 조건 사이의 스탠바이 처리량 비교는 인용하면 안 됩니다.**")
    else:
        print("  폭이 25% 안입니다. 스탠바이 처리량을 조건 사이에 비교할 수 있습니다.")
CHK
echo
echo "  ASSIGNMENT 가 0 이면 스탠바이는 오버플로를 통보받지 못합니다."
echo "  그 경우 subtrans 읽기가 0 인 것은 재현 실패가 아니라 조건 미성립입니다."
} 2>&1 | tee "$OUT/exp7-standby-cliff.txt"
