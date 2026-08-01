#!/usr/bin/env bash
# WAL 크기 차이가 실제 복제 전송량 차이가 되는지 잰다.
# 본문은 Uber 주장의 후반부(WAL 이 물리 복제를 타고 대역폭 문제로 전이)를 스탠바이
# 구성이 필요해 범위에서 뺐고, "WAL 크기 차이가 그대로 전송량 차이가 된다"는 추론까지만
# 가능하다고 적었다. 스탠바이를 붙여 그 추론을 확인한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
PRI=a18-pri; STB=a18-stb; NET=a18-net; N=${N:-200000}
cleanup(){ docker rm -f "$PRI" "$STB" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
trap cleanup EXIT; cleanup; docker network create "$NET" >/dev/null

P(){ docker exec -i "$PRI" psql -U postgres -d lab -At -c "$1" 2>&1; }
S(){ docker exec -i "$STB" psql -U postgres -d lab -At -c "$1" 2>&1; }
up(){ for _ in $(seq 1 90); do [ "$($1 'SELECT 1' 2>/dev/null)" = "1" ] && return 0; sleep 2; done; return 1; }

docker run -d --name "$PRI" --network "$NET" -e POSTGRES_PASSWORD=lab -e POSTGRES_DB=lab postgres:17.5 \
  -c wal_level=replica -c max_wal_senders=8 -c max_replication_slots=8 -c hot_standby=on >/dev/null
up P || { echo "중단: 프라이머리" >&2; exit 2; }
docker exec "$PRI" bash -c "echo 'host replication all all trust' >> /var/lib/postgresql/data/pg_hba.conf"
P "SELECT pg_reload_conf(); SELECT pg_create_physical_replication_slot('sb');" >/dev/null

docker run -d --name "$STB" --network "$NET" --entrypoint sleep postgres:17.5 infinity >/dev/null
docker exec "$STB" bash -c "rm -rf /var/lib/postgresql/data/* &&
  pg_basebackup -h $PRI -U postgres -D /var/lib/postgresql/data -R -S sb -X stream -c fast &&
  chown -R postgres:postgres /var/lib/postgresql/data && chmod 700 /var/lib/postgresql/data" >/dev/null 2>&1
docker exec "$STB" test -f /var/lib/postgresql/data/standby.signal || { echo "중단: 베이스백업 실패" >&2; exit 2; }
docker exec -u postgres -d "$STB" bash -c "postgres -D /var/lib/postgresql/data -c hot_standby=on > /tmp/pg.log 2>&1"
up S || { echo "중단: 스탠바이" >&2; exit 2; }

# 인덱스 개수를 축으로 둔다. Uber 주장의 핵심은 "인덱스가 많을수록 한 행 갱신이
# 만드는 WAL 이 커진다"이고, 그 WAL 이 그대로 복제를 탄다는 것이 후반부다.
measure(){ # $1 = 라벨, $2 = 추가 인덱스 수
  local lbl="$1" idx="$2" i
  P "DROP TABLE IF EXISTS t;
     CREATE TABLE t(id serial PRIMARY KEY, a int, b int, c int, d int, pad text);
     INSERT INTO t(a,b,c,d,pad) SELECT g,g,g,g,repeat('x',80) FROM generate_series(1,$N) g;" >/dev/null
  for i in $(seq 1 "$idx"); do
    local col=$(echo "a b c d" | cut -d' ' -f$(( (i-1)%4+1 )))
    P "CREATE INDEX idx_${i} ON t($col, id);" >/dev/null
  done
  P "CHECKPOINT;" >/dev/null; sleep 2
  local w0 s0 w1 s1
  w0=$(P "SELECT pg_current_wal_lsn()")
  s0=$(P "SELECT COALESCE(SUM(bytes_sent),0) FROM pg_stat_io WHERE 1=0" 2>/dev/null); s0=0
  # 인덱스에 안 걸린 컬럼(pad)만 갱신한다. HOT 이 성립할 수 있는 갱신이다.
  P "UPDATE t SET pad = repeat('y',80) WHERE id <= $((N/2));" >/dev/null
  w1=$(P "SELECT pg_current_wal_lsn()")
  local wal; wal=$(P "SELECT pg_wal_lsn_diff('$w1','$w0')")
  # 스탠바이가 그만큼 받았는지 확인한다
  sleep 3
  local recv; recv=$(S "SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(),'$w0')")
  local hot; hot=$(P "SELECT COALESCE(n_tup_hot_upd,0) FROM pg_stat_user_tables WHERE relname='t'")
  printf "  %-16s 인덱스 %2s개  WAL 생성 %9s바이트  스탠바이 수신 %9s바이트  HOT 갱신 %s\n" \
    "$lbl" "$idx" "${wal:-?}" "${recv:-?}" "${hot:-?}"
  echo "$lbl,$idx,${wal:-0},${recv:-0},${hot:-0}" >> "$OUT/replication-amp.csv"
}
echo "label,extra_indexes,wal_bytes,standby_received,hot_updates" > "$OUT/replication-amp.csv"
{
echo "# WAL 크기 차이가 복제 전송량 차이가 되는가"
echo "# PostgreSQL $(P 'SHOW server_version') · $N 행 · 절반을 갱신"
echo "# 갱신 대상은 인덱스에 안 걸린 컬럼입니다. 인덱스 수만 축으로 둡니다."
echo
for k in 0 2 4 8; do measure "인덱스$k" "$k"; done
echo
python3 - "$OUT/replication-amp.csv" <<'ST'
import csv,sys
r=list(csv.DictReader(open(sys.argv[1],encoding='utf-8')))
if not r: raise SystemExit
base=int(r[0]['wal_bytes']) or 1
print("  인덱스 수   WAL(기준 대비)   스탠바이 수신 / WAL")
for x in r:
    w=int(x['wal_bytes']); rc=int(x['standby_received'])
    ratio = rc/w if w else 0
    print(f"  {x['extra_indexes']:>7}   {w/base:>8.2f}배        {ratio:>6.2f}")
print()
print("  수신/WAL 이 1 에 가까우면 생성된 WAL 이 그대로 복제를 탄다는 뜻입니다.")
ST
} 2>&1 | tee "$OUT/exp3-replication-amp.txt"
