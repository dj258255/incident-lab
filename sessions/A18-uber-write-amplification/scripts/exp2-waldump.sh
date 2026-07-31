#!/usr/bin/env bash
# README 의 "못 한 것" 다섯 개를 한 번에 잡는다.
#
#   1) full-page image 를 분리하지 못했습니다
#      EXPLAIN 이 FPI 개수만 주고 바이트를 안 줘서 상한 추정까지만 했다.
#      pg_waldump --stats 는 리소스 매니저별로 레코드 바이트와 FPI 바이트를 갈라 준다.
#      Heap(힙 튜플), Btree(인덱스), XLOG(체크포인트 등)를 나눠 볼 수 있다.
#
#   2) autovacuum 을 끄지 않았습니다
#      pg_current_wal_lsn() 은 인스턴스 전역이라 앞 조건의 뒷정리가 뒤 조건에 섞인다.
#      측정 순서가 인덱스 0→10 이라 오염 방향이 결론 방향과 같았다.
#      이 실험은 autovacuum=off 로 띄운다.
#
#   3) 정상 상태 비교를 다시 설계해야 합니다
#      1차 실행에서 u10 을 인덱스 컬럼 갱신에 한 번 더 써서 갱신 이력이 u0 의 두 배가 됐다.
#      인덱스 컬럼 갱신에 별도 테이블 v10 을 둔다.
#
#   4) 호스트 사양을 기록하지 않았습니다
#      컨테이너 자원 한도도 없었다. 오버라이드로 한도를 걸고 사양을 남긴다.
#
#   5) wal_compression=off 조건에서만 성립합니다
#      켜면 FPI 가 압축되는데 이 실험에서 FPI 가 WAL 의 3분의 1에서 3분의 2다.
#      같은 조건을 압축 켠 채로 다시 재서 배수가 어떻게 달라지는지 본다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
ROWS=${ROWS:-500000}
PGBIN=/usr/lib/postgresql/17/bin

P(){ docker exec a18-pg psql -U postgres -d spoon -X -q -t -A -c "$1" 2>&1; }

start_pg(){ # $1 = wal_compression 값
  docker rm -f a18-pg >/dev/null 2>&1 || true
  docker run -d --name a18-pg \
    --cpus 4 --memory 4g \
    -e POSTGRES_PASSWORD=lab -e POSTGRES_DB=spoon \
    postgres:17.5 postgres \
      -c shared_buffers=1GB \
      -c wal_compression="$1" \
      -c autovacuum=off \
      -c max_wal_size=8GB \
      -c checkpoint_timeout=1h \
      -c wal_keep_size=4GB >/dev/null
  for _ in $(seq 1 90); do [ "$(P 'SELECT 1')" = "1" ] && break; sleep 2; done
  [ "$(P 'SELECT 1')" = "1" ] || { echo "중단: a18-pg 가 쿼리를 받지 못합니다" >&2; exit 2; }
  # 켠 값이 실제로 들어갔는지 확인한다. 안 들어간 채로 "압축 켠 조건"이라고 적으면
  # 두 조건이 같은 값을 내고 그것을 압축 효과 없음으로 잘못 읽는다.
  # on 은 서버가 pglz 로 정규화해 돌려준다(15부터 pglz·lz4·zstd 를 받으므로).
  # 그래서 문자열 일치로 보면 안 되고, 켜졌는지 꺼졌는지로 판정한다.
  local got; got=$(P "SELECT current_setting('wal_compression')")
  case "$1:$got" in
    off:off) ;;
    on:off) echo "중단: wal_compression 을 on 으로 줬는데 off 입니다" >&2; exit 3 ;;
    on:*)   ;;
    *) echo "중단: wal_compression 이 $1 인데 $got 입니다" >&2; exit 3 ;;
  esac
  echo "  wal_compression 적용값 = $got"
  [ "$(P "SELECT current_setting('autovacuum')")" = "off" ] || { echo "중단: autovacuum 이 안 꺼졌습니다" >&2; exit 3; }
}

