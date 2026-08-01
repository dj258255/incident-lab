#!/usr/bin/env bash
# README 의 "못 한 것" 하나를 잡는다.
#
#   물리 복제 슬롯을 다루지 않았습니다
#   "이 세션은 논리 복제 슬롯(CDC)만 봤습니다. 물리 복제 슬롯도 WAL 을 붙잡는데
#    같은 방식으로 위험한지는 안 봤습니다."
#
# 둘의 차이가 실무에서 중요한 자리다.
#   논리 슬롯: 디코딩 플러그인이 붙는다. 컨슈머가 커밋을 확인해야 restart_lsn 이 움직인다.
#   물리 슬롯: 스탠바이가 붙는다. 스탠바이가 적용한 위치까지 움직인다.
# 붙잡는 메커니즘은 같지만, 죽었을 때 무엇이 다른지와 max_slot_wal_keep_size 가 둘 다에
# 걸리는지가 질문이다.
#
# 조건 넷:
#   1) 물리 슬롯을 만들고 아무도 안 붙임      → WAL 이 계속 쌓이는가
#   2) 논리 슬롯을 만들고 아무도 안 붙임      → 같은 조건의 대조군
#   3) 물리 슬롯 + max_slot_wal_keep_size    → 무효화되는가
#   4) 물리 슬롯을 지우면                     → 회수되는가
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
CN=r04-pg
WINDOW=${WINDOW:-40}
KEEP=${KEEP:-64MB}

P(){ docker exec "$CN" psql -U postgres -d spoon -X -tAc "$1" 2>&1; }

for _ in $(seq 1 90); do [ "$(P 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(P 'SELECT 1')" = "1" ] || { echo "중단: $CN 이 쿼리를 받지 못합니다" >&2; exit 2; }

# 이 세션의 표가 있어야 쓰기를 만들 수 있다. 없으면 만든다.
HAVE=$(P "SELECT count(*) FROM information_schema.tables WHERE table_name='watch_log'")
if [ "${HAVE:-0}" = "0" ]; then
  echo "watch_log 가 없습니다. 만듭니다."
  P "CREATE TABLE watch_log (id bigserial PRIMARY KEY, live_id int, payload text,
                             created_at timestamptz DEFAULT now())" >/dev/null
fi
HAVE=$(P "SELECT count(*) FROM information_schema.tables WHERE table_name='watch_log'")
[ "${HAVE:-0}" != "0" ] || { echo "중단: watch_log 를 못 만들었습니다" >&2; exit 3; }

drop_all_slots(){
  # 슬롯이 활성 상태면 지우기가 실패한다. 사라질 때까지 재시도한다.
  for _ in $(seq 1 30); do
    P "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots" >/dev/null 2>&1 || true
    [ "$(P 'SELECT count(*) FROM pg_replication_slots')" = "0" ] && return 0
    sleep 1
  done
  echo "  경고: 슬롯이 남아 있습니다: $(P 'SELECT string_agg(slot_name, \",\") FROM pg_replication_slots')"
  return 1
}

wal_mb(){ P "SELECT ROUND(SUM(size)/1048576.0, 1) FROM pg_ls_waldir()"; }

# 쓰기를 WINDOW 초 동안 돌린다.
write_for(){
  docker exec -d "$CN" bash -c "
    END=\$(( \$(date +%s) + $1 ))
    while [ \$(date +%s) -lt \$END ]; do
      psql -U postgres -d spoon -X -c \"INSERT INTO watch_log (live_id, payload)
        SELECT (random()*1000)::int, repeat(md5(random()::text), 32)
        FROM generate_series(1,400);\" >/dev/null 2>&1
    done"
}

