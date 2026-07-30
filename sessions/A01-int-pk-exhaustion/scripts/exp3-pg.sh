#!/usr/bin/env bash
# PostgreSQL 대조. MySQL 로만 잰 것을 같은 조건에서 다시 잰다.
#
#   1) 고갈 지점의 에러가 무엇인가
#      MySQL AUTO_INCREMENT 는 상한에서 같은 값을 재발급해 중복키 1062 로 실패한다.
#      PostgreSQL 은 컬럼 선언 방식에 따라 벽이 두 군데다.
#
#   2) 한 방 ALTER 가 온라인인가
#      MySQL 은 ALGORITHM=INPLACE 를 에러 1846 으로 미리 거부한다.
#      PostgreSQL 은 사전 거부가 없다. 무슨 락을 잡는지로 확인한다.
#
#   3) expand-contract 는 PostgreSQL 에서도 같은 거래 조건인가
#
# 부하 CSV 는 밀리초 타임스탬프를 쓴다. 초 단위로는 2초짜리 사건을 담을 해상도가 안 되고,
# 그러면 창 밖의 쓰기가 섞여 "전환 중에도 통과했다"는 틀린 결론이 나온다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
Q(){  docker exec a01-pg psql -U postgres -d spoon -qAt -c "$1" 2>&1; }
QE(){ docker exec a01-pg psql -U postgres -d spoon -c "$1" 2>&1; }

for _ in $(seq 1 90); do [ "$(Q 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(Q 'SELECT 1')" = "1" ] || { echo "중단: a01-pg 가 쿼리를 받지 못합니다" >&2; exit 2; }

ROWS=${ROWS:-3000000}
PMSTART=$(Q "SELECT pg_postmaster_start_time()")

# 밀리초 타임스탬프로 기록하는 쓰기 부하를 컨테이너 안에 심는다.
install_writer() {
  docker exec -i a01-pg bash -c 'cat > /tmp/w.sh' <<'EOS'
#!/bin/bash
TBL=$1; SECS=$2
end=$(( $(date +%s) + SECS ))
while [ $(date +%s) -lt $end ]; do
  [ -f /tmp/w-stop ] && break
  s=$(date +%s%N)
  if psql -U postgres -d spoon -qAt -c "INSERT INTO $TBL (live_id, amount, memo) VALUES (1,1,'w')" >/dev/null 2>&1; then r=ok; else r=fail; fi
  e=$(date +%s%N)
  echo "$(( s/1000000 )),$(( (e-s)/1000000 )),$r"
  sleep 0.01
done
EOS
  docker exec a01-pg chmod +x /tmp/w.sh
}

# 대상 테이블의 락을 0.2초마다 훑는다.
install_watcher() {
  docker exec -i a01-pg bash -c 'cat > /tmp/lock.sh' <<'EOS'
#!/bin/bash
for i in $(seq 1 400); do
  [ -f /tmp/lock-stop ] && break
  psql -U postgres -d spoon -qAt -c "SELECT mode FROM pg_locks l JOIN pg_class c ON c.oid=l.relation WHERE c.relname='$1' AND l.granted"
  sleep 0.2
done
EOS
  docker exec a01-pg chmod +x /tmp/lock.sh
}

seed() {  # $1=테이블명
  Q "DROP TABLE IF EXISTS $1" >/dev/null
  Q "CREATE TABLE $1 (id serial PRIMARY KEY, live_id integer, amount integer, memo text)" >/dev/null
  Q "INSERT INTO $1 (live_id, amount, memo) SELECT (i%1000)+1, 1000, 'x' FROM generate_series(1,$ROWS) i" >/dev/null
  Q "VACUUM ANALYZE $1" >/dev/null
}