load(){
  for spec in "t0:100:0" "t10:100:10" "u0:70:0" "u10:70:10" "v10:70:10"; do
    IFS=: read -r tbl ff nidx <<< "$spec"
    P "DROP TABLE IF EXISTS $tbl;
       CREATE TABLE $tbl (
         id BIGINT PRIMARY KEY, val INT NOT NULL,
         c1 INT, c2 INT, c3 INT, c4 INT, c5 INT, c6 INT, c7 INT, c8 INT, c9 INT, c10 INT,
         pad TEXT
       ) WITH (fillfactor = $ff);" >/dev/null
    P "INSERT INTO $tbl
       SELECT g, 0, g%97, g%89, g%83, g%79, g%73, g%71, g%67, g%61, g%59, g%53,
              repeat(md5(g::text), 3)
       FROM generate_series(1, $ROWS) g;" >/dev/null
    if [ "$nidx" -gt 0 ]; then
      for i in $(seq 1 "$nidx"); do P "CREATE INDEX ON $tbl (c$i);" >/dev/null; done
    fi
    P "VACUUM ANALYZE $tbl;" >/dev/null
  done
}

# pg_waldump --stats 출력을 리소스 매니저별 (레코드 바이트, FPI 바이트) 로 접는다.
# 출력 형식이 버전마다 달라 열 위치가 아니라 숫자 두 개를 뒤에서 세는 방식으로 읽는다.
waldump_split(){ # $1=lsn0 $2=lsn1
  docker exec a18-pg $PGBIN/pg_waldump -p /var/lib/postgresql/data/pg_wal \
      --start="$1" --end="$2" --stats 2>/dev/null \
    | python3 -c "
import re, sys
rows = []
for line in sys.stdin:
    # 형식: <이름> <N> (  x.xx) <rec> (  x.xx) <fpi> (  x.xx) <comb> (  x.xx)
    m = re.match(r'^(\S+)\s+(\d+)\s+\(\s*[\d.]+\)\s+(\d+)\s+\(\s*[\d.]+\)\s+'
                 r'(\d+)\s+\(\s*[\d.]+\)\s+(\d+)\s+\(\s*[\d.]+\)', line)
    if not m: continue
    name, cnt, rec, fpi, comb = m.group(1), *(int(m.group(i)) for i in (2,3,4,5))
    if name.lower().startswith('total'): continue
    if comb == 0: continue
    rows.append((name, cnt, rec, fpi, comb))
rows.sort(key=lambda r: -r[4])
for name, cnt, rec, fpi, comb in rows[:6]:
    print(f'{name}|{cnt}|{rec}|{fpi}|{comb}')
"
}

measure(){ # $1=라벨 $2=테이블 $3=SET절
  local label="$1" tbl="$2" setcl="$3"
  P "CHECKPOINT;" >/dev/null; sleep 1
  local lsn0 lsn1 wal t0 t1
  lsn0=$(P "SELECT pg_current_wal_lsn();")
  t0=$(date +%s%N)
  P "UPDATE $tbl SET $setcl;" >/dev/null
  t1=$(date +%s%N)
  lsn1=$(P "SELECT pg_current_wal_lsn();")
  wal=$(P "SELECT pg_wal_lsn_diff('$lsn1','$lsn0');")
  local hot; hot=$(P "SELECT ROUND(100.0*n_tup_hot_upd/NULLIF(n_tup_upd,0),1) FROM pg_stat_user_tables WHERE relname='$tbl';")
  printf "  %-26s WAL %6.1fMB  HOT %5s%%  %5.2f초\n" \
    "$label" "$(python3 -c "print($wal/1048576)")" "${hot:-0}" "$(python3 -c "print(($t1-$t0)/1e9)")"
  echo "    리소스 매니저별 분해 (레코드 바이트 / FPI 바이트)"
  waldump_split "$lsn0" "$lsn1" | while IFS='|' read -r name cnt rec fpi comb; do
    printf "      %-14s %8s건  레코드 %8.1fMB  FPI %8.1fMB  FPI 비중 %5.1f%%\n" \
      "$name" "$cnt" \
      "$(python3 -c "print($rec/1048576)")" "$(python3 -c "print($fpi/1048576)")" \
      "$(python3 -c "print(100*$fpi/$comb if $comb else 0)")"
  done
  echo "$COMP,$label,$tbl,$wal,${hot:-0}" >> "$OUT/waldump-summary.csv"
}

