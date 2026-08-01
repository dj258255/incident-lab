#!/usr/bin/env bash
# 밀리초당 행 수를 바꿔 가며 UUIDv7 카운터의 값어치를 잰다.
#
# 본 실험은 밀리초당 20행 한 점에서만 쟀다. 카운터가 필요한 이유는 "같은 밀리초 안에서는
# 순서가 없다"인데, 밀리초당 행 수가 1 근처로 내려가면 그 조건 자체가 사라진다.
# 어디서부터 카운터가 의미를 잃는지가 질문이다.
#
# 캐싱: 조건마다 새 컨테이너를 띄운다. 버퍼 풀도 페이지 캐시도 같은 상태에서 출발한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
C=a17-rate; N=${N:-150000}; RATES=${RATES:-"1 5 20 100 1000"}

gen(){ # $1=행수 $2=밀리초당 $3=v7ctr|v7plain  -> 표준출력으로 INSERT 문들
docker exec -i "$C" python3 -c '
import sys, os, struct
n, rate, kind = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
ms = 0; cnt = 0
rows = []
for i in range(n):
    if cnt >= rate:
        ms += 1; cnt = 0
    cnt += 1
    ts = 1767225600000 + ms          # 고정 시작점. 실행 시각에 안 흔들리게
    if kind == "v7ctr":
        # 같은 밀리초 안에서 증가하는 12비트 카운터
        rand_a = cnt & 0xFFF
        rest = os.urandom(8)
    else:
        rand_a = struct.unpack(">H", os.urandom(2))[0] & 0xFFF
        rest = os.urandom(8)
    b = ts.to_bytes(6,"big") + bytes([0x70 | (rand_a>>8), rand_a & 0xFF]) + rest
    rows.append("(0x%s,REPEAT(\x27x\x27,100))" % b.hex())
B=1000
for i in range(0,len(rows),B):
    print("INSERT INTO t VALUES " + ",".join(rows[i:i+B]) + ";")
' "$1" "$2" "$3" 2>/dev/null; }

echo "rows_per_ms,kind,data_mb,pages_read,seconds" > "$OUT/rate-curve.csv"
{
echo "# 밀리초당 행 수에 따른 UUIDv7 카운터의 값어치"
echo "# 각 조건 $N 행 · 버퍼 풀 128M · 조건마다 새 컨테이너"
echo "# 카운터 있는 v7 과 없는 v7 을 같은 유입 속도에서 맞댑니다."
echo
printf "  %10s %14s %12s %14s %10s\n" "밀리초당" "조건" "테이블(MB)" "디스크읽기(쪽)" "적재(초)"
for R in $RATES; do
  for KIND in v7ctr v7plain; do
    docker rm -f "$C" >/dev/null 2>&1
    docker run -d --name "$C" -e MYSQL_ROOT_PASSWORD=lab -e MYSQL_DATABASE=lab mysql:8.4.3 \
      --innodb-buffer-pool-size=128M >/dev/null
    M(){ docker exec -i "$C" mysql -uroot -plab -N -B lab -e "$1" 2>/dev/null; }
    for _ in $(seq 1 90); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
    M "CREATE TABLE t(id BINARY(16) PRIMARY KEY, pad CHAR(100)) ENGINE=InnoDB;" >/dev/null
    B0=$(M "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads'")
    t0=$(date +%s%N)
    gen "$N" "$R" "$KIND" | docker exec -i "$C" mysql -uroot -plab lab >/dev/null 2>&1
    t1=$(date +%s%N)
    G=$(M "SELECT COUNT(*) FROM t")
    if [ "${G:-0}" -ne "$N" ]; then
      printf "  %10s %14s  적재 %s행(기대 %s). 이 줄은 못 씁니다\n" "$R" "$KIND" "${G:-0}" "$N"
      docker rm -f "$C" >/dev/null 2>&1; continue
    fi
    M "ANALYZE TABLE t;" >/dev/null
    MB=$(M "SELECT ROUND(DATA_LENGTH/1048576,1) FROM information_schema.tables WHERE table_schema='lab' AND table_name='t'")
    B1=$(M "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads'")
    SEC=$(python3 -c "print(f'{($t1-$t0)/1e9:.1f}')")
    printf "  %10s %14s %12s %14s %10s\n" "$R" \
      "$([ $KIND = v7ctr ] && echo 'v7+카운터' || echo 'v7 카운터없음')" "$MB" "$((B1-B0))" "$SEC"
    echo "$R,$KIND,$MB,$((B1-B0)),$SEC" >> "$OUT/rate-curve.csv"
    docker rm -f "$C" >/dev/null 2>&1
  done
done
echo
python3 - "$OUT/rate-curve.csv" <<'ST'
import csv,sys
r=list(csv.DictReader(open(sys.argv[1],encoding='utf-8')))
by={}
for x in r: by.setdefault(int(x['rows_per_ms']),{})[x['kind']]=x
print("  밀리초당   카운터 이득(테이블)   카운터 이득(디스크읽기)")
for k in sorted(by):
    a,b=by[k].get('v7ctr'),by[k].get('v7plain')
    if not(a and b): continue
    dm=float(b['data_mb'])-float(a['data_mb'])
    dp=int(b['pages_read'])-int(a['pages_read'])
    print(f"  {k:>8}   {dm:+8.1f}MB            {dp:+8}쪽")
print()
print("  이득이 0 에 붙는 구간에서는 카운터를 넣을 이유가 없습니다.")
print("  같은 밀리초에 여러 행이 안 들어오면 카운터가 정할 순서 자체가 없기 때문입니다.")
ST
} 2>&1 | tee "$OUT/exp3-rate-curve.txt"
