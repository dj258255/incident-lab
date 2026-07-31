#!/usr/bin/env bash
# README 의 "못 한 것" 중 이 환경에서 되는 다섯 개를 잰다.
#
#   1) 콜드에서 출발하지 못했습니다
#      workload.py 가 임포트 시점에 COUNT(*) 로 클러스터드 인덱스를 통째로 훑어서
#      모든 조건이 풀 스캔 직후에서 워밍업을 시작했다. --cold 로 MIN/MAX 만 읽게 하고
#      같은 조건을 다시 잰다. 큰 풀의 0페이지 miss 가 그 스캔이 만들어 준 값이었는지 본다.
#
#   2) 쓰기 부하를 섞지 않았습니다
#      읽기 전용이라 축소할 때 플러시할 더티 페이지가 없었다. 축소 3.5초는 하한이다.
#      --write-ratio 로 갱신을 섞어 축소를 다시 잰다.
#
#   3) 캐시가 다 찬 구간은 CPU 에 눌려 있습니다
#      2코어라 4,200 q/s 근처가 천장이다. 코어를 늘려 1536M 과 2G 가 갈리는지 본다.
#
#   4) O_DIRECT 조건의 블록 I/O 가 InnoDB 가 센 읽기의 2.0배입니다
#      리드어헤드를 의심만 하고 확인하지 않았다. read_ahead 카운터를 같이 남기게 고쳤으니
#      실제로 도는지 본다.
#
#   5) 버퍼 풀 인스턴스를 1로 고정했습니다
#      인스턴스를 8로 두고 같은 조건을 잰다.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=results
WARMUP=${WARMUP:-30}
DURATION=${DURATION:-60}

# compose 의 cpus·instances 를 덮어쓸 수 있게 오버라이드 파일을 만든다.
# compose.yml 자체는 손대지 않는다. 기존 결과의 재현 조건이 거기 적혀 있다.
ovr(){ # $1=cpus $2=instances
  cat > compose.override.yml <<YML
services:
  mysql:
    cpus: $1
    command:
      - --innodb-buffer-pool-size=\${BP_SIZE:-128M}
      - --innodb-buffer-pool-instances=$2
      - --innodb-flush-method=O_DIRECT
      - --innodb-flush-neighbors=0
      - --innodb-io-capacity=2000
      - --innodb-io-capacity-max=4000
      - --skip-innodb-adaptive-hash-index
YML
}
noovr(){ rm -f compose.override.yml; }
trap noovr EXIT

bench(){ # $1=BP_SIZE $2=라벨 $3...=workload.py 추가 인자
  local sz=$1 label=$2; shift 2
  BP_SIZE=$sz docker compose down >/dev/null 2>&1 || true
  BP_SIZE=$sz docker compose up -d --wait mysql >/dev/null 2>&1
  BP_SIZE=$sz docker compose run --rm load python workload.py \
    --dist hot --warmup "$WARMUP" --duration "$DURATION" \
    --label "$label" --out "/results/extra-${label}.json" "$@"
}

show(){ python3 - "$@" <<'PY'
import json, sys
rows=[]
for f in sys.argv[1:]:
    try: d=json.load(open(f))
    except Exception: continue
    rows.append(d)
if not rows: print("  (결과 없음)"); raise SystemExit
print(f"  {'조건':<26} {'q/s':>8} {'p95':>8} {'히트율':>9} {'디스크읽기':>11} {'리드어헤드':>11} {'더티':>8}")
for d in rows:
    print(f"  {d['label']:<26} {d.get('qps',0):>8.1f} {d.get('p95_ms') or 0:>8.3f} "
          f"{d.get('hit_rate_pct') or 0:>8.4f}% {d.get('disk_reads',0):>11,} "
          f"{d.get('read_ahead',0):>11,} {d.get('pages_dirty',0):>8,}")
PY
}

