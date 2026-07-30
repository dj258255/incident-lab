#!/usr/bin/env bash
# pt-online-schema-change 로 같은 전환을 하고 한 방 ALTER, 직접 구현한 expand-contract 와
# 나란히 놓는다.
#
# README 의 "못 한 것"에 적어 둔 항목이다. 실무에서는 이 도구가 expand-contract 를
# 자동화한다. 직접 구현해 단계별 비용을 보이는 쪽을 택했지만, 도구가 실제로 무엇을 하고
# 얼마나 걸리는지는 재지 않았다.
#
# 도구가 하는 일은 이렇다.
#   1) 새 스키마로 빈 테이블 _tbl_new 를 만든다
#   2) 원본에 트리거 셋(INSERT/UPDATE/DELETE)을 걸어 변경분을 새 테이블로 흘린다
#   3) 기존 행을 청크로 복사한다
#   4) RENAME 으로 자리를 바꾸고 트리거를 지운다
#
# 직접 구현한 expand-contract 와 다른 점은 트리거로 잔여분을 실시간으로 따라간다는 것이다.
# 그 대가가 무엇인지도 함께 본다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
M(){  docker exec a01-mysql mysql -uroot -plab spoon -N -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }
ROWS=${ROWS:-3000000}
NET=$(docker inspect a01-mysql -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')

for _ in $(seq 1 90); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(M 'SELECT 1')" = "1" ] || { echo "중단: a01-mysql 이 쿼리를 받지 못합니다" >&2; exit 2; }

# MySQL 8 기본 인증 플러그인 caching_sha2_password 는 암호화되지 않은 연결에서 인증을
# 거부한다. 처음에 mysql_native_password 로 전용 사용자를 만들려 했는데 MySQL 8.4 는
# 그 플러그인을 아예 제거했다("Plugin 'mysql_native_password' is not loaded").
# 남은 길은 TLS 를 켜는 것이고 pt-osc 에 --mysql_ssl 옵션이 있다.
# 이 두 단계가 도구를 처음 붙일 때 실제로 걸리는 자리라 기록에 남긴다.

seed(){
  M "DROP TABLE IF EXISTS $1" >/dev/null
  M "CREATE TABLE $1 (id INT AUTO_INCREMENT PRIMARY KEY, live_id INT, amount INT, memo VARCHAR(20)) ENGINE=InnoDB" >/dev/null
  M "SET SESSION cte_max_recursion_depth = $((ROWS + 10));
     INSERT INTO $1 (live_id, amount, memo)
     WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < $ROWS)
     SELECT n%1000+1, 1000, 'x' FROM s" >/dev/null
  M "ANALYZE TABLE $1" >/dev/null
}

# 쓰기 부하. 전환 중에 얼마나 통과하는지가 판정 기준이다.
start_writer(){ # $1=테이블
  docker exec -i a01-mysql bash -c 'cat > /tmp/w.sh' <<'EOS'
#!/bin/bash
TBL=$1; SECS=$2
end=$(( $(date +%s) + SECS ))
rm -f /tmp/w-stop
while [ $(date +%s) -lt $end ]; do
  [ -f /tmp/w-stop ] && break
  s=$(date +%s%N)
  if mysql -uroot -plab spoon -N -e "INSERT INTO $TBL (live_id, amount, memo) VALUES (1,1,'w')" >/dev/null 2>&1; then r=ok; else r=fail; fi
  e=$(date +%s%N)
  echo "$(( s/1000000 )),$(( (e-s)/1000000 )),$r"
  sleep 0.01
done
EOS
  docker exec a01-mysql chmod +x /tmp/w.sh
  n=$(docker exec a01-mysql bash -c "wc -l < /tmp/w.sh" | tr -d ' ')
  [ "${n:-0}" -ge 5 ] || { echo "중단: 부하 스크립트가 전달되지 않았습니다(줄 수 ${n:-0})" >&2; exit 3; }
  docker exec -d a01-mysql bash -c "/tmp/w.sh $1 600 > /tmp/w.csv 2>/dev/null"
  sleep 6
}