{
echo "# WAL 을 레코드와 FPI 로 가르고, autovacuum 을 끄고, 압축 대조까지"
echo "# 호스트: $(uname -srm), $(sysctl -n hw.ncpu 2>/dev/null || nproc)코어, \
$(python3 -c "print(f'{$(sysctl -n hw.memsize 2>/dev/null || echo 0)/1073741824:.0f}GB')" 2>/dev/null || echo '?')"
echo "# 컨테이너: --cpus 4 --memory 4g, autovacuum=off, ${ROWS}행"
echo "# 조건마다 1회 실행입니다."
: > "$OUT/waldump-summary.csv"
echo "wal_compression,label,table,wal_bytes,hot_pct" >> "$OUT/waldump-summary.csv"

for COMP in off on; do
  echo
  echo "## wal_compression = $COMP"
  start_pg "$COMP"
  echo "  적재 중..."
  load
  echo "  PostgreSQL $(P 'SHOW server_version')"
  measure "인덱스 0개(ff100)"        t0  "val = val + 1"
  measure "인덱스 10개(ff100)"       t10 "val = val + 1"
  measure "인덱스 0개(ff70)"         u0  "val = val + 1"
  measure "인덱스 10개(ff70)"        u10 "val = val + 1"
  # 인덱스 컬럼 갱신은 별도 테이블 v10 에서 한다. 1차 실행은 이것을 u10 에 해서
  # u10 의 갱신 이력이 u0 의 두 배가 됐고, 그 상태로 정상 상태 비교를 했다.
  measure "인덱스 컬럼 갱신(v10)"     v10 "c1 = c1 + 1"
  # 정상 상태. 이제 u10 과 u0 의 갱신 이력이 각각 1회로 같다.
  measure "2차 갱신 인덱스 10개"      u10 "val = val + 1"
  measure "2차 갱신 인덱스 0개"       u0  "val = val + 1"
done

echo
echo "## 압축이 배수를 얼마나 바꾸는가"
python3 - "$OUT/waldump-summary.csv" <<'PY'
import csv, sys, collections
d=collections.defaultdict(dict)
for r in csv.DictReader(open(sys.argv[1])):
    d[r['label']][r['wal_compression']] = int(r['wal_bytes'])
print(f"  {'조건':<24} {'압축 끔':>11} {'압축 켬':>11} {'줄어든 비율':>12}")
base_off = d.get('인덱스 0개(ff100)', {}).get('off')
base_on  = d.get('인덱스 0개(ff100)', {}).get('on')
for label, v in d.items():
    off, on = v.get('off'), v.get('on')
    if not off or not on: continue
    print(f"  {label:<24} {off/1048576:>10.1f}MB {on/1048576:>10.1f}MB {100*(1-on/off):>11.1f}%")
print()
print("  인덱스 0개 대비 배수")
print(f"  {'조건':<24} {'압축 끔':>11} {'압축 켬':>11}")
for label, v in d.items():
    off, on = v.get('off'), v.get('on')
    if not off or not on: continue
    print(f"  {label:<24} {off/base_off:>10.2f}배 {on/base_on:>10.2f}배")
PY
} 2>&1 | tee "$OUT/exp2-waldump.txt"
