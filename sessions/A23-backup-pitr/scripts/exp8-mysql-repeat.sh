#!/usr/bin/env bash
# README 의 "못 한 것" 하나를 잡는다.
#
#   MySQL 쪽 세 구간은 여전히 1회 실행값입니다
#   "1절의 RTO 분해(백업 / 덤프 복원 / binlog 적용)가 각각 한 번씩 잰 값입니다."
#
# RTO 는 이 세 구간의 합이다. 어느 구간이 지배하는지로 개선할 곳이 정해지므로,
# 회차 폭이 구간 사이 차이보다 크면 그 판단이 안 선다. 세 구간을 REPEAT 회 반복한다.
#
# 1절과 달리 사고 서사는 빼고 시간만 잰다. 같은 데이터로 같은 일을 반복하는 것이
# 목적이고, 사고 재현은 1절이 이미 했다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT/dump"
REPEAT=${REPEAT:-5}
ROWS=${ROWS:-200000}
BINLOG_ROWS=${BINLOG_ROWS:-20000}

M(){ docker exec a23-mysql mysql -uroot -plab -N -B -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }
R(){ docker exec a23-restore mysql -uroot -plab -N -B -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }

# ping 만 보면 부족하다. initdb 가 도는 동안 임시 서버가 떠 있어 ping 은 통하는데
# 곧 재기동되면서 그 사이 질의가 Access denied 로 떨어진다. 실제로 그렇게 나서
# 헤더의 SELECT VERSION() 이 에러 문자열이 되고, 그 뒤 적재가 통째로 0행이 됐다.
# 실제 질의가 두 번 연속 통해야 준비된 것으로 본다.
wait_up(){
  local ok=0
  for _ in $(seq 1 120); do
    if [ "$(docker exec "$1" mysql -uroot -plab -N -B -e 'SELECT 1' 2>/dev/null | tr -d ' ')" = "1" ]; then
      ok=$((ok + 1))
      [ "$ok" -ge 2 ] && return 0
    else
      ok=0
    fi
    sleep 2
  done
  return 1
}
wait_up a23-mysql || { echo "중단: a23-mysql 이 준비되지 않았습니다" >&2; exit 2; }
wait_up a23-restore || { echo "중단: a23-restore 가 준비되지 않았습니다" >&2; exit 2; }

secs(){ python3 -c "print(f'{($2-$1)/1e9:.3f}')"; }

seed(){
  M "DROP DATABASE IF EXISTS rto; CREATE DATABASE rto" >/dev/null
  M "CREATE TABLE rto.sponsor (
       id BIGINT AUTO_INCREMENT PRIMARY KEY,
       live_id INT NOT NULL, user_id INT NOT NULL, amount INT NOT NULL,
       memo VARCHAR(120) NOT NULL, created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
       KEY idx_live (live_id), KEY idx_user (user_id)
     ) ENGINE=InnoDB" >/dev/null
  M "INSERT INTO rto.sponsor (live_id, user_id, amount, memo)
     SELECT n % 1000, n % 50000, n % 10000, CONCAT('m', MD5(n)) FROM (
       SELECT @r := @r + 1 AS n FROM information_schema.COLUMNS c1,
         information_schema.COLUMNS c2, information_schema.COLUMNS c3,
         (SELECT @r := 0) r LIMIT ${ROWS}
     ) t" >/dev/null 2>&1
  local n; n=$(M "SELECT COUNT(*) FROM rto.sponsor")
  case "${n:-}" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -ge "$ROWS" ] || { echo "중단: rto.sponsor 가 ${n}행입니다(기대 ${ROWS})" >&2; exit 3; }
  echo "  적재 ${n}행"
}