# 조건 하나를 잰다. 시작 WAL 이 아니라 증가분으로 비교한다. 앞 조건이 남긴 값이
# 시작값을 오염시켜도 증가분은 살아남는다.
run_case(){ # $1=라벨 $2=슬롯종류(physical|logical|none) $3=keep설정(빈값이면 -1)
  local label="$1" kind="$2" keep="$3"
  echo
  echo "### $label"
  drop_all_slots || true
  docker exec "$CN" psql -U postgres -X -c \
    "ALTER SYSTEM SET max_slot_wal_keep_size='${keep:--1}'" >/dev/null 2>&1
  docker exec "$CN" psql -U postgres -X -c "SELECT pg_reload_conf()" >/dev/null 2>&1
  sleep 1
  echo "  max_slot_wal_keep_size = $(P "SELECT current_setting('max_slot_wal_keep_size')")"

  case "$kind" in
    physical) P "SELECT pg_create_physical_replication_slot('phys_slot', true)" >/dev/null ;;
    logical)  P "SELECT pg_create_logical_replication_slot('log_slot','test_decoding')" >/dev/null ;;
    none)     : ;;
  esac
  local made
  made=$(P "SELECT count(*) FROM pg_replication_slots")
  case "$kind" in
    none) [ "${made:-0}" = "0" ] || echo "  경고: 슬롯이 없어야 하는데 ${made}개 있습니다" ;;
    *)    [ "${made:-0}" = "1" ] || { echo "  중단: 슬롯이 안 만들어졌습니다(${made:-없음}개)"; return 1; } ;;
  esac
  echo "  슬롯 = $(P "SELECT COALESCE(string_agg(slot_name||'('||slot_type||')', ','), '없음') FROM pg_replication_slots")"

  P "CHECKPOINT" >/dev/null
  local w0 w1 grow
  w0=$(wal_mb)
  write_for "$WINDOW"
  sleep $((WINDOW + 3))
  P "CHECKPOINT" >/dev/null
  sleep 2
  w1=$(wal_mb)
  grow=$(python3 -c "print(f'{${w1:-0} - ${w0:-0}:.1f}')")
  echo "  WAL ${w0}MB → ${w1}MB (증가 ${grow}MB)"
  if [ "$kind" != "none" ]; then
    echo "  슬롯 상태 = $(P "SELECT COALESCE(string_agg(slot_name||' '||COALESCE(wal_status,'?')||' 붙잡은 '||
        COALESCE(pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)),'?'), ', '), '없음')
        FROM pg_replication_slots")"
  fi
  # 라벨에 쉼표가 있다("논리 슬롯, 컨슈머 없음"). 따옴표 없이 쓰면 필드가 7개가 되고
  # csv.DictReader 가 컬럼을 한 칸씩 민다. 그래서 grow_mb 가 wal_after_mb 를 읽어
  # 증가분 560.0MB 자리에 종료 시점 크기 816.0MB 가 들어갔고, 배수가 35배 대신
  # 51배로 발행됐다. 흔적은 요약표에 남아 있었다. "상한" 칸이 -1 이 아니라 logical 이다.
  # 라벨을 따옴표로 감싼다.
  echo "\"$label\",$kind,${keep:--1},${w0:-0},${w1:-0},${grow:-0}" >> "$OUT/physical-slot.csv"
}

{
echo "# 물리 복제 슬롯도 같은 방식으로 위험한가"
echo "# PostgreSQL $(P 'SHOW server_version')"
echo "# 조건마다 ${WINDOW}초 쓰기, 각 1회 실행입니다."
echo
echo "  비교는 시작 WAL 이 아니라 관측 창 안의 증가분으로 합니다."
echo "  앞 조건이 남긴 값이 시작값을 오염시켜도 증가분은 살아남습니다."

: > "$OUT/physical-slot.csv"
echo "label,kind,keep,wal_before_mb,wal_after_mb,grow_mb" >> "$OUT/physical-slot.csv"

run_case "대조군: 슬롯 없음" none ""
run_case "논리 슬롯, 컨슈머 없음" logical ""
run_case "물리 슬롯, 스탠바이 없음" physical ""
run_case "물리 슬롯 + 상한 ${KEEP}" physical "$KEEP"

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
python3 - "$OUT/physical-slot.csv" <<'STATS'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding='utf-8')))
if not rows:
    print("  결과가 없습니다"); raise SystemExit
base = next((float(r['grow_mb']) for r in rows if r['kind'] == 'none'), None)
print(f"  {'조건':<28} {'상한':>8} {'WAL 증가':>10} {'슬롯 없음 대비':>14}")
for r in rows:
    g = float(r['grow_mb'])
    ratio = f"{g/base:.2f}배" if base else "-"
    print(f"  {r['label']:<28} {r['keep']:>8} {g:>9.1f}MB {ratio:>14}")
print()
print("  슬롯 없음보다 크게 늘면 그 슬롯이 WAL 을 붙잡고 있는 것입니다.")
print("  논리와 물리가 비슷하게 늘면 붙잡는 메커니즘이 같다는 뜻이고,")
print("  상한을 걸었을 때만 안 늘면 max_slot_wal_keep_size 가 물리에도 걸린다는 뜻입니다.")
STATS
echo
echo "  설정을 되돌립니다."
docker exec "$CN" psql -U postgres -X -c "ALTER SYSTEM SET max_slot_wal_keep_size='-1'" >/dev/null 2>&1
docker exec "$CN" psql -U postgres -X -c "SELECT pg_reload_conf()" >/dev/null 2>&1
drop_all_slots || true
echo "  각 조건 1회 실행입니다."
} 2>&1 | tee "$OUT/exp5-physical-slot.txt"