tally() {  # $1=csv $2=시작(초.나노) $3=끝 $4=라벨
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys,csv
path,a0,a1,label=sys.argv[1],float(sys.argv[2])*1000,float(sys.argv[3])*1000,sys.argv[4]
rows=[]
for r in csv.reader(open(path)):
    if len(r)<3: continue
    try: rows.append((int(r[0]),int(r[1]),r[2]))
    except: pass
if not rows:
    print(f"  [{label}] 부하 CSV 가 비었습니다"); raise SystemExit
win=[r for r in rows if a0<=r[0]<=a1]          # 구간 안에서 시작한 쓰기만
ok=[r for r in win if r[2]=='ok']
dur=max((a1-a0)/1000,0.001)
base=[r for r in rows if a0-5000<=r[0]<a0 and r[2]=='ok']
print(f"  [{label}] 소요 {dur:.1f}초, 그 안에 시작한 쓰기 {len(win)}건 중 성공 {len(ok)}건 = 초당 {len(ok)/dur:.1f}건")
print(f"  [{label}] 전환 직전 5초 기준선 = 초당 {len(base)/5:.1f}건")
if win:
    lat=sorted(r[1] for r in win)
    if len(lat)>=20:
        print(f"  [{label}] 지연 중앙값 {lat[len(lat)//2]}ms, p95 {lat[int(len(lat)*0.95)]}ms, 최대 {lat[-1]}ms")
    else:
        print(f"  [{label}] 지연 중앙값 {lat[len(lat)//2]}ms, 최대 {lat[-1]}ms (표본 {len(lat)}건이라 p95 없음)")
print(f"  [{label}] 실패 {sum(1 for r in win if r[2]!='ok')}건")
PY
}

guard_alive() {  # 서버가 도중에 죽었는지 본다. 죽었으면 그 구간 수치는 못 쓴다.
  local now; now=$(Q "SELECT pg_postmaster_start_time()")
  if [ "$now" != "$PMSTART" ]; then
    echo "  경고: 측정 중 postgres 가 재기동됐습니다($PMSTART -> $now). 이 구간 수치는 버려야 합니다."
    return 1
  fi
  local rec; rec=$(Q "SELECT pg_is_in_recovery()")
  [ "$rec" = "f" ] || { echo "  경고: 서버가 복구 모드입니다"; return 1; }
  return 0
}

install_writer; install_watcher
for f in /tmp/w.sh /tmp/lock.sh; do
  n=$(docker exec a01-pg bash -c "wc -l < $f" 2>/dev/null | tr -d ' ')
  [ "${n:-0}" -ge 5 ] || { echo "중단: $f 가 컨테이너에 전달되지 않았습니다(줄 수 ${n:-0})" >&2; exit 2; }
done

