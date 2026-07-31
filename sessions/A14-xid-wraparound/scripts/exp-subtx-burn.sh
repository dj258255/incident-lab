#!/usr/bin/env bash
# README 의 "못 한 것" 하나를 잡는다.
#
#   서브트랜잭션의 기여
#   "서브트랜잭션은 XID 소비를 배로 늘려 이 위험을 키웁니다. 이 랩의 A19 가
#    서브트랜잭션을 다루지만, XID 소비율을 두 세션에 걸쳐 잇지는 않았습니다."
#
# 이 세션의 주제는 XID 가 21억을 채우는 것이고, A19 의 주제는 서브트랜잭션이 SLRU 를
# 압박하는 것이다. 둘을 잇는 축이 하나 있다. **쓰기를 하는 SAVEPOINT 는 XID 를 하나 더
# 쓴다.** 그러면 같은 업무량에 XID 소비가 몇 배가 되고, wraparound 까지의 시간이 그만큼
# 짧아진다. 그 배수를 잰다.
#
# 재는 법. XID 를 직접 읽는 함수(pg_current_xact_id)는 **부르는 것만으로 XID 를 할당한다.**
# 그래서 그것으로 재면 측정 자체가 결과를 바꾼다. 스냅숏의 xmax 를 쓰면 할당 없이 읽는다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
CN=a14-pg
TXNS=${TXNS:-2000}
SP_LIST=${SP_LIST:-"0 1 4 16"}

# 서버가 뜰 때까지 기다리고 데이터베이스 이름을 정한다. 이 세션은 lab 을 쓰는데
# 컨테이너를 새로 띄우면 postgres 만 있을 수 있다.
DBNAME=""
for _ in $(seq 1 90); do
  for d in lab postgres; do
    if [ "$(docker exec "$CN" psql -U postgres -d "$d" -X -qAt -c 'SELECT 1' 2>/dev/null)" = "1" ]; then
      DBNAME="$d"; break 2
    fi
  done
  sleep 2
done
[ -n "$DBNAME" ] || { echo "중단: $CN 이 쿼리를 받지 못합니다" >&2; exit 2; }

Q(){ docker exec "$CN" psql -U postgres -d "$DBNAME" -X -qAt -c "$1" 2>&1; }

Q "DROP TABLE IF EXISTS subtx_burn" >/dev/null
Q "CREATE TABLE subtx_burn (id bigserial PRIMARY KEY, n int NOT NULL)" >/dev/null

# 할당 없이 현재 XID 위치를 읽는다.
xid_now(){ Q "SELECT pg_snapshot_xmax(pg_current_snapshot())::text::bigint"; }

# 트랜잭션 하나가 본문 쓰기 1건 + SAVEPOINT 쓰기 $1 건을 한다.
# 업무량(넣는 행 수)은 조건마다 다르므로, 아래에서 행당 XID 로 정규화한다.
run_case(){ # $1=세이브포인트 수
  local sp="$1" body="" i
  for i in $(seq 1 "$sp"); do
    body="${body} SAVEPOINT s${i}; INSERT INTO subtx_burn (n) VALUES (${i});"
  done
  Q "TRUNCATE subtx_burn" >/dev/null
  local x0 x1 r1 t0 t1
  x0=$(xid_now)
  t0=$(date +%s%N)
  # DO 블록 안에서는 SAVEPOINT 를 못 쓴다. 클라이언트 쪽에서 트랜잭션을 돌린다.
  {
    for i in $(seq 1 "$TXNS"); do
      echo "BEGIN; INSERT INTO subtx_burn (n) VALUES (0);${body} COMMIT;"
    done
  } | docker exec -i "$CN" psql -U postgres -d "$DBNAME" -X -q >/dev/null 2>&1
  t1=$(date +%s%N)
  x1=$(xid_now)
  r1=$(Q "SELECT count(*) FROM subtx_burn")
  case "${r1:-}" in ''|*[!0-9]*) r1=0 ;; esac
  local expect=$(( TXNS * (sp + 1) ))
  if [ "$r1" -lt "$expect" ]; then
    echo "  세이브포인트 ${sp}개: 넣은 행이 ${r1}건입니다(기대 ${expect}). 이 조건은 버립니다"
    return 1
  fi
  local burn=$(( x1 - x0 ))
  printf "  %14s %12s %12s %14s %10s\n" \
    "${sp}개" "$(printf "%'d" "$burn")" "$(printf "%'d" "$r1")" \
    "$(python3 -c "print(f'{${burn}/${r1}:.3f}')")" \
    "$(python3 -c "print(f'{(${t1}-${t0})/1e9:.1f}초')")"
  echo "$sp,$burn,$r1,$TXNS" >> "$OUT/subtx-burn.csv"
}

{
echo "# 쓰기를 하는 SAVEPOINT 가 XID 를 얼마나 더 쓰는가"
echo "# PostgreSQL $(Q 'SHOW server_version'), 데이터베이스 ${DBNAME}"
echo "# 트랜잭션 ${TXNS}건, 세이브포인트 ${SP_LIST}"
echo
echo "  XID 위치는 pg_snapshot_xmax 로 읽습니다. pg_current_xact_id 는 부르는 것만으로"
echo "  XID 를 할당하므로 그것으로 재면 측정이 결과를 바꿉니다."
echo
: > "$OUT/subtx-burn.csv"
echo "savepoints,xid_burn,rows,txns" >> "$OUT/subtx-burn.csv"
printf "  %14s %12s %12s %14s %10s\n" "세이브포인트" "XID 소비" "넣은 행" "행당 XID" "소요"
for sp in $SP_LIST; do
  run_case "$sp" || true
done

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
python3 - "$OUT/subtx-burn.csv" <<'STATS'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding='utf-8')))
if not rows:
    print("  유효한 조건이 없습니다"); raise SystemExit
base = next((r for r in rows if r['savepoints'] == '0'), None)
print(f"  {'세이브포인트':>12} {'트랜잭션당 XID':>16} {'세이브포인트 없음 대비':>22}")
b = int(base['xid_burn']) / int(base['txns']) if base else 0
for r in rows:
    per = int(r['xid_burn']) / int(r['txns'])
    ratio = f"{per/b:.2f}배" if b else "-"
    print(f"  {r['savepoints']+'개':>12} {per:>15.2f} {ratio:>22}")
print()
print("  트랜잭션 하나가 세이브포인트 n 개에서 쓰기를 하면 XID 를 n+1 개 씁니다.")
print("  본문 하나에 서브트랜잭션 n 개이기 때문입니다.")
print()
if b:
    LIMIT = 2_000_000_000
    print(f"  초당 트랜잭션 1,000건을 가정하면 wraparound({LIMIT:,})까지")
    for r in rows:
        per = int(r['xid_burn']) / int(r['txns'])
        if per <= 0:
            continue
        days = LIMIT / (per * 1000) / 86400
        print(f"    세이브포인트 {r['savepoints']:>2}개  {days:>8.1f}일")
    print()
    print("  autovacuum 이 정상이면 이 날짜에 도달하지 않습니다. 이 표가 말하는 것은")
    print("  autovacuum 이 멈춰 있을 때 남은 시간이 세이브포인트 수만큼 짧아진다는 것입니다.")
    print("  A19 가 다루는 SLRU 압박과 이 세션이 다루는 XID 소진이 같은 원인에서 나옵니다.")
STATS
echo
echo "  각 조건 1회 실행입니다."
} 2>&1 | tee "$OUT/exp-subtx-burn.txt"
