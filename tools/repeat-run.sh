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
  # **세션 디렉터리에서 실행한다.** 저장소 루트에서 돌리면 docker compose 가
  # 설정 파일을 못 찾아 "no configuration file provided"로 죽는다. MDL 세션이 그랬다.
  ( cd "$SESSION" && env "$@" "$OLDPWD/$SCRIPT" ) > "$REP/run$r.log" 2>&1
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
# **회차마다 파일이 그대로면 그 스크립트는 이 파일을 다시 쓰지 않은 것이다.**
# 그것을 "폭 0.0%"로 적으면 아주 안정적인 측정처럼 보인다. 실제로는 측정이 없었다.
# Uber 세션에서 exp2-waldump 를 3회 돌렸을 때 타이밍이 소수점 셋째 자리까지
# 같게 나왔고, 알고 보니 그 스크립트가 measure.csv 를 안 건드렸다.
import hashlib
def h(f):
    try: return hashlib.sha256(f.read_bytes()).hexdigest()
    except Exception: return None
allnames = sorted({p.name for r in alive for p in r.iterdir() if p.is_file() and not p.name.startswith('.')})
stale = []
for name in allnames:
    hs = [h(r/name) for r in alive if (r/name).exists()]
    if len(hs) >= 2 and len(set(hs)) == 1: stale.append(name)
if stale:
    print("\n## 회차마다 내용이 같은 파일")
    for n in stale: print(f"  {n}")
    print("  이 파일들은 스크립트가 다시 쓰지 않았습니다. 반복해도 새로 잰 것이 없습니다.")
    print("  **여기에 '폭 0%'가 나오면 안정적인 것이 아니라 측정이 없었던 것입니다.**")

csvs = sorted({p.name for r in alive for p in r.glob("*.csv")})
csvs = [c for c in csvs if c not in stale]
fresh = [t for t in allnames if t not in stale and t.rsplit('.',1)[-1] in ('csv','txt','json')]
if not fresh:
    print("\n  비교할 새 결과가 없습니다. 이 스크립트는 반복 대상이 아닙니다.")
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
txts = [t for t in sorted({p.name for r in alive for p in r.glob("*.txt")}) if t not in stale]
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

# JSON 으로 결과를 남기는 세션도 있다. MDL 세션이 그렇고, csv 와 txt 만 보던
# 러너는 "비교할 새 결과가 없습니다"로 끝났다. 스크립트는 실제로 돌았는데도.
import json
def flat(o, pre=""):
    out={}
    if isinstance(o, dict):
        for k,v in o.items(): out.update(flat(v, f"{pre}.{k}" if pre else str(k)))
    elif isinstance(o, list):
        for i,v in enumerate(o[:20]): out.update(flat(v, f"{pre}[{i}]"))
    elif isinstance(o,(int,float)) and not isinstance(o,bool):
        out[pre]=float(o)
    return out
jsons = [j for j in sorted({p.name for r in alive for p in r.glob("*.json")}) if j not in stale]
for name in jsons:
    ds=[]
    for r in alive:
        f=r/name
        if not f.exists(): continue
        try: ds.append(flat(json.loads(f.read_text(encoding='utf-8'))))
        except Exception: pass
    if len(ds) < 2: continue
    keys=[k for k in ds[0] if all(k in d for d in ds)]
    rows=[]
    for k in keys:
        vals=[d[k] for d in ds]
        med=st.median(vals); lo=min(vals); hi=max(vals)
        if med==0 or hi==lo: continue
        rows.append((k, med, lo, hi, (hi-lo)/abs(med)*100))
    if not rows: continue
    print(f"\n## {name}  (흔들리는 값 {len(rows)}개)")
    print(f"  {'키':<42}{'중앙':>12}{'최소':>12}{'최대':>12}{'폭/중앙':>9}")
    for k,med,lo,hi,sp in sorted(rows,key=lambda x:-x[4])[:10]:
        flag="  **폭 큼**" if sp>30 else ""
        print(f"  {k[:40]:<42}{med:>12.4g}{lo:>12.4g}{hi:>12.4g}{sp:>8.1f}%{flag}")

print()
print("  폭이 30%를 넘는 줄은 1회 값으로 소수점을 인용하면 안 됩니다.")
print("  두 조건의 차이가 각자의 폭보다 작으면 그 비교 자체가 성립하지 않습니다.")
PY
