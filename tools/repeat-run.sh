#!/usr/bin/env bash
# 실험 스크립트를 N회 돌리고 회차별 결과를 보존한 뒤 편차를 정리한다.
#
# 이 랩의 여러 절이 "조건마다 1회 실행"으로 남아 있었다. 1회 값은 그 자체로 틀린 것은
# 아니지만 **회차 폭을 모르면 소수점을 인용할 수 없다.** 두 조건의 차이가 회차 폭보다
# 작으면 그 비교는 성립하지 않는데, 1회만 재면 그 판단 자체가 불가능하다.
#
# 스크립트마다 반복 손잡이를 새로 다는 대신, 스크립트를 통째로 N회 돌리고
# 회차마다 results 를 스냅숏으로 떠 둔 뒤 수치 열의 폭을 계산한다.
#
#   tools/repeat-run.sh <세션디렉터리> <스크립트경로> <횟수> [환경변수...]
#
# 결과: <세션>/results/repeat/<스크립트이름>/run<N>/  에 회차별 원본
#       <세션>/results/repeat/<스크립트이름>/SUMMARY.txt 에 열별 폭
set -uo pipefail
SESSION="$1"; SCRIPT="$2"; N="${3:-3}"; shift 3 || true
NAME=$(basename "$SCRIPT" .sh)
BASE="$SESSION/results"; REP="$BASE/repeat/$NAME"
rm -rf "$REP"; mkdir -p "$REP"

echo "# $NAME 를 ${N}회 반복합니다"
for r in $(seq 1 "$N"); do
  echo "  회차 $r ..."
  env "$@" "$SCRIPT" > "$REP/run$r.log" 2>&1
  RC=$?
  mkdir -p "$REP/run$r"
  # results 바로 아래의 파일만 뜬다(repeat 디렉터리 자신은 뺀다)
  find "$BASE" -maxdepth 1 -type f -exec cp {} "$REP/run$r/" \; 2>/dev/null
  echo "$RC" > "$REP/run$r/.exit"
done

python3 - "$REP" "$N" <<'PY' | tee "$REP/SUMMARY.txt"
import sys, csv, pathlib, statistics as st
rep, n = pathlib.Path(sys.argv[1]), int(sys.argv[2])
runs = [rep/f"run{i}" for i in range(1, n+1)]
alive = [r for r in runs if (r/".exit").exists() and (r/".exit").read_text().strip()=="0"]
print(f"# 반복 요약 ({len(alive)}/{n} 회차 정상 종료)")
if len(alive) < 2:
    print("  비교할 회차가 모자랍니다."); raise SystemExit
csvs = sorted({p.name for r in alive for p in r.glob("*.csv")})
for name in csvs:
    tables = []
    for r in alive:
        f = r/name
        if not f.exists(): continue
        try: tables.append(list(csv.DictReader(f.open(encoding='utf-8'))))
        except Exception: pass
    if len(tables) < 2: continue
    lens = {len(t) for t in tables}
    print(f"\n## {name}  (회차마다 {sorted(lens)} 행)")
    if len(lens) > 1:
        print("  회차마다 행 수가 다릅니다. 조건이 일부 안 선 회차가 있다는 뜻입니다.")
    cols = [c for c in (tables[0][0].keys() if tables[0] else [])]
    key = cols[0] if cols else None
    numeric = []
    for c in cols[1:]:
        try:
            [float(row[c]) for t in tables for row in t if row.get(c) not in (None,'')]
            numeric.append(c)
        except Exception: pass
    if not numeric:
        print("  수치 열이 없습니다."); continue
    print(f"  {'조건':<26}{'열':<22}{'중앙':>11}{'최소':>11}{'최대':>11}{'폭/중앙':>9}")
    rows0 = tables[0]
    for i, base in enumerate(rows0):
        label = str(base.get(key,''))[:24]
        for c in numeric:
            vals=[]
            for t in tables:
                if i < len(t) and t[i].get(c) not in (None,''):
                    try: vals.append(float(t[i][c]))
                    except Exception: pass
            if len(vals) < 2: continue
            med = st.median(vals); lo=min(vals); hi=max(vals)
            spread = (hi-lo)/med*100 if med else 0
            flag = "  **폭 큼**" if spread > 30 else ""
            print(f"  {label:<26}{c:<22}{med:>11.4g}{lo:>11.4g}{hi:>11.4g}{spread:>8.1f}%{flag}")
# CSV 가 없는 세션도 있다. 결과가 .txt 뿐이면 위 비교가 통째로 비고, 그러면
# "3/3 정상 종료"만 찍혀서 반복을 한 것처럼 보인다. 실제로는 아무것도 안 비교했다.
# 텍스트 결과도 줄 단위로 맞대고 숫자만 다른 줄의 폭을 잰다.
import re
txts = sorted({p.name for r in alive for p in r.glob("*.txt")})
NUM = re.compile(r'-?\d+(?:\.\d+)?')
for name in txts:
    lines = []
    for r in alive:
        f = r/name
        if f.exists(): lines.append(f.read_text(encoding='utf-8', errors='replace').splitlines())
    if len(lines) < 2: continue
    n = min(len(x) for x in lines)
    varying = []
    for i in range(n):
        col = [x[i] for x in lines]
        if len(set(col)) == 1: continue
        skel = [NUM.sub('#', c) for c in col]
        if len(set(skel)) != 1: continue      # 숫자 말고 다른 게 다르면 비교 대상이 아니다
        nums = [[float(v) for v in NUM.findall(c)] for c in col]
        if not nums[0] or len({len(v) for v in nums}) != 1: continue
        for j in range(len(nums[0])):
            vals = [v[j] for v in nums]
            med = st.median(vals); lo=min(vals); hi=max(vals)
            if med == 0 or hi == lo: continue
            varying.append((col[0].strip()[:52], j+1, med, lo, hi, (hi-lo)/abs(med)*100))
    if not varying: continue
    print(f"\n## {name}  (숫자가 흔들리는 줄 {len(varying)}개)")
    print(f"  {'줄':<54}{'위치':>4}{'중앙':>11}{'최소':>11}{'최대':>11}{'폭/중앙':>9}")
    for lbl,j,med,lo,hi,sp in sorted(varying, key=lambda x:-x[5])[:12]:
        flag = "  **폭 큼**" if sp > 30 else ""
        print(f"  {lbl:<54}{j:>4}{med:>11.4g}{lo:>11.4g}{hi:>11.4g}{sp:>8.1f}%{flag}")

print()
print("  폭이 30%를 넘는 줄은 1회 값으로 소수점을 인용하면 안 됩니다.")
print("  두 조건의 차이가 각자의 폭보다 작으면 그 비교 자체가 성립하지 않습니다.")
PY