{
echo "# PostgreSQL 대조. $(Q 'SELECT version()' | cut -c1-45)"
echo "# 행 수 = $ROWS (MySQL 쪽과 같은 규모)"
echo

# ── 1) 고갈 지점 ─────────────────────────────────────────────────────────
echo "## 1) integer PK 가 고갈되는 지점은 선언 방식에 따라 다르다"
echo
echo "### 1-1. serial (시퀀스 MAXVALUE 가 먼저 막는다)"
Q "DROP TABLE IF EXISTS ex_serial" >/dev/null
Q "CREATE TABLE ex_serial (id serial PRIMARY KEY, memo text)" >/dev/null
Q "SELECT format('  시퀀스: data_type=%s  max_value=%s', data_type, maximum_value) FROM information_schema.sequences WHERE sequence_name='ex_serial_id_seq'"
Q "SELECT setval('ex_serial_id_seq', 2147483646)" >/dev/null
QE "INSERT INTO ex_serial (memo) VALUES ('마지막 한 자리')" | grep -E "INSERT|ERROR" | sed 's/^/    /'
echo "    현재 최대 id = $(Q 'SELECT max(id) FROM ex_serial')"
QE "INSERT INTO ex_serial (memo) VALUES ('상한을 넘긴다')" | grep -E "INSERT|ERROR" | sed 's/^/    /'
echo

echo "### 1-2. integer 컬럼 + bigint 시퀀스 (컬럼 캐스트가 막는다)"
Q "DROP TABLE IF EXISTS ex_bigseq" >/dev/null
Q "DROP SEQUENCE IF EXISTS ex_bigseq_s" >/dev/null
Q "CREATE SEQUENCE ex_bigseq_s AS bigint" >/dev/null
Q "CREATE TABLE ex_bigseq (id integer PRIMARY KEY DEFAULT nextval('ex_bigseq_s'), memo text)" >/dev/null
Q "SELECT setval('ex_bigseq_s', 2147483647)" >/dev/null
QE "INSERT INTO ex_bigseq (memo) VALUES ('시퀀스는 되는데 컬럼이 안 된다')" | grep -E "INSERT|ERROR" | sed 's/^/    /'
echo

echo "### 1-3. GENERATED BY DEFAULT AS IDENTITY"
Q "DROP TABLE IF EXISTS ex_ident" >/dev/null
Q "CREATE TABLE ex_ident (id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, memo text)" >/dev/null
Q "SELECT setval(pg_get_serial_sequence('ex_ident','id'), 2147483647)" >/dev/null
QE "INSERT INTO ex_ident (memo) VALUES ('상한을 넘긴다')" | grep -E "INSERT|ERROR" | sed 's/^/    /'
echo "    (1-1 과 같은 문구다. IDENTITY 도 뒤에 integer 시퀀스를 둔다)"
echo

# ── 2) 한 방 ALTER ───────────────────────────────────────────────────────
echo "## 2) 한 방 ALTER TYPE"
echo "  MySQL 은 같은 요청을 미리 거부한다(results/exp2.txt):"
echo "    ERROR 1846 (0A000): ALGORITHM=INPLACE is not supported."
echo "    Reason: Cannot change column type INPLACE. Try ALGORITHM=COPY."
echo "  PostgreSQL 에는 이 사전 거부가 없다. 잡는 락으로 확인한다."
echo
LOGSINCE=$(date -u +%Y-%m-%dT%H:%M:%S)
seed sponsor_a
echo "  테이블 크기 = $(Q "SELECT pg_size_pretty(pg_total_relation_size('sponsor_a'))")"
docker exec a01-pg rm -f /tmp/w-stop /tmp/lock-stop
docker exec -d a01-pg bash -c "/tmp/w.sh sponsor_a 120 > /tmp/wa.csv 2>/dev/null"
docker exec -d a01-pg bash -c "/tmp/lock.sh sponsor_a > /tmp/locka.txt 2>/dev/null"
sleep 6
A0=$(date +%s.%N)
QE "ALTER TABLE sponsor_a ALTER COLUMN id TYPE bigint" | grep -E "ALTER TABLE|ERROR" | sed 's/^/    /'
A1=$(date +%s.%N)
sleep 2; docker exec a01-pg touch /tmp/w-stop /tmp/lock-stop; sleep 1
docker cp a01-pg:/tmp/wa.csv "$OUT/pg-writer-a.csv" >/dev/null 2>&1
guard_alive && tally "$OUT/pg-writer-a.csv" "$A0" "$A1" "한 방 ALTER"
echo "  ALTER 가 쥔 락(관측된 것 전부): $(docker exec a01-pg bash -c "sort -u /tmp/locka.txt | grep -v '^$' | paste -sd, -")"
echo "  서버 로그의 락 대기:"
docker logs --since "$LOGSINCE" a01-pg 2>&1 | grep -E "still waiting|acquired .*Lock" | tail -2 | sed 's/^/    /'
echo

# ── 3) expand-contract ───────────────────────────────────────────────────
echo "## 3) expand-contract"
seed sponsor_b
docker exec a01-pg rm -f /tmp/w-stop /tmp/lock-stop
docker exec -d a01-pg bash -c "/tmp/w.sh sponsor_b 400 > /tmp/wb.csv 2>/dev/null"
sleep 6
B0=$(date +%s.%N)
S0=$(date +%s.%N)
Q "ALTER TABLE sponsor_b ADD COLUMN id_new bigint" >/dev/null
S1=$(date +%s.%N)
printf "  1. expand   ADD COLUMN id_new bigint : %.2f초\n" "$(echo "$S1-$S0" | bc)"
S0=$(date +%s.%N)
CH=0
# 워터마크. MySQL 쪽 스크립트와 같은 구조로 맞춘다.
# WHERE id_new IS NULL 로만 돌면 부하가 방금 넣은 몇 행씩을 계속 쫓아
# 수렴 조건이 없어진다(우연히 빈 순간을 만나야 끝난다). 실제로 앞선 실행에서
# 벌크 151회 뒤에 28~30행짜리 청크가 1400회 넘게 이어졌다.
WM=$(Q "SELECT max(id) FROM sponsor_b")
echo "     워터마크 id <= $WM (이 범위가 벌크, 그 뒤 들어온 행은 3단계에서 처리)"
# 청크별 갱신 행 수를 파일에 남긴다. 앞선 실행에서 grep -c 로 센 횟수가
# 테이블 크기와 맞지 않았는데(151회여야 하는데 1608), 원인을 못 짚어
# 계수 자체를 wc -l 로 바꾸고 원자료를 남기도록 고쳤다.
: > "$OUT/pg-backfill-chunks.txt"
while :; do
  N=$(Q "WITH c AS (SELECT id FROM sponsor_b WHERE id_new IS NULL AND id <= '"$WM"' ORDER BY id LIMIT 20000) UPDATE sponsor_b s SET id_new = s.id FROM c WHERE s.id = c.id RETURNING 1" | wc -l | tr -d " ")
  echo "$N" >> "$OUT/pg-backfill-chunks.txt"
  [ "${N:-0}" -eq 0 ] && break
  CH=$((CH+1))
done
S1=$(date +%s.%N)
SUM=$(awk '{s+=$1} END{print s}' "$OUT/pg-backfill-chunks.txt")
printf "  2. backfill 2만 행씩 %d회 청크 UPDATE : %.1f초 (갱신 합계 %s행)\n" "$CH" "$(echo "$S1-$S0" | bc)" "$SUM"
# 검산은 워터마크와 비교해야 한다. 테이블 총행 수는 백필 중 부하가 넣은 만큼 늘어나므로
# 그 값과 비교하면 항상 불일치로 찍힌다. 그 차이는 3단계가 처리한다.
echo "     검산: 워터마크 ${WM}, 청크 갱신 합계 ${SUM} $([ "$SUM" = "$WM" ] && echo 일치 || echo 불일치)"
S0=$(date +%s.%N)
LEFT=$(Q "SELECT count(*) FROM sponsor_b WHERE id_new IS NULL")
Q "UPDATE sponsor_b SET id_new = id WHERE id_new IS NULL" >/dev/null
S1=$(date +%s.%N)
printf "  3. 잔여    백필 중 들어온 %s건 마저 채움 : %.2f초\n" "$LEFT" "$(echo "$S1-$S0" | bc)"
B1=$(date +%s.%N)
sleep 2; docker exec a01-pg touch /tmp/w-stop; sleep 1
docker cp a01-pg:/tmp/wb.csv "$OUT/pg-writer-b.csv" >/dev/null 2>&1
guard_alive && tally "$OUT/pg-writer-b.csv" "$B0" "$B1" "expand-contract"
echo
echo "## 정리"
printf "  한 방 ALTER TYPE       %.1f초\n" "$(echo "$A1-$A0" | bc)"
printf "  expand-contract        %.1f초\n" "$(echo "$B1-$B0" | bc)"
echo "  MySQL 의 사전 거부       있음 (ERROR 1846)"
echo "  PostgreSQL 의 사전 거부   없음. ACCESS EXCLUSIVE 를 쥐고 그냥 다시 쓴다"
} 2>&1 | tee "$OUT/exp3-pg.txt"
