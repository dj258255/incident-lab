#!/usr/bin/env bash
# README 의 "못 한 것" 두 개를 잡는다.
#
#   1) 풀 크기를 바꿔 가며 재지 않았습니다
#      "풀 확대를 택하지 않은 것은 측정 결과가 아니라 HikariCP 문서의 권고를 따른
#       판단입니다." 판단을 측정으로 바꾼다. 풀을 키우면 처리량이 어디까지 늘고
#       지연이 어디서 무너지는지 잰다.
#
#      HikariCP 문서는 풀을 키우는 것이 답이 아니라고 말한다. 커넥션은 결국 DB 의
#      코어와 디스크를 나눠 쓰는 것이라, 풀을 키우면 대기가 애플리케이션에서 DB 로
#      옮겨갈 뿐이라는 것이다. 그 말이 이 조건에서 맞는지가 질문이다.
#
#   2) max-threads 스윕은 조건마다 한 번씩입니다
#      네 조건이 단조롭게 움직여 방향은 편차로 보기 어렵지만 각 칸의 값 자체는
#      반복하지 않았다. 반복한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/results"; mkdir -p "$OUT/raw"
REPEAT=${REPEAT:-3}

# one-run.sh 가 남긴 k6 요약에서 필요한 값을 뽑는다.
# 형식이 바뀌어도 죽지 않게 못 찾으면 빈 값으로 둔다.
pick(){ # $1=라벨 $2=정규식
  grep -oE "$2" "$OUT/raw/$1-k6.txt" 2>/dev/null | head -1
}
summarize(){ # $1=라벨
  local f="$OUT/raw/$1-k6.txt"
  [ -f "$f" ] || { echo ",,,"; return; }
  python3 - "$f" <<'PY'
import re, sys
t = open(sys.argv[1], encoding='utf-8', errors='replace').read()
def num(pat, default=''):
    m = re.search(pat, t)
    return m.group(1) if m else default
# http_req_duration ... p(95)=123.45ms
p95 = num(r'http_req_duration[^\n]*?p\(95\)=([\d.]+)(?:ms|s)')
# checks 또는 http_reqs 에서 총 요청 수와 초당
reqs = num(r'http_reqs[^\n]*?:\s*([\d]+)')
rate = num(r'http_reqs[^\n]*?\s([\d.]+)/s')
# 상태코드별. 앱이 503 으로 흘려보낸 몫을 본다.
shed = num(r'shed[^\n]*?:\s*([\d]+)')
print(f"{p95},{reqs},{rate},{shed}")
PY
}

{
echo "# 풀 크기 스윕과 max-threads 반복"
echo "# 조건마다 ${REPEAT}회 반복입니다."
echo

# ── 1) 풀 크기 스윕 ─────────────────────────────────────────────────────
echo "=================================================================="
echo "## 1) 풀을 키우면 어떻게 되는가"
echo "=================================================================="
echo "  부하 차단 허용 수는 풀 크기와 같게 둡니다(기본 설계와 같은 관계)."
echo
: > "$OUT/pool-sweep.csv"
echo "pool,run,p95_ms,http_reqs,req_per_s,shed" >> "$OUT/pool-sweep.csv"
for pool in 10 20 50 100; do
  for run in $(seq 1 "$REPEAT"); do
    label="pool${pool}-r${run}"
    POOL_SIZE="$pool" SHED_PERMITS="$pool" \
      bash scripts/one-run.sh "$label" fixed > "$OUT/raw/$label-run.log" 2>&1 || true
    echo "$pool,$run,$(summarize "$label")" >> "$OUT/pool-sweep.csv"
  done
done
python3 - "$OUT/pool-sweep.csv" <<'PY'
import csv, sys, collections, statistics
rows = collections.defaultdict(list)
for r in csv.DictReader(open(sys.argv[1])):
    rows[r['pool']].append(r)
print(f"  {'풀':>6} {'p95 중앙':>12} {'초당 중앙':>12} {'차단 중앙':>11} {'회차':>6}")
for pool in sorted(rows, key=int):
    rs = rows[pool]
    def med(k):
        xs = [float(x[k]) for x in rs if x.get(k)]
        return statistics.median(xs) if xs else 0.0
    print(f"  {pool:>6} {med('p95_ms'):>11.1f}ms {med('req_per_s'):>12.1f} "
          f"{med('shed'):>11.0f} {len(rs):>6}")
print()
print("  읽는 법. 풀을 키워 초당 처리가 늘고 p95 가 안 오르면 문서의 권고가 이 조건에서는")
print("  안 맞는 것입니다. 처리는 느는데 p95 가 같이 오르면 대기가 애플리케이션에서")
print("  DB 로 옮겨간 것이고, 그것이 문서가 경고하는 상태입니다.")
print("  차단(503) 건수가 줄어드는 것은 받아 준 것이지 빨라진 것이 아닙니다.")
PY
echo

# ── 2) max-threads 반복 ─────────────────────────────────────────────────
echo "=================================================================="
echo "## 2) max-threads 스윕을 반복해서"
echo "=================================================================="
: > "$OUT/threads-repeat.csv"
echo "threads,run,p95_ms,http_reqs,req_per_s,shed" >> "$OUT/threads-repeat.csv"
for th in 10 50 200 800; do
  for run in $(seq 1 "$REPEAT"); do
    label="th${th}-r${run}"
    TOMCAT_MAX_THREADS="$th" \
      bash scripts/one-run.sh "$label" buggy > "$OUT/raw/$label-run.log" 2>&1 || true
    echo "$th,$run,$(summarize "$label")" >> "$OUT/threads-repeat.csv"
  done
done
python3 - "$OUT/threads-repeat.csv" <<'PY'
import csv, sys, collections, statistics
rows = collections.defaultdict(list)
for r in csv.DictReader(open(sys.argv[1])):
    rows[r['threads']].append(r)
print(f"  {'스레드':>8} {'p95 중앙':>12} {'p95 최소':>12} {'p95 최대':>12} {'초당 중앙':>12}")
for th in sorted(rows, key=int):
    rs = rows[th]
    xs = [float(x['p95_ms']) for x in rs if x.get('p95_ms')]
    ys = [float(x['req_per_s']) for x in rs if x.get('req_per_s')]
    if not xs: continue
    print(f"  {th:>8} {statistics.median(xs):>11.1f}ms {min(xs):>11.1f}ms "
          f"{max(xs):>11.1f}ms {statistics.median(ys) if ys else 0:>12.1f}")
print()
print("  회차별 최소와 최대가 조건 사이의 차이보다 작으면 방향을 믿을 수 있습니다.")
print("  겹치면 그 칸의 값은 인용하면 안 됩니다.")
PY
echo
docker compose down -v >/dev/null 2>&1 || true
echo "  각 조건 ${REPEAT}회 실행입니다."
} 2>&1 | tee "$OUT/exp-pool-sweep.txt"
