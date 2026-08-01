#!/usr/bin/env bash
# publication 에 없는 테이블에 쓰면 슬롯이 전진하는가.
#
# 이 세션은 소비자가 없는 슬롯이 WAL 을 붙잡는 것을 쟀다. 소비자가 살아 있는데도
# 쌓이는 조건이 따로 있고, Debezium 문서가 그 처방으로 하트비트를 든다.
# 그런데 같은 문서가 NOTE 를 하나 달아 둔다.
#   "you must add the table to the PostgreSQL publication ... If the publication is not
#    already configured ... FOR ALL TABLES ... you must explicitly add the heartbeat table"
#
# 이것을 빠뜨리면 어떻게 되는가. 하트비트는 돌고, 쿼리는 실행되고, 에러도 안 난다.
# 그런데 슬롯이 안 전진한다면 설정이 켜진 채로 아무 일도 안 하는 것이다.
# 이 랩이 반복해 만난 유형이라 확인한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
C=r04-hb

docker rm -f "$C" >/dev/null 2>&1
docker run -d --name "$C" -e POSTGRES_PASSWORD=lab -e POSTGRES_DB=lab postgres:17.5 \
  -c wal_level=logical -c max_replication_slots=8 >/dev/null
P(){ docker exec -i "$C" psql -U postgres -d lab -At -c "$1" 2>&1; }
for _ in $(seq 1 90); do [ "$(P 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(P 'SELECT 1')" = "1" ] || { echo "중단: PostgreSQL 이 안 뜹니다" >&2; exit 2; }

# 실제 조건을 만든다. publication 은 **캡처 대상 테이블만** 싣고, 그 테이블에는
# 아무도 안 쓴다(저트래픽 DB). WAL 을 만드는 것은 publication 밖의 noise 다(고트래픽).
# 1차 시도는 소음을 publication 안 테이블에 넣어서 슬롯이 늘 전진했다. 조건이 없었다.
P "CREATE TABLE captured(id serial PRIMARY KEY, v text);
   CREATE TABLE noise(id serial PRIMARY KEY, v text);
   CREATE TABLE heartbeat(id serial PRIMARY KEY, ts timestamptz);
   CREATE PUBLICATION pub_cap FOR TABLE captured;" >/dev/null

# pgoutput 슬롯을 만들고, 소비를 흉내낸다. 소비자는 publication 이 실어 준 변경만 받고,
# 받은 데이터의 LSN 까지만 확정(advance)할 수 있다.
P "SELECT pg_create_logical_replication_slot('s1','pgoutput');" >/dev/null

lag(){ P "SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) FROM pg_replication_slots WHERE slot_name='s1'"; }
restart(){ P "SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name='s1'"; }
rlsn(){ P "SELECT restart_lsn FROM pg_replication_slots WHERE slot_name='s1'"; }
consume(){ # publication 이 실어 준 것만 읽고 그 지점까지 확정한다
  P "SELECT COUNT(*) FROM pg_logical_slot_get_binary_changes('s1', NULL, NULL,
       'proto_version','1','publication_names','pub_cap','messages','true')" ; }

churn(){ # busy 테이블에 대량 쓰기를 넣어 WAL 을 만든다
  P "INSERT INTO noise(v) SELECT repeat('x',400) FROM generate_series(1,$1);
     CHECKPOINT;" >/dev/null; }

{
echo "# publication 에 없는 테이블에 써도 슬롯이 전진하는가"
echo "# PostgreSQL $(P 'SHOW server_version') · 슬롯 s1(pgoutput) · publication 은 captured 만 실음(그 테이블엔 안 씀)"
echo

echo "## 1. 하트비트 테이블이 publication 에 없을 때"
churn 40000
B0=$(restart)
# 하트비트를 다섯 번 넣는다. Debezium 의 heartbeat.action.query 가 하는 일이다.
for i in 1 2 3 4 5; do P "INSERT INTO heartbeat(ts) VALUES (now());" >/dev/null; done
HN=$(P "SELECT COUNT(*) FROM heartbeat")
GOT=$(consume)
B1=$(restart)
printf "  %-34s %s행\n" "하트비트 테이블에 들어간 행" "$HN"
printf "  %-34s %s건\n" "슬롯이 받은 변경" "$GOT"
printf "  %-34s %s\n" "확정 지점이 움직였는가" "$([ "$B0" = "$B1" ] && echo '**안 움직임**' || echo '움직임')"
printf "  %-34s %s\n" "붙잡고 있는 WAL" "$(lag)"
[ "${HN:-0}" -ne 5 ] && echo "  주의: 하트비트가 5행이 아닙니다. 이 조건은 안 섰습니다"
echo

echo "## 2. publication 에 하트비트 테이블을 추가한 뒤"
P "ALTER PUBLICATION pub_cap ADD TABLE heartbeat;" >/dev/null
churn 40000
C0=$(restart)
for i in 1 2 3 4 5; do P "INSERT INTO heartbeat(ts) VALUES (now());" >/dev/null; done
GOT2=$(consume)
C1=$(restart)
printf "  %-34s %s건\n" "슬롯이 받은 변경" "$GOT2"
printf "  %-34s %s\n" "확정 지점이 움직였는가" "$([ "$C0" = "$C1" ] && echo '**안 움직임**' || echo '움직임')"
printf "  %-34s %s\n" "붙잡고 있는 WAL" "$(lag)"
echo

echo "## 3. 테이블 없이 논리 디코딩 메시지로 대신할 수 있는가 (PG 14+)"
churn 40000
D0=$(restart)
for i in 1 2 3 4 5; do P "SELECT pg_logical_emit_message(false,'heartbeat',now()::text);" >/dev/null; done
GOT3=$(consume)
D1=$(restart)
printf "  %-34s %s건\n" "슬롯이 받은 변경" "$GOT3"
printf "  %-34s %s\n" "확정 지점이 움직였는가" "$([ "$D0" = "$D1" ] && echo '**안 움직임**' || echo '움직임')"
printf "  %-34s %s\n" "붙잡고 있는 WAL" "$(lag)"
echo
echo "  전 구간에서 에러는 나지 않았습니다. 갈리는 것은 슬롯이 전진하느냐뿐입니다."
} 2>&1 | tee "$OUT/exp6-heartbeat-publication.txt"
docker rm -f "$C" >/dev/null 2>&1
