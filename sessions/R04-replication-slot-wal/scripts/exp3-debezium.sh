#!/usr/bin/env bash
# 실제 CDC 도구(Debezium)로 같은 조건을 잰다.
#
# README 의 "못 한 것"에 이렇게 적어 두었다.
#   pg_recvlogical 로 대신했고, 실제 도구는 하트비트나 자동 재연결 같은 완충 장치가 있습니다.
#
# 완충 장치가 실제로 무엇을 막는지가 이 실험의 질문이다. 세 조건으로 나눈다.
#
#   A) Debezium 이 살아 있고 캡처 대상 테이블에 쓰기가 있다
#      → 슬롯이 따라온다. 당연한 조건이고 기준선이다
#
#   B) Debezium 이 살아 있는데 캡처 대상 테이블은 조용하고 다른 테이블만 바쁘다
#      → 이것이 Debezium 의 유명한 함정이다. 슬롯의 restart_lsn 은 캡처 대상의 변경을
#        받을 때만 전진하므로, 대상이 조용하면 서버는 살아 있는데 WAL 이 쌓인다
#      → heartbeat.interval.ms 가 이 자리를 막는다. 그것을 켜고 끈 두 조건을 잰다
#
#   C) Debezium 이 죽었다
#      → pg_recvlogical 과 같다. 하트비트가 있어도 소용없다
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
P(){ docker exec r04-pg psql -U postgres -d spoon -qAt -c "$1" 2>&1; }
NET=$(docker inspect r04-pg -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')

for _ in $(seq 1 90); do [ "$(P 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(P 'SELECT 1')" = "1" ] || { echo "중단: r04-pg 가 쿼리를 받지 못합니다" >&2; exit 2; }

DUR=${DUR:-90}

# 앞 실험(exp2)이 max_slot_wal_keep_size 를 64MB 로 남겨 두면 슬롯이 그 지점에서
# 무효화되어 지연이 리셋된다. 처음에 그대로 돌려 조건 C 의 지연이 39MB 에서 0 으로
# 줄어드는 이상한 값이 나왔다. 이 실험은 상한 없이 본다.
P "ALTER SYSTEM SET max_slot_wal_keep_size = -1" >/dev/null
P "SELECT pg_reload_conf()" >/dev/null
echo "max_slot_wal_keep_size = $(P "SELECT current_setting('max_slot_wal_keep_size')")"

cleanup(){
  docker rm -f r04-dbz r04-sink >/dev/null 2>&1 || true
  docker exec r04-pg pkill -f "other-writer" >/dev/null 2>&1 || true
  P "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots" >/dev/null 2>&1
  P "SELECT pg_drop_replication_slot('dbz_slot')" >/dev/null 2>&1
}
trap cleanup EXIT

# Debezium Server 를 띄운다.
#
# 싱크는 http 를 쓴다. 처음에 pravega 를 골랐는데 scope 같은 추가 설정을 요구해
# 기동 자체가 안 됐다("The config property debezium.sink.pravega.scope is required").
# 이 실험은 슬롯이 전진하는지만 보면 되므로 받아 주기만 하는 엔드포인트면 충분하다.
#
# 설정은 환경변수가 아니라 properties 파일로 넘긴다. 하트비트의 action.query 에는
# 공백이 들어가는데 환경변수로 넘기려다 셸 치환이 깨졌다.
# 경로는 /debezium/config 다. /debezium/conf 로 넣으면 기동은 되고 설정만 안 읽혀
# 'Failed to load mandatory config value debezium.sink.type' 이 난다.
start_dbz(){ # $1=heartbeat_ms (0이면 끔)
  docker rm -f r04-dbz r04-sink >/dev/null 2>&1 || true
  # 변경분을 받아 버리는 최소 엔드포인트. 200 만 돌려주면 된다.
  docker run -d --name r04-sink --network "$NET" python:3.12-alpine \
    python -c "
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n=int(self.headers.get('Content-Length',0)); self.rfile.read(n)
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(('0.0.0.0',8080), H).serve_forever()" >/dev/null

  local conf="$OUT/dbz-application.properties"
  cat > "$conf" <<CONF
debezium.sink.type=http
debezium.sink.http.url=http://r04-sink:8080/
# http 싱크는 포맷을 명시해야 한다. 안 적으면
# 'The config property debezium.format.value is required' 로 기동이 안 된다.
debezium.format.key=json
debezium.format.value=json
debezium.format.key.schemas.enable=false
debezium.format.value.schemas.enable=false
debezium.source.connector.class=io.debezium.connector.postgresql.PostgresConnector
debezium.source.offset.storage.file.filename=/tmp/offsets.dat
debezium.source.offset.flush.interval.ms=1000
debezium.source.database.hostname=r04-pg
debezium.source.database.port=5432
debezium.source.database.user=postgres
debezium.source.database.password=lab
debezium.source.database.dbname=spoon
debezium.source.topic.prefix=lab
debezium.source.plugin.name=pgoutput
debezium.source.slot.name=dbz_slot
debezium.source.publication.autocreate.mode=filtered
debezium.source.table.include.list=public.watch_log
quarkus.log.level=INFO
CONF
  if [ "$1" != "0" ]; then
    # 하트비트는 두 부분이다. 주기적으로 신호를 보내는 것과, 그 신호가 WAL 에 실제
    # 변경으로 남도록 쓰기를 한 번 하는 것이다. action.query 가 없으면 캡처 대상이
    # 조용한 동안 restart_lsn 이 전진하지 못한다.
    cat >> "$conf" <<CONF
debezium.source.heartbeat.interval.ms=$1
debezium.source.heartbeat.action.query=INSERT INTO dbz_heartbeat (ts) VALUES (now()) ON CONFLICT DO NOTHING
CONF
  fi
  docker run -d --name r04-dbz --network "$NET" \
    -v "$conf":/debezium/config/application.properties:ro \
    quay.io/debezium/server:3.0 >/dev/null
}

# MB 로 반올림하면 작은 변화가 숨는다. 바이트로 본다.
lag_b(){ P "SELECT COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn),0)::bigint
            FROM pg_replication_slots WHERE slot_name='dbz_slot'"; }
wal_mb(){ P "SELECT ROUND(SUM(size)/1024/1024) FROM pg_ls_waldir()"; }
hum(){ python3 -c "
import sys
b=int(sys.argv[1] or 0)
print(f'{b/1024/1024:.1f}MB' if abs(b)>=1048576 else f'{b/1024:.0f}KB')" "$1"; }

# 캡처 대상이 아닌 테이블에만 쓰기를 넣는다. 이것이 조건 B 의 핵심이다.
start_other_writer(){
  docker exec -d r04-pg bash -c "
    for i in \$(seq 1 100000); do
      psql -U postgres -d spoon -c \"INSERT INTO other_log (payload)
        SELECT repeat(md5(random()::text), 32) FROM generate_series(1,400);\" >/dev/null 2>&1
      sleep 0.1
    done"
}

run_case(){ # $1=라벨 $2=heartbeat_ms $3=대상테이블에 쓰기(yes/no) $4=debezium 살림(yes/no)
  local label="$1" hb="$2" target_write="$3" alive="$4"
  cleanup
  P "CREATE TABLE IF NOT EXISTS other_log (id bigserial PRIMARY KEY, payload text)" >/dev/null
  P "CREATE TABLE IF NOT EXISTS dbz_heartbeat (ts timestamptz PRIMARY KEY)" >/dev/null
  P "TRUNCATE other_log" >/dev/null
  echo
  echo "### $label"
  start_dbz "$hb"
  # 슬롯이 만들어질 때까지 기다린다. 안 만들어지면 이 조건은 성립하지 않는다.
  local ok=0
  for _ in $(seq 1 60); do
    [ "$(P "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name='dbz_slot'")" = "1" ] && { ok=1; break; }
    sleep 2
  done
  if [ "$ok" != "1" ]; then
    echo "  슬롯이 만들어지지 않았습니다. Debezium 로그:"
    docker logs r04-dbz 2>&1 | grep -iE "error|exception|fail" | tail -4 | sed 's/^/    /'
    return 1
  fi
  echo "  슬롯 생성됨. 하트비트 = ${hb}ms, 대상 테이블 쓰기 = $target_write, Debezium = $alive"

  if [ "$target_write" = "yes" ]; then
    docker exec -d r04-pg bash -c "
      for i in \$(seq 1 100000); do
        psql -U postgres -d spoon -c \"INSERT INTO watch_log (live_id, payload)
          SELECT (random()*1000)::int, repeat(md5(random()::text), 32) FROM generate_series(1,400);\" >/dev/null 2>&1
        sleep 0.1
      done"
  fi
  start_other_writer
  if [ "$alive" = "no" ]; then
    sleep 5
    docker rm -f r04-dbz >/dev/null 2>&1
    echo "  Debezium 을 죽였습니다"
  fi

  local t0 lag0 lag1 w0 w1
  t0=$(date +%s); lag0=$(lag_b); w0=$(wal_mb)
  sleep "$DUR"
  lag1=$(lag_b); w1=$(wal_mb)
  echo "  ${DUR}초 동안: 슬롯 지연 $(hum "$lag0") → $(hum "$lag1"), pg_wal ${w0}MB → ${w1}MB"
  echo "  슬롯 상태 = $(P "SELECT wal_status FROM pg_replication_slots WHERE slot_name='dbz_slot'")"
  echo "  other_log 행 수 = $(P 'SELECT COUNT(*) FROM other_log')"
  echo "  하트비트 테이블 행 수 = $(P 'SELECT COUNT(*) FROM dbz_heartbeat')"
  docker exec r04-pg pkill -f "psql -U postgres -d spoon -c" >/dev/null 2>&1 || true
  echo "$label,$hb,$target_write,$alive,$lag0,$lag1,$w0,$w1" >> "$OUT/debezium-summary.csv"
}

{
echo "# Debezium Server 로 같은 조건을 잰다"
echo "# $(docker run --rm quay.io/debezium/server:3.0 sh -c 'echo Debezium Server 3.0' 2>/dev/null || echo 'Debezium Server 3.0')"
echo "# PostgreSQL $(P 'SELECT version()' | cut -c1-40)"
echo "# 조건마다 ${DUR}초 관측, 1회 실행"
: > "$OUT/debezium-summary.csv"
echo "label,heartbeat_ms,target_write,dbz_alive,lag0_mb,lag1_mb,wal0_mb,wal1_mb" >> "$OUT/debezium-summary.csv"

run_case "A. 살아 있고 대상 테이블에 쓰기 있음"        0     yes yes
run_case "B1. 살아 있는데 대상은 조용, 하트비트 없음"   0     no  yes
run_case "B2. 살아 있는데 대상은 조용, 하트비트 5초"    5000  no  yes
run_case "C. Debezium 이 죽음"                          5000  yes no

echo
echo "## 정리"
column -s, -t "$OUT/debezium-summary.csv" 2>/dev/null || cat "$OUT/debezium-summary.csv"
echo
echo "  각 조건 1회 실행입니다."
} 2>&1 | tee "$OUT/exp3-debezium.txt"