stop_writer(){ docker exec a01-mysql touch /tmp/w-stop; sleep 1; }

tally(){ # $1=시작 $2=끝 $3=라벨
  docker cp a01-mysql:/tmp/w.csv "$OUT/ptosc-$3.csv" >/dev/null 2>&1
  python3 - "$OUT/ptosc-$3.csv" "$1" "$2" "$3" <<'PY'
import sys,csv
path,a0,a1,label=sys.argv[1],float(sys.argv[2])*1000,float(sys.argv[3])*1000,sys.argv[4]
rows=[]
for r in csv.reader(open(path)):
    if len(r)<3: continue
    try: rows.append((int(r[0]),int(r[1]),r[2]))
    except: pass
if not rows: print(f"  [{label}] 부하 CSV 가 비었습니다"); raise SystemExit
win=[r for r in rows if a0<=r[0]<=a1]
ok=[r for r in win if r[2]=='ok']
dur=max((a1-a0)/1000,0.001)
base=[r for r in rows if a0-5000<=r[0]<a0 and r[2]=='ok']
lat=sorted(r[1] for r in win) or [0]
p95=lat[int(len(lat)*0.95)] if len(lat)>=20 else lat[-1]
print(f"  [{label}] {dur:.1f}초 동안 시작한 쓰기 {len(win)}건 중 성공 {len(ok)}건 = 초당 {len(ok)/dur:.1f}건")
print(f"  [{label}] 전환 직전 5초 기준선 = 초당 {len(base)/5:.1f}건")
print(f"  [{label}] 지연 중앙값 {lat[len(lat)//2]}ms, p95 {p95}ms, 최대 {lat[-1]}ms, 실패 {len(win)-len(ok)}건")
PY
}

{
echo "# pt-online-schema-change 대조"
echo "# MySQL $(M 'SELECT VERSION()'), $(docker run --rm percona/percona-toolkit pt-online-schema-change --version 2>&1 | head -1)"
echo "# 행 수 $ROWS. INT AUTO_INCREMENT 를 BIGINT 로 옮긴다."
echo

echo "## 1) 한 방 ALTER (COPY)"
seed sponsor_alter
start_writer sponsor_alter
A0=$(date +%s.%N)
docker exec a01-mysql mysql -uroot -plab spoon -e "ALTER TABLE sponsor_alter MODIFY id BIGINT AUTO_INCREMENT, ALGORITHM=COPY" >/dev/null 2>&1
A1=$(date +%s.%N)
stop_writer
printf "  소요 %.1f초\n" "$(echo "$A1-$A0" | bc)"
tally "$A0" "$A1" alter
echo

echo "## 2) pt-online-schema-change"
seed sponsor_pt
start_writer sponsor_pt
B0=$(date +%s.%N)
docker run --rm --network "$NET" percona/percona-toolkit pt-online-schema-change \
  --alter "MODIFY id BIGINT AUTO_INCREMENT" \
  --host a01-mysql --user root --password lab --mysql_ssl 1 \
  D=spoon,t=sponsor_pt --execute --no-check-alter --alter-foreign-keys-method=auto \
  --set-vars innodb_lock_wait_timeout=5 \
  2>&1 | grep -E "Creating|Altering|Copying|Copied|Swapping|Dropping|Successfully|Error|Cannot" | sed 's/^/    /'
B1=$(date +%s.%N)
stop_writer
printf "  소요 %.1f초\n" "$(echo "$B1-$B0" | bc)"
tally "$B0" "$B1" ptosc
echo

echo "## 3) 결과 검산"
for tb in sponsor_alter sponsor_pt; do
  echo "  $tb: 컬럼 $(M "SELECT COLUMN_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='$tb' AND COLUMN_NAME='id'"), 행 수 $(M "SELECT COUNT(*) FROM $tb")"
done
echo
echo "## 정리"
echo "  각 조건 1회 실행입니다."
} 2>&1 | tee "$OUT/exp5-pt-osc.txt"
