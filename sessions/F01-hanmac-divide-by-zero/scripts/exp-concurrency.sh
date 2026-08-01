#!/usr/bin/env bash
# README 의 "못 한 것" 하나를 잡는다.
#
#   동시성과 처리량을 측정하지 않았습니다. Spring 재현도 단일 인스턴스에서 인프로세스
#   드라이버로 순차 호출한 것입니다. 이 세션에는 시간축이 없습니다.
#
# 순차 호출로는 못 보는 것이 하나 있다. 컨트롤러가 이렇게 생겼다.
#
#   if (killswitch.tripped()) return 503;   // (A) 읽기
#   ...
#   killswitch.recordDeviation();           // (B) 증가 + 문턱 판정
#
# 순차면 문턱 T 건째에 (B) 가 켜지고 그다음이 (A) 에서 막힌다. 정확히 T 건이 통과한다.
# 동시면 여러 요청이 (A) 를 이미 지나간 뒤에 (B) 가 켜진다. 그 사이의 요청이 전부
# 통과한다. **탐지에서 차단까지의 틈이 동시성만큼 벌어진다.**
#
# 이것이 이 세션의 주제와 직결된다. 한맥은 킬스위치가 늦어서 2분 만에 460억을 잃었다.
# 늦는 이유가 사람의 판단만이 아니라 코드의 검사 후 행동 틈에도 있다는 것을 잰다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
SPRING="$ROOT/spring"
VUS_LIST=${VUS_LIST:-"1 4 16 64"}
DURATION=${DURATION:-15s}
THRESHOLD=${THRESHOLD:-3}
EP=${EP:-/orders/leaky-independent}
CN=lab-f01-hanmac-spring

cleanup(){ (cd "$SPRING" && LAB_MODE=server docker compose down >/dev/null 2>&1) || true; }
trap cleanup EXIT

echo "앱을 서버 모드로 띄웁니다(내장 드라이버는 안 돕니다)."
(cd "$SPRING" && LAB_MODE=server docker compose up -d --build >/dev/null 2>&1)

# 준비 확인. 404 가 아니라 실제 응답이 오는지 본다.
READY=""
for _ in $(seq 1 90); do
  if docker exec "$CN" sh -c "command -v curl >/dev/null 2>&1" 2>/dev/null; then
    R=$(docker exec "$CN" curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/health 2>/dev/null)
  else
    R=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/health 2>/dev/null)
  fi
  [ "$R" = "200" ] && { READY=1; break; }
  sleep 2
done
[ -n "$READY" ] || { echo "중단: 앱이 준비되지 않았습니다" >&2; exit 2; }
echo "준비 확인 완료"

NET=$(docker inspect "$CN" -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' | grep -v '^$' | head -1)
[ -n "$NET" ] || { echo "중단: 앱의 네트워크를 못 읽었습니다" >&2; exit 2; }

reset_ks(){
  local r
  r=$(curl -s -X POST "http://127.0.0.1:18080/killswitch/reset?threshold=${THRESHOLD}" 2>/dev/null)
  case "${r:-}" in
    *"threshold=${THRESHOLD}"*) : ;;
    *) echo "  중단: 킬스위치 리셋이 안 됐습니다(응답 ${r:-없음})" >&2; return 1 ;;
  esac
  local st; st=$(curl -s "http://127.0.0.1:18080/killswitch" 2>/dev/null)
  case "${st:-}" in
    *"tripped=false"*) : ;;
    *) echo "  중단: 리셋 뒤에도 tripped 가 false 가 아닙니다(${st:-없음})" >&2; return 1 ;;
  esac
}

{
echo "# 킬스위치가 걸리기까지 몇 건이 통과하는가"
echo "# 엔드포인트 ${EP}, 문턱 ${THRESHOLD}, 부하 ${DURATION}, 동시성 ${VUS_LIST}"
echo
echo "  순차 호출이면 정확히 문턱 수만큼 통과하고 그다음이 막혀야 합니다."
echo "  컨트롤러가 tripped() 를 읽고 나서 record 하는 사이에 틈이 있으므로,"
echo "  동시 요청이면 그 틈으로 더 통과합니다. 그 수를 셉니다."
echo

: > "$OUT/concurrency.csv"
echo "vus,passed_before_trip,c201,c422,c503,rps,p95_ms,max_ms" >> "$OUT/concurrency.csv"

for vus in $VUS_LIST; do
  reset_ks || continue
  LOG="$OUT/k6-vus${vus}.txt"
  docker run --rm --network "$NET" -v "$SPRING":/w -w /w \
    -e VUS="$vus" -e DURATION="$DURATION" -e EP="$EP" \
    grafana/k6 run --address= /w/k6-killswitch.js > "$LOG" 2>&1 || true
  python3 - "$LOG" "$vus" "$OUT/concurrency.csv" <<'PY'
import re, sys
log, vus, csvp = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(log, encoding='utf-8', errors='replace').read()
def num(pat, d=0):
    m = re.search(pat, t)
    return float(m.group(1)) if m else d
c201 = num(r'cnt_201[.\s]*:\s*(\d+)')
c422 = num(r'cnt_422[.\s]*:\s*(\d+)')
c503 = num(r'cnt_503[.\s]*:\s*(\d+)')
passed = num(r'passed_before_trip[.\s]*:\s*(\d+)')
rps = num(r'http_reqs[^\n]*?\s([\d.]+)/s')
p95 = num(r'dur_ms[^\n]*?p\(95\)=([\d.]+)')
mx = num(r'dur_ms[^\n]*?max=([\d.]+)')
total = c201 + c422 + c503
if total == 0:
    print(f"  VU {vus:<4} k6 출력을 못 읽었습니다. 이 조건은 버립니다")
else:
    print(f"  VU {vus:<4} 통과 {passed:>7.0f}건  접수 {c201:>7.0f}  거부 {c422:>7.0f}  "
          f"차단 {c503:>7.0f}  {rps:>8.1f}/s  p95 {p95:>7.1f}ms")
    with open(csvp, 'a', encoding='utf-8') as f:
        f.write(f"{vus},{passed:.0f},{c201:.0f},{c422:.0f},{c503:.0f},{rps},{p95},{mx}\n")
PY
done

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
python3 - "$OUT/concurrency.csv" "$THRESHOLD" <<'STATS'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding='utf-8')))
T = int(sys.argv[2])
if not rows:
    print("  유효한 조건이 없습니다"); raise SystemExit
print(f"  {'동시성':>6} {'통과 건수':>10} {'문턱 대비':>10} {'처리량':>11} {'p95':>9} {'최대':>9}")
base = None
for r in rows:
    p = int(r['passed_before_trip'])
    if base is None:
        base = p
    print(f"  {r['vus']:>6} {p:>10,} {p/T:>9.1f}배 {float(r['rps']):>10.1f}/s "
          f"{float(r['p95_ms']):>8.1f}ms {float(r['max_ms']):>8.1f}ms")
print()
print(f"  문턱은 {T} 입니다. 순차라면 통과가 {T} 건이어야 합니다.")
print("  동시성이 올라갈수록 통과 건수가 늘면, 그 초과분이 탐지와 차단 사이의 틈입니다.")
print("  이 틈은 킬스위치의 문턱을 낮춰도 안 줄어듭니다. 검사와 기록이 원자적이지")
print("  않은 것이 원인이므로, 줄이려면 그 두 동작을 한 번에 해야 합니다.")
STATS
echo
echo "  각 조건 1회 실행입니다."
} 2>&1 | tee "$OUT/exp-concurrency.txt"
