#!/usr/bin/env bash
# 아카이브 로그 모드 전환 시간을 반복해서 잰다.
#
# exp6 은 각 방향 1회였고 12초와 11초가 나왔다. 그런데 이 랩의 데이터가 1,500행이라
# 그 12초의 대부분이 기동 시간이다. 기동 시간은 회차마다 흔들리는 값이라, 한 번 재고
# "12초"라고 적으면 인용할 수 없는 수치가 된다.
#
# 끄고 켜기를 한 묶음으로 ROUNDS 회 돌린다. 회차 폭이 두 방향의 차이보다 크면
# "끄는 쪽이 더 오래 걸린다" 같은 말을 못 한다는 뜻이고, 그것도 결과다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
ROUNDS=${ROUNDS:-3}

SQL(){ docker exec -i a23-oracle bash -lc "sqlplus -S / as sysdba" <<EOF 2>&1
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200 TRIMSPOOL ON
$1
EOF
}
mode(){ SQL "SELECT log_mode FROM v\$database;" | tr -d ' \r\n'; }
opened(){ SQL "SELECT open_mode FROM v\$database;" | tr -d ' \r\n'; }

# exp6 과 같은 준비 확인. 질의가 답하는 것만으로는 부족하고 READ WRITE 까지 봐야 한다.
# 기동 중에는 SYSDBA 질의를 받으면서도 MOUNTED 일 수 있고, 그때 SHUTDOWN 을 던지면
# ORA-01154 가 난다.
ready(){
  SQL "SELECT 'PI'||'NG' FROM dual;" | grep -q "PING" || return 1
  SQL "SELECT open_mode FROM v\$database;" | grep -q "READ WRITE"
}
for _ in $(seq 1 200); do ready && break; sleep 5; done
ready || { echo "중단: a23-oracle 이 쿼리를 받지 못합니다" >&2; exit 2; }

# 한 방향을 재고 그 방향이 실제로 섰는지 확인한다. 안 섰으면 그 회차는 버린다.
# 시간만 재고 상태를 안 보면 ORA 에러가 나도 "12초"가 남는다.
switch(){  # $1 = ARCHIVELOG | NOARCHIVELOG
  local want="$1" t0 t1
  t0=$(date +%s%N)
  SQL "SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ${want};
ALTER DATABASE OPEN;" >/dev/null 2>&1
  t1=$(date +%s%N)
  SQL "ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;" >/dev/null 2>&1
  [ "$(mode)" = "$want" ] || return 1
  [ "$(opened)" = "READWRITE" ] || return 1
  echo "scale=1; ($t1 - $t0) / 1000000000" | bc
}

{
echo "# 아카이브 로그 모드 전환을 반복해서"
SQL "SELECT banner FROM v\$version WHERE ROWNUM=1;" | tr -s ' ' | sed 's/^/# /'
echo "# ${ROUNDS}회 반복. 한 회차는 끄고 켜기 한 묶음입니다."
echo "# 시작 상태 log_mode = $(mode), open_mode = $(opened)"
echo

: > "$OUT/oracle-archivelog-repeat.csv"
echo "run,direction,seconds" >> "$OUT/oracle-archivelog-repeat.csv"

printf "  %6s %14s %14s\n" "회차" "끄기(초)" "켜기(초)"
for r in $(seq 1 "$ROUNDS"); do
  OFF=$(switch NOARCHIVELOG) || { echo "  회차 ${r}: 끄기가 안 섰습니다. 버립니다"; continue; }
  ON=$(switch ARCHIVELOG)    || { echo "  회차 ${r}: 켜기가 안 섰습니다. 버립니다"; continue; }
  printf "  %6s %14s %14s\n" "$r" "$OFF" "$ON"
  echo "$r,off,$OFF" >> "$OUT/oracle-archivelog-repeat.csv"
  echo "$r,on,$ON"   >> "$OUT/oracle-archivelog-repeat.csv"
done

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
python3 - "$OUT/oracle-archivelog-repeat.csv" <<'STATS'
import csv, sys, statistics as st
rows = list(csv.DictReader(open(sys.argv[1], encoding='utf-8')))
if not rows:
    print("  유효한 회차가 없습니다"); raise SystemExit
by = {}
for r in rows:
    by.setdefault(r['direction'], []).append(float(r['seconds']))
print(f"  {'방향':<8}{'중앙':>9}{'최소':>9}{'최대':>9}{'폭':>9}")
for k, ko in (('off', '끄기'), ('on', '켜기')):
    v = by.get(k) or []
    if not v: continue
    w = (max(v) - min(v)) / st.median(v) * 100
    print(f"  {ko:<8}{st.median(v):>8.1f}초{min(v):>8.1f}초{max(v):>8.1f}초{w:>8.1f}%")
print()
offs, ons = by.get('off') or [], by.get('on') or []
if offs and ons:
    gap = abs(st.median(offs) - st.median(ons))
    width = max(max(offs) - min(offs), max(ons) - min(ons))
    print(f"  두 방향의 중앙값 차이 {gap:.1f}초, 회차 폭 최대 {width:.1f}초")
    if gap > width:
        print("  차이가 폭보다 큽니다. 방향 사이의 비교를 인용할 수 있습니다.")
    else:
        print("  **차이가 회차 폭 안입니다. 어느 방향이 더 오래 걸린다고 말할 수 없습니다.**")
        print("  이 규모에서는 두 방향 모두 대부분이 기동 시간이고, 그 기동이 회차마다")
        print("  흔들리기 때문입니다. 갈리는 것은 길이가 아니라 단계 수입니다.")
STATS
} 2>&1 | tee "$OUT/exp9-oracle-archivelog-repeat.txt"
