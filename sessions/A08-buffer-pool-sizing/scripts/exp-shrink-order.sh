#!/usr/bin/env bash
# 쓰기 비율 스윕이 쓰기 비율이 아니라 실행 순서를 따라갔다. 그것을 확인한다.
#
# run-extra.sh 2절을 0.0 → 0.1 → 0.2 → 0.4 → 0.8 순으로 돌렸더니 안정까지 시간이
# 65.10 → 35.05 → 3.04 → 3.04 → 3.04 초로 나왔다. 더티 페이지는 0 → 1,365 → 1,874 →
# 2,101 → 3,118 로 늘어나는데 시간은 줄어든다. 방향이 반대다.
#
# 값이 실행 순서를 따라가면 그것은 쓰기 비율의 효과가 아니라 회차 위치의 효과다.
# 순서를 뒤집어 돌려 본다.
#   순서가 원인이면  → 뒤집어도 앞 두 회차가 느리다(이번엔 0.8, 0.4 가 느려진다)
#   쓰기가 원인이면  → 뒤집어도 0.0 이 느리고 0.8 이 빠르다
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
WARMUP=${WARMUP:-30}
ORDER=${ORDER:-"0.8 0.4 0.2 0.1 0.0"}
export ORDER

{
echo "# 쓰기 비율 스윕을 역순으로"
echo "# 순서 ${ORDER}, 각 1회. 정순 결과는 results/extra-run.txt 2절에 있습니다."
echo
echo "  정순(0.0→0.8)에서 안정까지가 65.10 / 35.05 / 3.04 / 3.04 / 3.04 초였습니다."
echo "  더티 페이지는 늘어나는데 시간은 줄어드는 방향이라 순서를 의심합니다."
echo

for wr in $ORDER; do
  BP_SIZE=2G docker compose down >/dev/null 2>&1 || true
  BP_SIZE=2G docker compose up -d --wait mysql >/dev/null 2>&1
  BP_SIZE=2G docker compose run --rm load python workload.py \
    --dist hot --warmup "$WARMUP" --duration 90 \
    --write-ratio "$wr" --action-at 30 \
    --action-sql "SET GLOBAL innodb_buffer_pool_size = 134217728" \
    --label "shrink-rev-${wr}" \
    --out "/results/extra-shrink-rev-${wr}.json" >/dev/null 2>&1
done

python3 - "$OUT" <<'STATS'
import json, os, sys
out = sys.argv[1]
print(f"  {'실행 순서':<10} {'쓰기 비율':<10} {'안정까지':>10} {'더티':>10} {'최종 풀':>9}")
order = os.environ.get("ORDER", "0.8 0.4 0.2 0.1 0.0").split()
rows = []
for pos, wr in enumerate(order, 1):
    f = os.path.join(out, f"extra-shrink-rev-{wr}.json")
    if not os.path.exists(f):
        print(f"  {pos:<10} {wr:<10} 파일 없음")
        continue
    d = json.load(open(f, encoding='utf-8'))
    a = d.get("action") or {}
    if a.get("error"):
        print(f"  {pos:<10} {wr:<10} 실행 실패: {a['error']}")
        continue
    if "settle_s" not in a:
        print(f"  {pos:<10} {wr:<10} 측정값 없음")
        continue
    rows.append((pos, float(wr), a["settle_s"], d.get("pages_dirty", 0)))
    print(f"  {pos:<10} {wr:<10} {a['settle_s']:>9.2f}초 {d.get('pages_dirty',0):>10,} "
          f"{a.get('final_pool_mb',0):>7}MB")
print()
if len(rows) >= 3:
    first_two = [r[2] for r in rows[:2]]
    rest = [r[2] for r in rows[2:]]
    print(f"  앞 두 회차 {[round(x,2) for x in first_two]}, 나머지 {[round(x,2) for x in rest]}")
    print()
    if max(rest) and min(first_two) / max(rest) > 2:
        print("  역순으로 돌려도 앞 두 회차가 느립니다. **원인은 쓰기 비율이 아니라 실행 순서입니다.**")
        print("  첫 회차는 컨테이너를 새로 띄운 직후라 페이지 캐시와 InnoDB 내부 구조가")
        print("  아직 안 데워져 있고, 그 상태에서 리사이즈가 겹칩니다.")
    else:
        print("  역순에서는 앞 두 회차가 안 느립니다. 순서 효과로 설명되지 않습니다.")
        print("  쓰기 비율 쪽을 다시 봐야 합니다.")
STATS
echo
echo "  각 조건 1회 실행입니다."
} 2>&1 | tee "$OUT/exp-shrink-order.txt"
