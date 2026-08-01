#!/usr/bin/env bash
# 두 전환 방법을 반복해서 잰다.
# 본문은 COPY 12.8초와 expand-contract 119.4초를 각각 1회만 쟀다. 관측 범위가 없으면
# 소수점을 그대로 인용할 수 없다. 회차 폭이 두 방법의 차이보다 작은지가 질문이다.
# 캐싱: 회차마다 컨테이너를 새로 띄운다. 버퍼 풀도 페이지 캐시도 같은 상태에서 출발한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
ROUNDS=${ROUNDS:-5}; ROWS=${ROWS:-3000000}; C=a01-rep
echo "round,method,seconds" > "$OUT/altermethod-repeat.csv"
{
echo "# INT to BIGINT 전환 두 방법 ${ROUNDS}회 반복 · 각 회차 새 컨테이너"
echo
printf "  %6s %14s %18s\n" "회차" "한방 ALTER(초)" "expand-contract(초)"
for r in $(seq 1 "$ROUNDS"); do
  for m in copy ec; do
    docker rm -f "$C" >/dev/null 2>&1
    docker run -d --name "$C" -e MYSQL_ROOT_PASSWORD=lab -e MYSQL_DATABASE=lab mysql:8.4.3 >/dev/null
    M(){ docker exec -i "$C" mysql -uroot -plab -N -B lab -e "$1" 2>/dev/null; }
    for _ in $(seq 1 90); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
    M "CREATE TABLE e(id INT AUTO_INCREMENT PRIMARY KEY, body VARCHAR(80)) ENGINE=InnoDB;
       SET SESSION cte_max_recursion_depth=$((ROWS+10));
       INSERT INTO e(body) SELECT REPEAT('x',80) FROM (
         WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<$ROWS) SELECT n FROM s) q;" >/dev/null
    G=$(M "SELECT COUNT(*) FROM e")
    [ "${G:-0}" -ne "$ROWS" ] && { echo "  회차 $r $m: 적재 ${G:-0}행, 버립니다"; continue; }
    t0=$(date +%s%N)
    if [ "$m" = copy ]; then
      M "ALTER TABLE e MODIFY id BIGINT NOT NULL AUTO_INCREMENT, ALGORITHM=COPY;" >/dev/null
    else
      M "ALTER TABLE e ADD COLUMN id_new BIGINT NULL, ALGORITHM=INPLACE, LOCK=NONE;" >/dev/null
      M "UPDATE e SET id_new = id;" >/dev/null
      M "ALTER TABLE e MODIFY id_new BIGINT NOT NULL, ALGORITHM=INPLACE, LOCK=NONE;" >/dev/null
    fi
    t1=$(date +%s%N); S=$(python3 -c "print(f'{($t1-$t0)/1e9:.1f}')")
    echo "$r,$m,$S" >> "$OUT/altermethod-repeat.csv"
    [ "$m" = copy ] && CP="$S" || printf "  %6s %14s %18s\n" "$r" "$CP" "$S"
  done
done
docker rm -f "$C" >/dev/null 2>&1
echo
python3 - "$OUT/altermethod-repeat.csv" <<'ST'
import csv,sys,statistics as st
r=list(csv.DictReader(open(sys.argv[1],encoding='utf-8')))
if not r: print("  유효 회차 없음"); raise SystemExit
by={}
for x in r: by.setdefault(x['method'],[]).append(float(x['seconds']))
for k,ko in (('copy','한방 ALTER'),('ec','expand-contract')):
    v=by.get(k) or []
    if not v: continue
    print(f"  {ko:<18} 중앙 {st.median(v):7.1f}초  최소 {min(v):7.1f}  최대 {max(v):7.1f}  폭 {(max(v)-min(v)):.1f}초")
a,b=by.get('copy') or [],by.get('ec') or []
if a and b:
    gap=abs(st.median(a)-st.median(b)); w=max(max(a)-min(a),max(b)-min(b))
    print(f"\n  두 방법 중앙값 차이 {gap:.1f}초, 회차 폭 최대 {w:.1f}초")
    print("  차이가 폭보다 " + ("큽니다. 비교를 인용할 수 있습니다." if gap>w else "**작습니다. 두 방법의 차이를 말할 수 없습니다.**"))
ST
} 2>&1 | tee "$OUT/exp7-repeat.txt"
