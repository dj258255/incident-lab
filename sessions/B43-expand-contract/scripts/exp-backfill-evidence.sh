#!/usr/bin/env bash
# README 의 "못 한 것" 세 개를 잡는다.
#
#   1) 백필 중 조회 지연의 원인에 양성 증거가 없습니다
#      "락이 아니다"라는 배제까지만 했고 디스크 경쟁 쪽은 pg_stat_io 도
#      EXPLAIN (ANALYZE, BUFFERS) 도 안 봤다. 둘 다 잰다.
#      배제는 "락이 아니다"까지만 말하고 "그럼 무엇이냐"는 못 말한다.
#
#   2) 백필 뒤 VACUUM 계획을 세워 재지 않았습니다
#      3단계가 437MB 로 부푼 것과 죽은 튜플 2,999,730개는 관측했지만,
#      회수에 얼마가 드는지는 안 쟀다. VACUUM 을 직접 돌려 시간과 회수량을 잰다.
#
#   3) 35배는 5회차 한 실행 안에서 나온 비율입니다
#      기준선 계산 방식을 맞춰 3회 반복한다.
#
# 이 스크립트는 컨테이너 안이 아니라 호스트에서 docker exec 로 돈다.
# run.sh 는 runner 컨테이너 안에서 도는데, 이 실험은 회차마다 상태를 되돌려야 해서
# 바깥에서 제어하는 편이 낫다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
DB=lab-b43-pg
ROWS=${ROWS:-3000000}
CHUNK=${CHUNK:-100000}
REPEAT=${REPEAT:-3}

P(){ docker exec "$DB" psql -U lab -d lab -X -qAt -c "$1" 2>&1; }
PT(){ docker exec "$DB" psql -U lab -d lab -X -c "$1" 2>&1; }

for _ in $(seq 1 60); do docker exec "$DB" pg_isready -U lab -d lab >/dev/null 2>&1 && break; sleep 2; done
docker exec "$DB" pg_isready -U lab -d lab >/dev/null 2>&1 \
  || { echo "중단: $DB 가 준비되지 않았습니다" >&2; exit 2; }

# pg_stat_io 는 16 에서 들어왔다. 없으면 이 실험의 절반이 성립하지 않으므로 먼저 확인한다.
HAS_IO=$(P "SELECT COUNT(*) FROM pg_class WHERE relname='pg_stat_io'")
[ "$HAS_IO" = "1" ] || echo "경고: pg_stat_io 가 없습니다(PostgreSQL 16 미만). I/O 증거는 건너뜁니다."

