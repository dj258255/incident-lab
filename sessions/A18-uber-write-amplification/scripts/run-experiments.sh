#!/usr/bin/env bash
# Uber 주장의 경계선을 긋는 실험.
#
#   변형 축 1: 세컨더리 인덱스 수 (0 / 3 / 6 / 10)
#   변형 축 2: fillfactor (100 = 페이지가 꽉 참, 70 = HOT용 여유 공간)
#   변형 축 3: 갱신 컬럼 (비인덱스 val / 인덱스 걸린 c1)
#
# 각 측정: CHECKPOINT로 조건을 맞춘 뒤 50만 행 전체를 UPDATE 한 문장으로 갱신하고
# WAL 증가량(pg_wal_lsn_diff), HOT 비율(pg_stat_user_tables), 소요 시간을 기록한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"
mkdir -p "$OUT"
P() { docker exec a18-pg psql -U postgres -d spoon -X -q -t -A -c "$1"; }
PT() { docker exec a18-pg psql -U postgres -d spoon -X -c "$1"; }

ROWS=500000

echo "== 0. 적재 =="
for spec in "t0:100:0" "t3:100:3" "t6:100:6" "t10:100:10" "u0:70:0" "u10:70:10"; do
  IFS=: read -r tbl ff nidx <<< "$spec"
  P "DROP TABLE IF EXISTS $tbl;
     CREATE TABLE $tbl (
       id BIGINT PRIMARY KEY,
       val INT NOT NULL,
       c1 INT, c2 INT, c3 INT, c4 INT, c5 INT, c6 INT, c7 INT, c8 INT, c9 INT, c10 INT,
       pad TEXT
     ) WITH (fillfactor = $ff);"
  P "INSERT INTO $tbl
     SELECT g, 0, g%97, g%89, g%83, g%79, g%73, g%71, g%67, g%61, g%59, g%53,
            repeat(md5(g::text), 3)
     FROM generate_series(1, $ROWS) g;"
  # macOS의 seq는 seq 1 0 이 1,0 을 역순으로 내놓는다. 0개일 때는 아예 돌지 않게 막는다.
  if [ "$nidx" -gt 0 ]; then
    for i in $(seq 1 "$nidx"); do
      P "CREATE INDEX ON $tbl (c$i);"
    done
  fi
  P "VACUUM ANALYZE $tbl;"
  echo "  $tbl 적재 완료 (fillfactor=$ff, 인덱스 ${nidx}개)"
done
PT "SELECT relname, pg_size_pretty(pg_total_relation_size(relid)) AS total
    FROM pg_stat_user_tables ORDER BY relname;" | tee "$OUT/00-sizes.txt"

measure() {  # measure <라벨> <테이블> <SET절>
  local label="$1" tbl="$2" setcl="$3"
  P "CHECKPOINT;" >/dev/null
  sleep 1
  local s0 s1 lsn0 lsn1 t0 t1
  read -r s0 <<< "$(P "SELECT n_tup_upd||' '||n_tup_hot_upd||' '||n_tup_newpage_upd FROM pg_stat_user_tables WHERE relname='$tbl';")"
  lsn0=$(P "SELECT pg_current_wal_lsn();")
  t0=$(date +%s.%N)
  P "UPDATE $tbl SET $setcl;" >/dev/null
  t1=$(date +%s.%N)
  lsn1=$(P "SELECT pg_current_wal_lsn();")
  sleep 1   # 통계 수집기 반영 대기
  read -r s1 <<< "$(P "SELECT n_tup_upd||' '||n_tup_hot_upd||' '||n_tup_newpage_upd FROM pg_stat_user_tables WHERE relname='$tbl';")"
  local wal
  wal=$(P "SELECT pg_wal_lsn_diff('$lsn1','$lsn0');")
  echo "$label,$tbl,$wal,$(echo "$t1 - $t0" | bc),$s0,$s1" | tr ' ' ',' >> "$OUT/measure.csv"
  echo "  $label: WAL $(( wal / 1024 / 1024 ))MB, $(echo "$t1 - $t0" | bc)초"
}

echo "== 1. 본 측정 =="
echo "label,table,wal_bytes,elapsed_s,upd0,hot0,newpage0,upd1,hot1,newpage1" > "$OUT/measure.csv"

# 축 1+2: 비인덱스 컬럼 갱신. ff100은 페이지가 꽉 차 HOT이 거의 불가능하고, ff70은 가능하다.
measure ff100-idx0  t0  "val = val + 1"
measure ff100-idx3  t3  "val = val + 1"
measure ff100-idx6  t6  "val = val + 1"
measure ff100-idx10 t10 "val = val + 1"
measure ff70-idx0   u0  "val = val + 1"
measure ff70-idx10  u10 "val = val + 1"

# 축 3: 인덱스가 걸린 컬럼을 갱신하면 HOT이 원천 불가능하다. fillfactor와 무관하게.
measure ff70-idx10-indexedcol u10 "c1 = c1 + 1"

echo "== 2. 쿼리 단위 증거: EXPLAIN (ANALYZE, WAL) =="
{
  echo '--- 인덱스 10개 테이블(ff100), 비인덱스 컬럼 1만 행 갱신'
  PT "EXPLAIN (ANALYZE, WAL, COSTS OFF) UPDATE t10 SET val = val + 1 WHERE id <= 10000;"
  echo '--- 인덱스 0개 테이블(ff100), 같은 갱신'
  PT "EXPLAIN (ANALYZE, WAL, COSTS OFF) UPDATE t0 SET val = val + 1 WHERE id <= 10000;"
} | tee "$OUT/02-explain-wal.txt"

echo "실험 종료"
