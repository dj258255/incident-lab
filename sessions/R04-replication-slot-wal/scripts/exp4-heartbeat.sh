#!/usr/bin/env bash
# 하트비트를 다시 잰다. exp3 에서 하트비트 테이블이 0행이었던 이유를 밝히고,
# 하트비트가 실제로 슬롯을 미는 조건이 무엇인지 가른다.
#
# ── exp3 이 0행이었던 이유 ──────────────────────────────────────────────
# exp3 은 이렇게 적었다. "B2. 대상은 조용, 하트비트 5초 → 하트비트 테이블 0행".
# 유휴 데이터베이스에 같은 설정으로 60초를 돌려 보니 19행이 들어왔다. 3초 주기니
# 계산이 맞는다. 하트비트는 돈다.
#
# exp3 의 조건 A 가 90초 동안 watch_log 에 초당 4천 행을 넣었다. 조건 B 는 컨테이너를
# 새로 띄우므로 오프셋 파일이 비어 있어 초기 스냅샷부터 다시 시작한다. 하트비트는
# 스트리밍 단계에 들어가야 발동한다. 스냅샷이 관측 창 90초 안에 안 끝나면 하트비트는
# 영원히 0이다. 싱크가 단일 스레드 파이썬이라 스냅샷이 더 느렸다.
# 하트비트가 안 돈 것이 아니라 하트비트 단계에 닿지 못했다.
#
# ── 그다음에 나온 것 ────────────────────────────────────────────────────
# 스냅샷을 걷어 내고 다시 재니 하트비트가 90초에 29회 돌았다. 그런데 슬롯 지연은
# 288MB 자랐다. 하트비트를 끈 조건의 322MB 와 거의 같다. publication 을 열어 봤다.
#
#   dbz_publication | public | watch_log     ← 이 한 줄뿐
#
# publication.autocreate.mode=filtered 는 table.include.list 에 적힌 테이블만으로
# publication 을 만든다. 하트비트 테이블은 거기 없다. 그러면 action.query 의 INSERT 가
# WAL 에는 남지만 pgoutput 이 걸러 내고, Debezium 은 그 변경을 받지 못하고, 받은 LSN 이
# 없으니 restart_lsn 이 제자리다.
#
# 하트비트 테이블에는 행이 쌓이고 로그에도 경고가 없다.
# **잘 도는 것처럼 보이면서 아무 일도 안 하는 조합이다.** 이것이 이 실험의 답이다.
#
# ── 조건 다섯 ───────────────────────────────────────────────────────────
#   A. 하트비트 없음                                  기준선. 지연이 자란다
#   B. 주기만(action.query 없음)                      신호는 가는데 알릴 LSN 이 없다
#   C. 주기 + action.query, 테이블이 publication 밖   돌지만 소용없다
#   E. 주기 + action.query, 테이블이 publication 안   지연이 잡힌다
#   D. 하트비트 없이 대상 테이블에도 쓰기             하트비트가 필요 없는 경우의 대조
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
P(){ docker exec r04-pg psql -U postgres -d spoon -qAt -c "$1" 2>&1; }
NET=$(docker inspect r04-pg -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')

for _ in $(seq 1 90); do [ "$(P 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(P 'SELECT 1')" = "1" ] || { echo "중단: r04-pg 가 쿼리를 받지 못합니다" >&2; exit 2; }

DUR=${DUR:-90}
HB=${HB:-3000}

P "ALTER SYSTEM SET max_slot_wal_keep_size = -1" >/dev/null
P "SELECT pg_reload_conf()" >/dev/null

# 슬롯을 확실히 지운다. 1차 실행에서 이 자리가 결함이었다.
# docker rm -f 로 Debezium 을 죽여도 PostgreSQL 이 walsender 의 죽음을 알아채기까지
# 잠깐 걸린다. 그 사이 pg_drop_replication_slot 은 "슬롯이 활성 상태"라며 실패하고,
# 반환값을 안 보면 옛 슬롯이 그대로 남는다. 그러면 다음 조건이 앞 조건의 restart_lsn 을
# 물려받아 시작 지연이 300MB 로 찍힌다. 실제로 조건 C 의 시작값이 그렇게 나왔다.
drop_slot(){
  for _ in $(seq 1 30); do
    [ "$(P "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name='dbz_slot'")" = "0" ] && return 0
    P "SELECT pg_drop_replication_slot('dbz_slot')" >/dev/null 2>&1
    sleep 1
  done
  echo "  경고: 옛 슬롯을 지우지 못했습니다. 이 조건의 시작 지연은 앞 조건에서 이어집니다."
  return 1
}

cleanup(){
  docker rm -f r04-dbz r04-sink >/dev/null 2>&1 || true
  docker exec r04-pg pkill -f "psql -U postgres -d spoon -c" >/dev/null 2>&1 || true
  drop_slot >/dev/null 2>&1 || true
  P "DROP PUBLICATION IF EXISTS dbz_publication" >/dev/null 2>&1
}
trap cleanup EXIT

start_dbz(){ # $1=heartbeat_ms(0이면 끔) $2=action_query(yes/no) $3=include_list
  docker rm -f r04-dbz r04-sink >/dev/null 2>&1 || true
  # 싱크를 스레드 방식으로 바꾼다. exp3 의 단일 스레드 서버가 병목이라
  # 지연 수치가 슬롯의 성질이 아니라 싱크 처리량을 재고 있었다.
  docker run -d --name r04-sink --network "$NET" python:3.12-alpine python -c "
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def do_POST(self):
        n=int(self.headers.get('Content-Length',0)); self.rfile.read(n)
        self.send_response(200); self.send_header('Content-Length','0'); self.end_headers()
    def log_message(self, *a): pass
ThreadingHTTPServer(('0.0.0.0',8080), H).serve_forever()" >/dev/null

  local conf="$OUT/dbz-hb.properties"
  cat > "$conf" <<CONF
debezium.sink.type=http
debezium.sink.http.url=http://r04-sink:8080/
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
debezium.source.table.include.list=$3
# 스냅샷을 걷어 낸다. exp3 이 하트비트를 0으로 본 원인이 여기였다.
debezium.source.snapshot.mode=no_data
CONF
  [ "$1" != "0" ] && echo "debezium.source.heartbeat.interval.ms=$1" >> "$conf"
  [ "$2" = "yes" ] && echo "debezium.source.heartbeat.action.query=INSERT INTO dbz_heartbeat (ts) VALUES (now()) ON CONFLICT DO NOTHING" >> "$conf"

  docker run -d --name r04-dbz --network "$NET" \
    -v "$conf":/debezium/config/application.properties:ro \
    quay.io/debezium/server:3.0 >/dev/null
}

lag_b(){ P "SELECT COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn),0)::bigint
            FROM pg_replication_slots WHERE slot_name='dbz_slot'"; }
wal_mb(){ P "SELECT ROUND(SUM(size)/1024/1024) FROM pg_ls_waldir()"; }
hum(){ python3 -c "
import sys
b=int(sys.argv[1] or 0)
print(f'{b/1024/1024:.1f}MB' if abs(b)>=1048576 else f'{b/1024:.0f}KB')" "$1"; }

writer(){ docker exec -d r04-pg bash -c "
    for i in \$(seq 1 100000); do
      psql -U postgres -d spoon -c \"INSERT INTO $1 (payload)
        SELECT repeat(md5(random()::text), 32) FROM generate_series(1,400);\" >/dev/null 2>&1
      sleep 0.1
    done"
}

run_case(){ # $1=라벨 $2=hb_ms $3=action_query $4=대상테이블에도 쓰기 $5=include_list
  local label="$1" hb="$2" aq="$3" tw="$4" inc="$5"
  cleanup
  P "CREATE TABLE IF NOT EXISTS other_log (id bigserial PRIMARY KEY, payload text)" >/dev/null
  P "CREATE TABLE IF NOT EXISTS watch_log (id bigserial PRIMARY KEY, payload text)" >/dev/null
  P "CREATE TABLE IF NOT EXISTS dbz_heartbeat (ts timestamptz PRIMARY KEY)" >/dev/null
  P "TRUNCATE other_log, watch_log, dbz_heartbeat" >/dev/null
  echo
  echo "### $label"
  start_dbz "$hb" "$aq" "$inc"
  local ok=0
  for _ in $(seq 1 60); do
    [ "$(P "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name='dbz_slot'")" = "1" ] && { ok=1; break; }
    sleep 2
  done
  [ "$ok" = "1" ] || { echo "  슬롯이 만들어지지 않았습니다"; docker logs r04-dbz 2>&1 | grep -iE "error|exception" | tail -3 | sed 's/^/    /'; return 1; }
  for _ in $(seq 1 45); do
    docker logs r04-dbz 2>&1 | grep -qi "Starting streaming\|streaming is enabled" && break
    sleep 2
  done
  echo "  하트비트 ${hb}ms, action.query $aq, 대상 쓰기 $tw"
  # publication 에 무엇이 들어갔는지 조건마다 남긴다. 이 실험의 핵심 증거다.
  echo "  publication = $(P "SELECT COALESCE(string_agg(tablename, ', ' ORDER BY tablename), '(없음)') FROM pg_publication_tables WHERE pubname='dbz_publication'")"

  [ "$tw" = "yes" ] && writer watch_log
  writer other_log
  sleep 3

  local lag0 lag1 w0 w1 hb0 hb1
  lag0=$(lag_b); w0=$(wal_mb); hb0=$(P 'SELECT COUNT(*) FROM dbz_heartbeat')
  sleep "$DUR"
  lag1=$(lag_b); w1=$(wal_mb); hb1=$(P 'SELECT COUNT(*) FROM dbz_heartbeat')
  local grow=$((lag1 - lag0))
  echo "  ${DUR}초 동안"
  echo "    슬롯 지연     $(hum "$lag0") → $(hum "$lag1")  (증가 $(hum "$grow"))"
  echo "    pg_wal        ${w0}MB → ${w1}MB"
  echo "    하트비트 행   ${hb0} → ${hb1} (${DUR}초에 $((hb1 - hb0))회)"
  echo "    other_log     $(P 'SELECT COUNT(*) FROM other_log')행 / watch_log $(P 'SELECT COUNT(*) FROM watch_log')행"
  docker exec r04-pg pkill -f "psql -U postgres -d spoon -c" >/dev/null 2>&1 || true
  echo "$label,$hb,$aq,$tw,$lag0,$lag1,$grow,$((hb1 - hb0))" >> "$OUT/heartbeat-summary.csv"
}

{
echo "# Debezium 하트비트: 켜고 action.query 까지 줘도 publication 밖이면 소용없다"
echo "# PostgreSQL $(P 'SELECT version()' | cut -c1-40)"
echo "# Debezium Server 3.0, 조건마다 ${DUR}초 관측, 1회 실행"
echo "# 스냅샷은 snapshot.mode=no_data 로 걷어 냈고, 싱크는 스레드 방식으로 바꿨습니다."
: > "$OUT/heartbeat-summary.csv"
echo "label,heartbeat_ms,action_query,target_write,lag0_b,lag1_b,growth_b,heartbeat_rows" >> "$OUT/heartbeat-summary.csv"

run_case "A. 하트비트 없음"                       0     no  no  "public.watch_log"
run_case "B. 주기만(action.query 없음)"            "$HB" no  no  "public.watch_log"
run_case "C. 주기+query / 테이블이 publication 밖"  "$HB" yes no  "public.watch_log"
run_case "E. 주기+query / 테이블이 publication 안"  "$HB" yes no  "public.watch_log,public.dbz_heartbeat"
run_case "D. 하트비트 없이 대상 테이블에도 쓰기"    0     no  yes "public.watch_log"

echo
echo "## 정리 (증가분이 판단 기준입니다)"
column -s, -t "$OUT/heartbeat-summary.csv" 2>/dev/null || cat "$OUT/heartbeat-summary.csv"
echo
echo "  각 조건 1회 실행입니다."
} 2>&1 | tee "$OUT/exp4-heartbeat.txt"