# 조회 한 번의 소요를 밀리초로. 서버 시간만 재려고 \timing 대신 EXPLAIN 의 실행 시간을 쓴다.
probe_ms(){
  P "EXPLAIN (ANALYZE, TIMING ON, FORMAT JSON) SELECT count(*) FROM orders_v2" \
    | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(f\"{d[0]['Execution Time']:.1f}\")
except Exception:
    print('0')
"
}

# 같은 조회의 버퍼 접근을 본다. 이것이 '디스크 경쟁' 가설의 양성 증거다.
probe_buffers(){
  P "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT count(*) FROM orders_v2" \
    | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())[0]['Plan']
    def walk(p, acc):
        for k in ('Shared Hit Blocks','Shared Read Blocks','Shared Dirtied Blocks','Shared Written Blocks'):
            acc[k] = acc.get(k, 0) + p.get(k, 0)
        for c in p.get('Plans', []): walk(c, acc)
        return acc
    a = walk(d, {})
    print(f\"{a['Shared Hit Blocks']} {a['Shared Read Blocks']} {a['Shared Dirtied Blocks']} {a['Shared Written Blocks']}\")
except Exception:
    print('0 0 0 0')
"
}

io_snapshot(){
  [ "$HAS_IO" = "1" ] || { echo "0 0 0"; return; }
  P "SELECT COALESCE(SUM(reads),0)||' '||COALESCE(SUM(writes),0)||' '||COALESCE(SUM(extends),0)
     FROM pg_stat_io WHERE backend_type IN ('client backend','autovacuum worker','background writer','checkpointer')"
}

reset_table(){
  P "DROP TABLE IF EXISTS orders_v2" >/dev/null
  P "CREATE TABLE orders_v2 (id bigserial PRIMARY KEY, amount numeric(12,2), memo text)" >/dev/null
  P "INSERT INTO orders_v2 (amount, memo)
     SELECT (random()*100000)::numeric(12,2), repeat(md5(g::text), 2)
     FROM generate_series(1, $ROWS) g" >/dev/null
  P "VACUUM ANALYZE orders_v2" >/dev/null
  P "ALTER TABLE orders_v2 ADD COLUMN trace_id uuid" >/dev/null
}

{
echo "# 백필 중 지연의 양성 증거, VACUUM 회수 비용, 비율 반복"
echo "# PostgreSQL $(P 'SHOW server_version')"
echo "# ${ROWS}행, 청크 ${CHUNK}행, ${REPEAT}회 반복"
echo

: > "$OUT/backfill-evidence.csv"
echo "run,phase,ms,hit_blocks,read_blocks,dirtied,written" >> "$OUT/backfill-evidence.csv"

for run in $(seq 1 "$REPEAT"); do
  echo "=================================================================="
  echo "## 회차 $run"
  echo "=================================================================="
  reset_table

  # ── 기준선 ────────────────────────────────────────────────────────
  # 같은 조회를 세 번 재고 중앙값을 쓴다. 원 실행은 기준선을 따로 옮겨 적지 않아
  # 같은 방식으로 비율을 못 냈다. 여기서는 두 구간을 같은 방식으로 잰다.
  base=()
  for _ in 1 2 3; do base+=("$(probe_ms)"); done
  BASE=$(printf '%s\n' "${base[@]}" | sort -n | sed -n 2p)
  read -r bh br bd bw <<< "$(probe_buffers)"
  echo "  기준선 조회 = ${BASE}ms  (버퍼 hit ${bh} / read ${br})"
  echo "$run,baseline,$BASE,$bh,$br,$bd,$bw" >> "$OUT/backfill-evidence.csv"

  IO0=$(io_snapshot)

  # ── 백필 중 ───────────────────────────────────────────────────────
  (
    i=0
    while [ "$i" -lt "$ROWS" ]; do
      docker exec "$DB" psql -U lab -d lab -X -q -c \
        "UPDATE orders_v2 SET trace_id = gen_random_uuid()
          WHERE id > $i AND id <= $((i + CHUNK)) AND trace_id IS NULL" >/dev/null 2>&1
      i=$((i + CHUNK))
    done
  ) &
  BF=$!
  sleep 5
  dur=()
  for _ in 1 2 3; do dur+=("$(probe_ms)"); done
  DUR=$(printf '%s\n' "${dur[@]}" | sort -n | sed -n 2p)
  read -r dh dr dd dw <<< "$(probe_buffers)"
  wait $BF
  IO1=$(io_snapshot)
  read -r r0 w0 e0 <<< "$IO0"; read -r r1 w1 e1 <<< "$IO1"
  echo "  백필 중 조회 = ${DUR}ms  (버퍼 hit ${dh} / read ${dr})"
  echo "$run,during,$DUR,$dh,$dr,$dd,$dw" >> "$OUT/backfill-evidence.csv"
  RATIO=$(python3 -c "print(f'{${DUR:-0}/${BASE:-1}:.1f}')")
  echo "  배수 = ${RATIO}배  (같은 방식으로 잰 기준선 대비)"
  echo "  백필 구간 pg_stat_io 증분: reads $((r1-r0)), writes $((w1-w0)), extends $((e1-e0))"
  echo
  echo "  이것이 양성 증거입니다. 지연이 늘어난 조회의 read 블록이 기준선보다 많으면"
  echo "  버퍼에서 밀려나 디스크로 다시 간 것이고, writes 와 extends 가 늘었으면"
  echo "  백필이 그 자리를 쓴 것입니다. 락은 앞 절에서 이미 배제했습니다."
  echo

  # ── 백필 뒤 상태와 VACUUM ─────────────────────────────────────────
  PT "SELECT pg_size_pretty(pg_relation_size('orders_v2')) AS \"힙 크기\",
             n_live_tup AS \"산 튜플\", n_dead_tup AS \"죽은 튜플\",
             COALESCE(last_autovacuum::text,'아직 없음') AS \"마지막 autovacuum\"
      FROM pg_stat_user_tables WHERE relname='orders_v2'" | sed 's/^/  /'
  SZ0=$(P "SELECT pg_relation_size('orders_v2')")
  T0=$(date +%s%N)
  P "VACUUM (VERBOSE, ANALYZE) orders_v2" > "$OUT/vacuum-run${run}.txt" 2>&1
  T1=$(date +%s%N)
  SZ1=$(P "SELECT pg_relation_size('orders_v2')")
  echo "  VACUUM 소요 = $(python3 -c "print(f'{($T1-$T0)/1e9:.2f}')")초"
  echo "  힙 크기 $(python3 -c "print(f'{$SZ0/1048576:.0f}')")MB → $(python3 -c "print(f'{$SZ1/1048576:.0f}')")MB"
  echo "  죽은 튜플 = $(P "SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='orders_v2'")"
  echo
  echo "  VACUUM 은 죽은 튜플을 재사용 가능으로 표시할 뿐 파일을 줄이지 않습니다."
  echo "  크기가 그대로면 그것이 이유입니다. 파일을 줄이려면 VACUUM FULL 이 필요하고"
  echo "  그것은 ACCESS EXCLUSIVE 를 잡습니다. 그래서 백필의 대가는 시간이 아니라"
  echo "  되찾기 어려운 공간입니다."
  echo
done

echo "=================================================================="
echo "## 회차별 배수"
echo "=================================================================="
python3 - "$OUT/backfill-evidence.csv" <<'PY'
import csv, sys, collections, statistics
rows = collections.defaultdict(dict)
for r in csv.DictReader(open(sys.argv[1])):
    rows[r['run']][r['phase']] = r
print(f"  {'회차':<6} {'기준선':>10} {'백필 중':>10} {'배수':>8} {'기준 read':>11} {'백필 read':>11}")
ratios = []
for run in sorted(rows):
    b, d = rows[run].get('baseline'), rows[run].get('during')
    if not b or not d: continue
    try:
        ratio = float(d['ms']) / float(b['ms'])
    except (ValueError, ZeroDivisionError):
        continue
    ratios.append(ratio)
    print(f"  {run:<6} {float(b['ms']):>9.1f}ms {float(d['ms']):>9.1f}ms {ratio:>7.1f}배 "
          f"{b['read_blocks']:>11} {d['read_blocks']:>11}")
if len(ratios) >= 2:
    print()
    print(f"  중앙 {statistics.median(ratios):.1f}배, 최소 {min(ratios):.1f}배, 최대 {max(ratios):.1f}배")
PY
echo
echo "  각 회차 1회 실행이고 조회만 3회 중앙값입니다."
} 2>&1 | tee "$OUT/exp-backfill-evidence.txt"
