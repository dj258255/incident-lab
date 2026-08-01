#!/usr/bin/env bash
# README 의 "못 한 것" 하나를 잡는다.
#
#   동시성과 처리량을 측정하지 않았습니다. Spring 재현도 단일 인스턴스에서 인프로세스
#   드라이버로 순차 호출한 것입니다. 이 세션에는 시간축이 없습니다.
#
# 처음에는 킬스위치의 검사 후 행동 경합을 노렸다. 문턱 3 이 밀리초 안에 걸려서
# JIT 워밍업과 램프업이 신호를 덮었고, 통과 건수가 8 → 68 → 34 → 26 으로 단조가
# 아니었다. **재려던 것보다 잡음이 컸다.** 표적을 바꾼다.
#
# /orders/leaky 는 가드에 구멍이 있다. NaN 은 isInfinite 에 안 걸리고, 상한·하한
# 비교가 NaN 에서 전부 false 라 **접수(201)된다.** 킬스위치는 Infinite 만 세므로
# 영원히 안 걸린다. 즉 잘못된 주문이 기계 속도로 계속 접수된다.
#
# 그러면 경합을 잴 필요가 없다. **초당 접수되는 NaN 주문 수가 곧 피해 속도다.**
# 한맥은 2분에 3만 6천 건이 체결됐고, 정확히 이 축이다. 순차 드라이버 120건으로는
# 그 축이 아예 없었다. 동시성을 바꿔 가며 그 속도를 잰다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
SPRING="$ROOT/spring"
VUS_LIST=${VUS_LIST:-"1 4 16 64"}
DURATION=${DURATION:-15s}
THRESHOLD=${THRESHOLD:-3}
EP=${EP:-/orders/leaky}
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

# k6 가 붙을 주소. 컨테이너 이름과 compose 서비스 이름 둘 다 네트워크에서 풀린다.
TARGET=${TARGET:-http://app:8080}
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
echo "  이 엔드포인트는 NaN 이 가드를 통과해 접수됩니다. 킬스위치는 Infinite 만 세므로"
echo "  안 걸립니다. 초당 접수 건수가 곧 잘못된 주문이 쌓이는 속도입니다."
echo

: > "$OUT/concurrency.csv"
echo "vus,passed_before_trip,c201,c422,c503,rps,p95_ms,max_ms,c_nan" >> "$OUT/concurrency.csv"

for vus in $VUS_LIST; do
  reset_ks || continue
  LOG="$OUT/k6-vus${vus}.txt"
  docker run --rm --network "$NET" -v "$SPRING":/w -w /w \
    -e VUS="$vus" -e DURATION="$DURATION" -e EP="$EP" -e TARGET="$TARGET" \
    grafana/k6 run --address= /w/k6-killswitch.js > "$LOG" 2>&1 || true
  # 요청이 실제로 나갔는지 먼저 본다. 주소가 틀리면 k6 는 에러 없이 빈 통계를 낸다.
  if grep -qE "data_received[.\s]*:\s*0 B" "$LOG"; then
    echo "  VU ${vus} 요청이 한 건도 안 나갔습니다(data_received 0 B). 대상 주소를 확인하십시오"
    continue
  fi
  python3 - "$LOG" "$vus" "$OUT/concurrency.csv" <<'PY'
import re, sys
log, vus, csvp = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(log, encoding='utf-8', errors='replace').read()
def num(pat, d=0):
    m = re.search(pat, t)
    return float(m.group(1)) if m else d
c201 = num(r'cnt_201[.\s]*:\s*(\d+)')
cnan = num(r'cnt_nan_accepted[.\s]*:\s*(\d+)')
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
    # NaN 비율이 10% 이므로 접수된 것 중 대략 그만큼이 잘못된 주문이다.
    print(f"  VU {vus:<4} 접수 {c201:>8.0f}건(그중 NaN {cnan:>7.0f})  거부 {c422:>7.0f}  "
          f"차단 {c503:>7.0f}  NaN 초당 {cnan/15:>7.1f}/s  p95 {p95:>7.1f}ms")
    with open(csvp, 'a', encoding='utf-8') as f:
        f.write(f"{vus},{passed:.0f},{c201:.0f},{c422:.0f},{c503:.0f},{rps},{p95},{mx},{cnan:.0f}\n")
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
SEC = 15.0
print(f"  {'동시성':>6} {'NaN 접수':>11} {'초당':>11} {'VU 1 대비':>11} {'p95':>9} {'2분 환산':>12}")
base = None
for r in rows:
    c = int(r.get('c_nan') or r['c201'])
    if base is None:
        base = c
    per = c / SEC
    print(f"  {r['vus']:>6} {c:>11,} {per:>10.1f}/s {c/base if base else 0:>10.1f}배 "
          f"{float(r['p95_ms']):>8.1f}ms {per*120:>11,.0f}건")
print()
print("  마지막 열은 이 속도가 2분 이어졌을 때의 건수입니다. 한맥은 2분에 3만 6천 건이")
print("  체결됐습니다. 같은 자릿수에 닿는지가 이 표의 요지입니다.")
print()
print("  이 엔드포인트의 킬스위치는 한 번도 안 걸립니다(차단 0). Infinite 만 세는데")
print("  들어오는 것은 NaN 이기 때문입니다. **탐지원이 가드와 같으면 가드의 구멍이")
print("  탐지의 구멍이 됩니다.** 접수 건수는 동시성에 그대로 비례해 늘어납니다.")
STATS
echo
echo "  각 조건 1회 실행입니다."
} 2>&1 | tee "$OUT/exp-concurrency.txt"
