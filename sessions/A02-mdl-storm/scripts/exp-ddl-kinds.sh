#!/usr/bin/env bash
# README 의 "못 한 것" 두 개를 잡는다.
#
#   1) 테이블 재작성이 필요한 DDL 은 안 다뤘습니다
#      "ADD COLUMN 은 8.4 에서 INSTANT 라 실행 자체가 0.09초입니다. ALGORITHM=COPY 가
#       필요한 변경은 락을 훨씬 오래 쥡니다."
#      알고리즘을 명시한 세 DDL 을 같은 MDL 대기 조건에서 잰다.
#
#   2) 반복 측정을 하지 않았습니다
#      "조건마다 60초 한 번입니다."
#      세 DDL 을 REPEAT 회씩 돌려 회차 폭을 함께 남긴다.
#
# 갈리는 자리가 둘이다.
#   DDL 자신이 락을 얻기까지 기다린 시간  → 앞선 롱 트랜잭션이 정하므로 셋이 같아야 한다
#   DDL 이 락을 얻은 뒤 실제로 일한 시간   → 알고리즘이 정하므로 셋이 달라야 한다
# 앞의 것만 보면 세 DDL 이 같아 보이고, 뒤의 것이 "재작성이 필요한 DDL" 의 대가다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
REPEAT=${REPEAT:-3}
KINDS=${KINDS:-"instant inplace copy"}
CN=a02-mysql

M(){ docker exec "$CN" mysql -uroot -plab -N -B -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }

for _ in $(seq 1 90); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(M 'SELECT 1')" = "1" ] || { echo "중단: $CN 이 쿼리를 받지 못합니다" >&2; exit 2; }

# 적재 확인. mdl.py 는 randrange(1, 행수) 로 조회하므로 빈 표에서는 죽는다.
ROWS=$(M "SELECT COUNT(*) FROM lab.orders" | tr -d '[:space:]')
case "${ROWS:-0}" in ''|*[!0-9]*) ROWS=0 ;; esac
if [ "$ROWS" -lt 1000000 ]; then
  echo "적재가 ${ROWS}행뿐입니다. seed.py 를 먼저 돌립니다(약 145초)."
  (cd "$ROOT" && docker compose run --rm load python seed.py) >/dev/null 2>&1
  ROWS=$(M "SELECT COUNT(*) FROM lab.orders" | tr -d '[:space:]')
  case "${ROWS:-0}" in ''|*[!0-9]*) ROWS=0 ;; esac
fi
[ "$ROWS" -ge 1000000 ] || { echo "중단: lab.orders 가 ${ROWS}행입니다(기대 100만 이상)" >&2; exit 3; }

{
echo "# 알고리즘을 명시한 세 DDL 을 같은 MDL 대기 아래에서"
echo "# MySQL $(M 'SELECT VERSION()'), lab.orders ${ROWS}행"
echo "# DDL 종류 ${KINDS}, 각 ${REPEAT}회"
echo
echo "  세 DDL 다 앞선 롱 트랜잭션이 락을 놓을 때까지 기다립니다. 그 대기는 같아야 합니다."
echo "  갈리는 것은 락을 얻은 뒤 실제로 일한 시간입니다."
echo

: > "$OUT/ddl-kinds.csv"
echo "kind,run,ok,elapsed_s,lock_wait_timeout,stmt" >> "$OUT/ddl-kinds.csv"

for kind in $KINDS; do
  echo "### $kind"
  for run in $(seq 1 "$REPEAT"); do
    F="$OUT/ddl-kind-${kind}-r${run}.json"
    (cd "$ROOT" && docker compose run --rm load \
       python mdl.py --case ddl-default --ddl "$kind" \
       --out "/results/$(basename "$F")") >/dev/null 2>&1
    if [ ! -s "$F" ]; then
      echo "  run${run} 결과 파일이 없습니다. 이 회차는 버립니다"
      continue
    fi
    python3 - "$F" "$kind" "$run" "$OUT/ddl-kinds.csv" <<'PY'
import json, sys
f, kind, run, csvp = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = json.load(open(f, encoding='utf-8'))
ddl = d.get("ddl") or d.get("result") or {}
if not isinstance(ddl, dict):
    ddl = {}
ok = ddl.get("ok")
el = ddl.get("elapsed_s")
stmt = (ddl.get("stmt") or "").replace(",", " ")
if el is None:
    print(f"  run{run} DDL 결과를 못 읽었습니다({list(d)[:6]}). 이 회차는 버립니다")
else:
    err = ddl.get("error")
    print(f"  run{run} {'성공' if ok else '실패'} {el:>7.2f}초"
          + (f"  {err[:60]}" if err else ""))
    with open(csvp, "a", encoding='utf-8') as fh:
        fh.write(f"{kind},{run},{ok},{el},{ddl.get('lock_wait_timeout')},{stmt}\n")
PY
  done
  echo
done

echo "=================================================================="
echo "## 정리"
echo "=================================================================="
python3 - "$OUT/ddl-kinds.csv" <<'STATS'
import csv, sys, collections, statistics
rows = collections.defaultdict(list)
stmts = {}
for r in csv.DictReader(open(sys.argv[1], encoding='utf-8')):
    try:
        rows[r['kind']].append(float(r['elapsed_s']))
    except (ValueError, TypeError):
        continue
    stmts[r['kind']] = r.get('stmt', '')
if not rows:
    print("  유효한 회차가 없습니다"); raise SystemExit
LBL = {'instant': 'INSTANT (ADD COLUMN)', 'inplace': 'INPLACE (ADD INDEX)',
       'copy': 'COPY (테이블 재작성)'}
print(f"  {'알고리즘':<24} {'중앙':>9} {'최소':>9} {'최대':>9} {'폭':>9} {'회차':>5}")
med = {}
for k in ('instant', 'inplace', 'copy'):
    xs = rows.get(k, [])
    if not xs:
        continue
    med[k] = statistics.median(xs)
    print(f"  {LBL[k]:<24} {statistics.median(xs):>8.2f}s {min(xs):>8.2f}s "
          f"{max(xs):>8.2f}s {max(xs)-min(xs):>8.2f}s {len(xs):>5}")
if 'instant' in med and 'copy' in med and med['instant']:
    print()
    print(f"  COPY / INSTANT = {med['copy']/med['instant']:.1f}배")
print()
print("  이 시간은 DDL 이 락을 기다린 구간까지 포함한 전체입니다. 세 조건의 대기는 같게")
print("  맞춰 두었으므로, 차이는 락을 얻은 뒤의 작업량입니다.")
print("  회차 폭이 알고리즘 사이 차이보다 작아야 그 배수를 인용할 수 있습니다.")
STATS
echo
echo "  각 알고리즘 ${REPEAT}회 실행입니다."
} 2>&1 | tee "$OUT/exp-ddl-kinds.txt"