{
echo "# A08 남은 항목 다섯"
echo "# 조건마다 워밍업 ${WARMUP}초, 측정 ${DURATION}초, 1회 실행"
echo

# ── 1) 콜드 출발 ────────────────────────────────────────────────────────
echo "## 1) 콜드에서 출발하면 곡선이 달라지는가"
echo "  기존 측정은 임포트 시점 COUNT(*) 때문에 풀 스캔 직후에서 워밍업을 시작했습니다."
echo "  --cold 는 MIN/MAX 만 읽습니다. B-Tree 양 끝 리프 페이지만 건드립니다."
ovr 2 1
for sz in 128M 512M 2G; do
  bench "$sz" "warm-$sz" >/dev/null 2>&1
  bench "$sz" "cold-$sz" --cold >/dev/null 2>&1
done
show "$OUT"/extra-warm-*.json "$OUT"/extra-cold-*.json
echo

# ── 2) 쓰기를 섞은 축소 ─────────────────────────────────────────────────
echo "## 2) 쓰기를 섞으면 축소가 얼마나 더 걸리는가"
echo "  읽기 전용 축소 3.5초는 하한입니다. 더티 페이지가 없었기 때문입니다."
# 쓰기 비율을 0.2 하나만 봤다. 더티 페이지가 늘수록 축소가 얼마나 더 걸리는지
# 곡선을 그리려면 점이 더 있어야 한다.
for wr in 0.0 0.1 0.2 0.4 0.8; do
  BP_SIZE=2G docker compose down >/dev/null 2>&1 || true
  BP_SIZE=2G docker compose up -d --wait mysql >/dev/null 2>&1
  BP_SIZE=2G docker compose run --rm load python workload.py \
    --dist hot --warmup "$WARMUP" --duration 90 \
    --write-ratio "$wr" --action-at 30 \
    --action-sql "SET GLOBAL innodb_buffer_pool_size = 134217728" \
    --label "shrink-write-${wr}" \
    --out "/results/extra-shrink-write-${wr}.json" >/dev/null 2>&1
done
python3 - "$OUT"/extra-shrink-write-*.json <<'PY'
import json, sys
print(f"  {'쓰기 비율':<10} {'문장 반환':>10} {'안정까지':>10} {'최대 지연':>11} {'더티':>10} {'최종 풀':>9}")
for f in sys.argv[1:]:
    try: d=json.load(open(f))
    except Exception: continue
    a=d.get("action") or {}
    if a.get("error"):
        print(f"  {d.get('write_ratio',0):<10} 실행 실패: {a['error']}")
        continue
    print(f"  {d.get('write_ratio',0):<10} {a.get('stmt_ms',0):>9.0f}ms {a.get('settle_s',0):>9.2f}초 "
          f"{d.get('max_ms') or 0:>10.1f}ms {d.get('pages_dirty',0):>10,} {a.get('final_pool_mb',0):>7}MB")
PY
echo

# ── 3) 코어를 늘리면 1536M 과 2G 가 갈리는가 ────────────────────────────
echo "## 3) 코어를 늘리면 큰 풀끼리 갈리는가"
echo "  2코어에서는 4,200 q/s 근처가 천장이라 1536M 과 2G 가 구별되지 않았습니다."
for cpu in 2 6; do
  ovr "$cpu" 1
  for sz in 1536M 2G; do
    bench "$sz" "cpu${cpu}-$sz" --procs "$cpu" >/dev/null 2>&1
  done
done
show "$OUT"/extra-cpu*.json
echo

# ── 4) 리드어헤드가 실제로 도는가 ───────────────────────────────────────
echo "## 4) O_DIRECT 의 블록 I/O 격차가 리드어헤드 때문인가"
echo "  위 표의 리드어헤드 열이 답입니다. 0 이면 리드어헤드는 원인이 아닙니다."
python3 - "$OUT"/extra-warm-*.json "$OUT"/extra-cold-*.json <<'PY'
import json, sys
tot_ra=tot_rd=0
for f in sys.argv[1:]:
    try: d=json.load(open(f))
    except Exception: continue
    tot_ra+=d.get("read_ahead",0); tot_rd+=d.get("disk_reads",0)
print(f"  전체 조건 합계: 디스크 읽기 {tot_rd:,}페이지, 리드어헤드 {tot_ra:,}페이지")
print(f"  리드어헤드 비중 {100*tot_ra/tot_rd:.2f}%" if tot_rd else "  (읽기 없음)")
PY
echo

# ── 5) 인스턴스를 8로 ───────────────────────────────────────────────────
echo "## 5) 버퍼 풀 인스턴스를 8로 두면"
echo "  크기는 chunk_size x instances 의 배수로 반올림되므로 실제 적용값을 같이 봅니다."
ovr 2 8
for sz in 512M 2G; do
  bench "$sz" "inst8-$sz" >/dev/null 2>&1
done
python3 - "$OUT"/extra-inst8-*.json "$OUT"/extra-warm-512M.json "$OUT"/extra-warm-2G.json <<'PY'
import json, sys
print(f"  {'조건':<20} {'인스턴스':>9} {'실제 풀':>9} {'q/s':>9} {'p95':>8} {'히트율':>9}")
for f in sys.argv[1:]:
    try: d=json.load(open(f))
    except Exception: continue
    print(f"  {d['label']:<20} {d.get('instances',0):>9} {d.get('buffer_pool_mb',0):>7}MB "
          f"{d.get('qps',0):>9.1f} {d.get('p95_ms') or 0:>8.3f} {d.get('hit_rate_pct') or 0:>8.4f}%")
PY
noovr
echo
echo "  각 조건 1회 실행입니다."

# ── 5) 워밍업까지 없앤 진짜 콜드 스타트 ────────────────────────────────
# 8절의 --cold 는 임포트 시점의 풀 스캔만 없앴고 측정 전 워밍업 30초는 그대로 뒀다.
# 그래서 "콜드" 라고 적었지만 실제로는 30초 데워진 상태에서 잰 값이다.
# 워밍업을 0 으로 두고 같은 조건을 다시 잰다.
echo "=================================================================="
echo "## 5) 워밍업까지 없앤 콜드 스타트"
echo "=================================================================="
echo "  8절의 콜드 조건도 측정 전 워밍업 30초는 그대로 뒀습니다. 그것까지 없앱니다."
echo "  기동 직후 첫 요청이 실제로 얼마나 느린지가 이 표의 질문입니다."
echo
for sz in 256M 1G 2G; do
  for wu in 0 30; do
    BP_SIZE="$sz" docker compose down >/dev/null 2>&1 || true
    BP_SIZE="$sz" docker compose up -d --wait mysql >/dev/null 2>&1
    BP_SIZE="$sz" docker compose run --rm load python workload.py \
      --dist hot --warmup "$wu" --duration 60 --cold \
      --label "truecold-${sz}-w${wu}" \
      --out "/results/extra-truecold-${sz}-w${wu}.json" >/dev/null 2>&1
  done
done
python3 - "$OUT"/extra-truecold-*.json <<'PY'
import json, sys, re, collections
rows = collections.defaultdict(dict)
for f in sys.argv[1:]:
    m = re.search(r"truecold-(\w+)-w(\d+)\.json$", f)
    if not m:
        continue
    try:
        d = json.load(open(f, encoding='utf-8'))
    except Exception:
        continue
    rows[m.group(1)][m.group(2)] = d
if not rows:
    print("  결과 파일이 없습니다")
else:
    print(f"  {'풀 크기':<10} {'워밍업':>8} {'qps':>10} {'p95':>10} {'p99':>10} {'최대':>10}")
    for sz in ('256M', '1G', '2G'):
        for wu in ('0', '30'):
            d = rows.get(sz, {}).get(wu)
            if not d:
                continue
            def g(k):
                v = d.get(k)
                return v if isinstance(v, (int, float)) else 0
            print(f"  {sz:<10} {wu+'초':>8} {g('qps'):>10.1f} {g('p95_ms'):>9.1f}ms "
                  f"{g('p99_ms'):>9.1f}ms {g('max_ms'):>9.1f}ms")
    print()
    print("  워밍업 0 과 30 의 차이가 기동 직후에 실제로 물리는 값입니다.")
    print("  풀이 작을수록 그 차이가 작아야 합니다. 데울 자리가 애초에 없기 때문입니다.")
PY
echo

} 2>&1 | tee "$OUT/extra-run.txt"