{
echo "# MySQL 세 구간을 반복해서"
echo "# MySQL $(M 'SELECT VERSION()')"
echo "# ${ROWS}행, binlog 구간 ${BINLOG_ROWS}행, 각 ${REPEAT}회 반복"
echo
seed
echo

: > "$OUT/mysql-rto-repeat.csv"
echo "run,phase,seconds,bytes,rows" >> "$OUT/mysql-rto-repeat.csv"

for run in $(seq 1 "$REPEAT"); do
  # ── 1) 백업 ──────────────────────────────────────────────────────────
  T0=$(date +%s%N)
  docker exec a23-mysql mysqldump -uroot -plab --single-transaction --source-data=2 \
    --databases rto > "$OUT/dump/rto-full.sql" 2>/dev/null
  T1=$(date +%s%N)
  DUMP_B=$(wc -c < "$OUT/dump/rto-full.sql" | tr -d ' ')
  BK=$(secs "$T0" "$T1")
  # 백업이 실제로 내용을 담았는지 본다. 빈 파일이면 그 뒤 복원이 0.01초로 끝난다.
  if [ "${DUMP_B:-0}" -lt 100000 ]; then
    echo "  run${run} 백업이 ${DUMP_B}바이트뿐입니다. 이 회차는 버립니다"
    continue
  fi
  echo "$run,backup,$BK,$DUMP_B," >> "$OUT/mysql-rto-repeat.csv"

  # ── 2) 덤프 복원 ─────────────────────────────────────────────────────
  # mysqldump 는 기본값(--set-gtid-purged=AUTO)에서 SET @@GLOBAL.GTID_PURGED 를 넣는다.
  # 대상에 GTID 가 이미 있으면 그 문장이 실패하고 복원 전체가 거기서 멈춘다.
  # 첫 회차는 깨끗해서 통과했고, 그 회차의 binlog 적용이 GTID 를 남기자 2회차부터
  # 복원 후 0행이 됐다. 회차마다 GTID 를 비운다.
  R "DROP DATABASE IF EXISTS rto" >/dev/null
  R "RESET BINARY LOGS AND GTIDS" >/dev/null 2>&1 || R "RESET MASTER" >/dev/null 2>&1 || true
  T2=$(date +%s%N)
  docker exec -i a23-restore mysql -uroot -plab < "$OUT/dump/rto-full.sql" 2>/dev/null
  T3=$(date +%s%N)
  RS=$(secs "$T2" "$T3")
  RN=$(R "SELECT COUNT(*) FROM rto.sponsor")
  case "${RN:-}" in ''|*[!0-9]*) RN=0 ;; esac
  if [ "$RN" -lt "$ROWS" ]; then
    echo "  run${run} 복원 후 ${RN}행(기대 ${ROWS}). 이 회차는 버립니다"
    continue
  fi
  echo "$run,restore,$RS,$DUMP_B,$RN" >> "$OUT/mysql-rto-repeat.csv"

  # ── 3) binlog 적용 ───────────────────────────────────────────────────
  # 백업 이후의 쓰기를 만들고, 그 구간만 뽑아 복구 인스턴스에 적용한다.
  # 좌표를 한 번에 읽는다. 두 번 나눠 읽으면 그 사이에 위치가 움직여 구간이 어긋난다.
  read -r BINFILE POS_BEFORE <<< "$(M "SHOW BINARY LOG STATUS" 2>/dev/null | head -1 | awk '{print $1, $2}')"
  if [ -z "${BINFILE:-}" ]; then
    read -r BINFILE POS_BEFORE <<< "$(M "SHOW MASTER STATUS" 2>/dev/null | head -1 | awk '{print $1, $2}')"
  fi

  M "INSERT INTO rto.sponsor (live_id, user_id, amount, memo)
     SELECT n % 1000, n % 50000, n % 10000, CONCAT('b', MD5(n)) FROM (
       SELECT @b := @b + 1 AS n FROM information_schema.COLUMNS c1,
         information_schema.COLUMNS c2, (SELECT @b := 0) b LIMIT ${BINLOG_ROWS}
     ) t" >/dev/null 2>&1
  read -r BINAFTER POS_AFTER <<< "$(M "SHOW BINARY LOG STATUS" 2>/dev/null | head -1 | awk '{print $1, $2}')"
  if [ -z "${POS_AFTER:-}" ]; then
    read -r BINAFTER POS_AFTER <<< "$(M "SHOW MASTER STATUS" 2>/dev/null | head -1 | awk '{print $1, $2}')"
  fi
  # 구간 도중에 binlog 파일이 넘어가면 한 파일만 잘라 내는 이 방식이 안 맞는다.
  if [ "${BINAFTER:-}" != "${BINFILE:-}" ]; then
    echo "  run${run} binlog 파일이 ${BINFILE} 에서 ${BINAFTER} 로 넘어갔습니다. 이 구간은 건너뜁니다"
    continue
  fi

  if [ -z "${BINFILE:-}" ] || [ -z "${POS_BEFORE:-}" ] || [ -z "${POS_AFTER:-}" ]; then
    echo "  run${run} binlog 좌표를 못 읽었습니다. 이 구간은 건너뜁니다"
    continue
  fi
  # mysql:8.4 이미지에는 mysqlbinlog 가 없다. 1절이 이미 알고 있던 사실인데 이 스크립트가
  # 그대로 불러서, "command not found" 가 2>&1 에 삼켜지고 "적용 0행" 으로만 남았다.
  # 1절과 같이 a23-tools 컨테이너에서 변환하고 그 SQL 을 복구 인스턴스에 먹인다.
  # results/dump 가 a23-tools 의 /dump 로 마운트돼 있다.
  docker exec a23-mysql bash -c "cat /var/lib/mysql/$BINFILE" > "$OUT/dump/rto-binlog" 2>/dev/null
  docker exec a23-tools bash -c \
    "mysqlbinlog --skip-gtids --start-position=$POS_BEFORE --stop-position=$POS_AFTER \
       /dump/rto-binlog > /dump/rto-recover.sql" 2>/dev/null
  SQL_B=$(wc -c < "$OUT/dump/rto-recover.sql" 2>/dev/null | tr -d ' ')
  if [ "${SQL_B:-0}" -lt 1000 ]; then
    echo "  run${run} binlog 변환 결과가 ${SQL_B:-0}바이트뿐입니다. 이 구간은 건너뜁니다"
    continue
  fi
  T4=$(date +%s%N)
  docker exec -i a23-restore mysql -uroot -plab < "$OUT/dump/rto-recover.sql" >/dev/null 2>&1
  T5=$(date +%s%N)
  BS=$(secs "$T4" "$T5")
  RN2=$(R "SELECT COUNT(*) FROM rto.sponsor")
  case "${RN2:-}" in ''|*[!0-9]*) RN2=0 ;; esac
  APPLIED=$(( RN2 - RN ))
  if [ "$APPLIED" -le 0 ]; then
    echo "  run${run} binlog 적용 후 늘어난 행이 ${APPLIED}건입니다. 이 구간은 버립니다"
  else
    echo "$run,binlog,$BS,,$APPLIED" >> "$OUT/mysql-rto-repeat.csv"
  fi
  printf "  run%-2s 백업 %7ss  복원 %7ss  binlog %7ss (적용 %s행)\n" \
    "$run" "$BK" "$RS" "$BS" "$APPLIED"
  # 다음 회차를 위해 원본을 처음 상태로 되돌린다.
  M "DELETE FROM rto.sponsor WHERE memo LIKE 'b%'" >/dev/null 2>&1
