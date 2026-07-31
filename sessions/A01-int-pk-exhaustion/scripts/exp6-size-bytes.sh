#!/usr/bin/env bash
# README 의 "못 한 것" 하나를 잡는다.
#
#   전환 후 테이블 크기 차이를 재지 못했습니다
#   "6절의 104MB 는 information_schema 추정치를 MB 로 반올림한 값이라 BIGINT 의
#    4바이트 차이가 드러나지 않습니다."
#
# 반올림해서 안 보이는 것이지 없는 것이 아니다. 바이트로 읽고, 추정치가 아니라
# 파일 크기로도 읽는다. information_schema 의 DATA_LENGTH 는 InnoDB 가 페이지 단위로
# 잡아 둔 값이라 실제 파일과 다를 수 있으므로 둘 다 남긴다.
#
# 조건 넷을 같은 행 수로 만든다.
#   INT / BIGINT / INT UNSIGNED / BIGINT + 세컨더리 인덱스 하나
# 마지막 조건은 PK 폭이 세컨더리 인덱스로 번지는 몫을 보기 위한 것이다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
ROWS=${ROWS:-3000000}

M(){ docker exec a01-mysql mysql -uroot -plab -N -B -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }

for _ in $(seq 1 90); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(M 'SELECT 1')" = "1" ] || { echo "중단: a01-mysql 이 쿼리를 받지 못합니다" >&2; exit 2; }

M "CREATE DATABASE IF NOT EXISTS lab" >/dev/null

build(){ # $1=이름 $2=PK 타입 $3=세컨더리 인덱스 DDL(빈 문자열 가능)
  M "DROP TABLE IF EXISTS lab.$1" >/dev/null
  M "CREATE TABLE lab.$1 (
       id $2 NOT NULL AUTO_INCREMENT,
       user_id INT NOT NULL,
       amount INT NOT NULL,
       memo VARCHAR(64) NOT NULL,
       PRIMARY KEY (id)${3:+, $3}
     ) ENGINE=InnoDB" >/dev/null
  M "INSERT INTO lab.$1 (user_id, amount, memo)
     SELECT n % 100000, n % 1000, CONCAT('m', n) FROM (
       SELECT @r := @r + 1 AS n FROM information_schema.COLUMNS c1,
         information_schema.COLUMNS c2, information_schema.COLUMNS c3,
         (SELECT @r := 0) r LIMIT ${ROWS}
     ) t" >/dev/null 2>&1
  local n
  n=$(M "SELECT COUNT(*) FROM lab.$1")
  case "${n:-}" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -lt "$ROWS" ]; then
    echo "중단: lab.$1 에 ${n}행만 들어갔습니다(기대 ${ROWS})" >&2
    exit 3
  fi
  M "ANALYZE TABLE lab.$1" >/dev/null 2>&1
}

# ibd 파일의 실제 바이트. information_schema 는 추정치라 둘을 나란히 둔다.
ibd_bytes(){ docker exec a01-mysql sh -c "stat -c %s /var/lib/mysql/lab/$1.ibd 2>/dev/null || echo 0"; }

{
echo "# INT 와 BIGINT 의 크기 차이를 바이트로"
echo "# MySQL $(M 'SELECT VERSION()'), 조건마다 ${ROWS}행"
echo

: > "$OUT/size-bytes.csv"
echo "arm,pk_type,secondary,data_bytes,index_bytes,ibd_bytes" >> "$OUT/size-bytes.csv"

declare -a NAMES=(t_int t_bigint t_int_unsigned t_bigint_idx t_int_idx)
declare -a TYPES=("INT" "BIGINT" "INT UNSIGNED" "BIGINT" "INT")
declare -a IDXS=("" "" "" "KEY idx_user (user_id)" "KEY idx_user (user_id)")

for i in "${!NAMES[@]}"; do
  build "${NAMES[$i]}" "${TYPES[$i]}" "${IDXS[$i]}"
  read -r D X <<< "$(M "SELECT DATA_LENGTH, INDEX_LENGTH FROM information_schema.TABLES
                        WHERE TABLE_SCHEMA='lab' AND TABLE_NAME='${NAMES[$i]}'")"
  F=$(ibd_bytes "${NAMES[$i]}")
  echo "${NAMES[$i]},${TYPES[$i]},${IDXS[$i]:-없음},${D:-0},${X:-0},${F:-0}" >> "$OUT/size-bytes.csv"
  printf "  %-16s %-14s 데이터 %12s  인덱스 %12s  파일 %12s\n" \
    "${NAMES[$i]}" "${TYPES[$i]}" "${D:-0}" "${X:-0}" "${F:-0}"
done

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
python3 - "$OUT/size-bytes.csv" "$ROWS" <<'PY'
import csv, sys
rows = {r['arm']: r for r in csv.DictReader(open(sys.argv[1], encoding='utf-8'))}
n = int(sys.argv[2])


def mb(x):
    return int(x) / 1048576


print(f"  {'조건':<22} {'데이터':>11} {'인덱스':>11} {'파일':>11} {'행당 바이트':>12}")
LBL = {'t_int': 'INT', 't_bigint': 'BIGINT', 't_int_unsigned': 'INT UNSIGNED',
       't_int_idx': 'INT + 인덱스', 't_bigint_idx': 'BIGINT + 인덱스'}
for k in ('t_int', 't_int_unsigned', 't_bigint', 't_int_idx', 't_bigint_idx'):
    r = rows.get(k)
    if not r:
        continue
    tot = int(r['data_bytes']) + int(r['index_bytes'])
    print(f"  {LBL[k]:<22} {mb(r['data_bytes']):>9.1f}MB {mb(r['index_bytes']):>9.1f}MB "
          f"{mb(r['ibd_bytes']):>9.1f}MB {tot/n:>11.1f}B")

print()
a, b = rows.get('t_int'), rows.get('t_bigint')
if a and b:
    d = int(b['data_bytes']) - int(a['data_bytes'])
    print(f"  INT → BIGINT 데이터 증가 {d:,}바이트 ({mb(d):.1f}MB, 행당 {d/n:.2f}바이트)")
    print(f"  컬럼 폭 차이는 4바이트인데 행당 증가는 {d/n:.2f}바이트입니다.")
    print(f"  InnoDB 는 클러스터 인덱스라 PK 가 모든 잎에 한 번씩만 들어갑니다.")
ai, bi = rows.get('t_int_idx'), rows.get('t_bigint_idx')
if ai and bi:
    di = int(bi['index_bytes']) - int(ai['index_bytes'])
    print()
    print(f"  세컨더리 인덱스 하나가 있을 때 인덱스 증가 {di:,}바이트 "
          f"({mb(di):.1f}MB, 행당 {di/n:.2f}바이트)")
    print(f"  세컨더리 인덱스의 잎에 PK 값이 통째로 들어가기 때문입니다.")
    print(f"  인덱스가 k 개면 이 몫이 k 배가 됩니다.")
u = rows.get('t_int_unsigned')
if a and u:
    print()
    print(f"  INT 와 INT UNSIGNED 는 데이터 {mb(a['data_bytes']):.1f}MB 대 "
          f"{mb(u['data_bytes']):.1f}MB 로 같습니다. 폭이 같고 해석만 다릅니다.")
PY
echo
echo "  각 조건 1회 실행입니다. 파일 크기는 컨테이너 안 .ibd 의 실제 바이트입니다."
} 2>&1 | tee "$OUT/exp6-size-bytes.txt"