done

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
python3 - "$OUT/mysql-rto-repeat.csv" <<'STATS'
import csv, sys, collections, statistics
rows = collections.defaultdict(list)
for r in csv.DictReader(open(sys.argv[1], encoding='utf-8')):
    try:
        rows[r['phase']].append(float(r['seconds']))
    except ValueError:
        pass
LBL = {'backup': '백업(mysqldump)', 'restore': '덤프 복원', 'binlog': 'binlog 적용'}
if not rows:
    print("  유효한 회차가 없습니다"); raise SystemExit
print(f"  {'구간':<20} {'중앙':>9} {'최소':>9} {'최대':>9} {'폭':>9} {'회차':>5}")
med = {}
for k in ('backup', 'restore', 'binlog'):
    xs = rows.get(k, [])
    if not xs:
        print(f"  {LBL[k]:<20} 값 없음")
        continue
    med[k] = statistics.median(xs)
    print(f"  {LBL[k]:<20} {statistics.median(xs):>8.3f}s {min(xs):>8.3f}s "
          f"{max(xs):>8.3f}s {max(xs)-min(xs):>8.3f}s {len(xs):>5}")
if len(med) == 3:
    total = sum(med.values())
    print()
    print(f"  RTO 합 중앙 {total:.3f}초")
    for k in ('backup', 'restore', 'binlog'):
        print(f"    {LBL[k]:<20} {100*med[k]/total:>5.1f}%")
    print()
    print("  회차 폭이 구간 사이 차이보다 작아야 '어느 구간이 지배하는가' 를 말할 수 있습니다.")
    print("  백업은 RTO 에 안 들어갑니다. 사고 전에 이미 끝나 있기 때문입니다.")
    rec = med['restore'] + med['binlog']
    print(f"  실제 RTO 는 복원과 binlog 적용의 합 {rec:.3f}초이고,")
    print(f"  그중 binlog 적용이 {100*med['binlog']/rec:.1f}% 입니다.")
STATS
echo
echo "  각 구간 ${REPEAT}회 실행이고, 행 수 확인에 걸린 회차는 표에서 뺐습니다."
} 2>&1 | tee "$OUT/exp8-mysql-repeat.txt"
