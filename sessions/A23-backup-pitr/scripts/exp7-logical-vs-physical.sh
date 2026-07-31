#!/usr/bin/env bash
# README 의 "못 한 것" 두 개를 잡는다.
#
#   1) 논리·물리 백업의 복원 시간을 비교하지 않았습니다
#      "벤더 문서가 백업 속도만 명시하고 복원 속도 비교는 없어서, 직접 재면
#       독자적 기여가 되는 자리입니다."
#
#      논리 백업(mysqldump)은 SQL 문을 다시 실행한다. 파싱하고 인덱스를 다시 만든다.
#      물리 백업(데이터 디렉터리 복사)은 파일을 그대로 옮긴다. 복원에 SQL 이 없다.
#      백업 크기와 복원 시간을 규모별로 잰다.
#
#   2) MySQL 쪽 세 구간은 여전히 1회 실행값입니다
#      5절의 PostgreSQL 조건만 4회 반복했다. MySQL 의 덤프·복원·binlog 적용을 반복한다.
#
# 물리 백업은 Percona XtraBackup 이 정석이지만 MySQL 8.4 용 이미지 확보가 따로 필요하다.
# 여기서는 서버를 멈추고 데이터 디렉터리를 통째로 복사하는 콜드 백업으로 잰다.
# 무중단이 아니라는 것이 콜드 백업의 대가이고, 그 대가까지 포함해 적는다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
REPEAT=${REPEAT:-3}
SIZES=${SIZES:-"100000 1000000"}

M(){ docker exec a23-mysql mysql -uroot -plab -N -B -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }
R(){ docker exec a23-restore mysql -uroot -plab -N -B -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }

wait_up(){ # $1=컨테이너
  for _ in $(seq 1 90); do
    docker exec "$1" mysqladmin ping -uroot -plab >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

wait_up a23-mysql || { echo "중단: a23-mysql 이 준비되지 않았습니다" >&2; exit 2; }
wait_up a23-restore || { echo "중단: a23-restore 가 준비되지 않았습니다" >&2; exit 2; }

seed(){ # $1=행 수
  M "DROP DATABASE IF EXISTS bench; CREATE DATABASE bench" >/dev/null
  M "CREATE TABLE bench.t (
       id BIGINT AUTO_INCREMENT PRIMARY KEY,
       a VARCHAR(64), b VARCHAR(64), c INT,
       KEY idx_a (a), KEY idx_c (c)
     )" >/dev/null
  # 인덱스가 둘 있어야 복원 쪽 비용이 드러난다. 논리 복원은 인덱스를 다시 만든다.
  M "INSERT INTO bench.t (a, b, c)
     SELECT MD5(n), MD5(n+1), n % 1000 FROM (
       SELECT @r := @r + 1 AS n FROM information_schema.COLUMNS c1,
         information_schema.COLUMNS c2, information_schema.COLUMNS c3,
         (SELECT @r := 0) r LIMIT $1
     ) t" >/dev/null 2>&1
}

{
echo "# 논리 백업과 물리 백업의 복원 시간, 그리고 MySQL 구간 반복"
echo "# MySQL $(M 'SELECT VERSION()')"
echo "# 규모 ${SIZES}, 각 ${REPEAT}회 반복"
echo

: > "$OUT/logical-vs-physical.csv"
echo "rows,run,kind,phase,seconds,bytes" >> "$OUT/logical-vs-physical.csv"

for rows in $SIZES; do
  echo "=================================================================="
  echo "## ${rows}행"
  echo "=================================================================="
  seed "$rows"
  N=$(M "SELECT COUNT(*) FROM bench.t")
  SZ=$(M "SELECT ROUND((DATA_LENGTH+INDEX_LENGTH)) FROM information_schema.TABLES
          WHERE TABLE_SCHEMA='bench' AND TABLE_NAME='t'")
  echo "  적재 ${N}행, 테이블 $(python3 -c "print(f'{${SZ:-0}/1048576:.1f}')")MB"
  echo

  # ── 패스 1: 논리 백업과 복원만 ─────────────────────────────────────
  # 물리 쪽과 같은 루프에서 돌리면 물리 복원이 복구 인스턴스의 데이터 디렉터리를
  # 통째로 갈아엎어 다음 논리 복원이 깨진다. 실제로 첫 회차만 성공하고 나머지는
  # "Table 'bench.t' doesn't exist" 가 행 수 자리에 들어갔다. 패스를 나눈다.
  for run in $(seq 1 "$REPEAT"); do
    T0=$(date +%s%N)
    docker exec a23-mysql mysqldump -uroot -plab --single-transaction bench \
      > "$OUT/bench-${rows}.sql" 2>/dev/null
    T1=$(date +%s%N)
    DUMP_B=$(wc -c < "$OUT/bench-${rows}.sql" | tr -d ' ')
    R "DROP DATABASE IF EXISTS bench; CREATE DATABASE bench" >/dev/null
    T2=$(date +%s%N)
    docker exec -i a23-restore mysql -uroot -plab bench < "$OUT/bench-${rows}.sql" 2>/dev/null
    T3=$(date +%s%N)
    RN=$(R "SELECT COUNT(*) FROM bench.t")
    case "${RN:-}" in ''|*[!0-9]*) RN=0 ;; esac
    L_BACKUP=$(python3 -c "print(f'{($T1-$T0)/1e9:.2f}')")
    L_RESTORE=$(python3 -c "print(f'{($T3-$T2)/1e9:.2f}')")
    if [ "$RN" -lt "$N" ]; then
      printf "  run%d  논리 실패(복원 후 %s행, 기대 %s행). 이 회차는 버립니다\n" "$run" "$RN" "$N"
    else
      echo "$rows,$run,logical,backup,$L_BACKUP,$DUMP_B" >> "$OUT/logical-vs-physical.csv"
      echo "$rows,$run,logical,restore,$L_RESTORE,$DUMP_B" >> "$OUT/logical-vs-physical.csv"
      printf "  run%d  논리 백업 %6ss 복원 %6ss (%sMB, 복원 후 %s행)\n" \
        "$run" "$L_BACKUP" "$L_RESTORE" \
        "$(python3 -c "print(f'{${DUMP_B:-0}/1048576:.1f}')")" "$RN"
    fi
    rm -f "$OUT/bench-${rows}.sql"
  done

  # ── 패스 2: 물리 백업과 복원만 ─────────────────────────────────────
  for run in $(seq 1 "$REPEAT"); do
    T4=$(date +%s%N)
    docker stop a23-mysql >/dev/null
    docker run --rm --volumes-from a23-mysql -v "$OUT":/backup alpine \
      sh -c "cd /var/lib/mysql && tar cf /backup/bench-phys.tar ." >/dev/null 2>&1
    docker start a23-mysql >/dev/null
    T5=$(date +%s%N)
    wait_up a23-mysql || echo "  경고: a23-mysql 재기동 확인 실패"
    PHYS_B=$(wc -c < "$OUT/bench-phys.tar" 2>/dev/null | tr -d ' ')

    T6=$(date +%s%N)
    docker stop a23-restore >/dev/null
    docker run --rm --volumes-from a23-restore -v "$OUT":/backup alpine \
      sh -c "rm -rf /var/lib/mysql/* && cd /var/lib/mysql && tar xf /backup/bench-phys.tar" >/dev/null 2>&1
    docker start a23-restore >/dev/null
    wait_up a23-restore || echo "  경고: a23-restore 재기동 확인 실패"
    T7=$(date +%s%N)
    PN=$(R "SELECT COUNT(*) FROM bench.t")
    case "${PN:-}" in ''|*[!0-9]*) PN=0 ;; esac
    P_BACKUP=$(python3 -c "print(f'{($T5-$T4)/1e9:.2f}')")
    P_RESTORE=$(python3 -c "print(f'{($T7-$T6)/1e9:.2f}')")
    if [ "$PN" -lt "$N" ]; then
      printf "  run%d  물리 실패(복원 후 %s행, 기대 %s행). 이 회차는 버립니다\n" "$run" "$PN" "$N"
    else
      echo "$rows,$run,physical,backup,$P_BACKUP,$PHYS_B" >> "$OUT/logical-vs-physical.csv"
      echo "$rows,$run,physical,restore,$P_RESTORE,$PHYS_B" >> "$OUT/logical-vs-physical.csv"
      printf "  run%d  물리 백업 %6ss 복원 %6ss (%sMB, 복원 후 %s행)\n" \
        "$run" "$P_BACKUP" "$P_RESTORE" \
        "$(python3 -c "print(f'{${PHYS_B:-0}/1048576:.1f}')")" "$PN"
    fi
    rm -f "$OUT/bench-phys.tar"
  done
  echo
done

echo "=================================================================="
echo "## 정리"
echo "=================================================================="
python3 - "$OUT/logical-vs-physical.csv" <<'PY'
import csv, sys, collections, statistics
rows = collections.defaultdict(list)
for r in csv.DictReader(open(sys.argv[1])):
    rows[(r['rows'], r['kind'], r['phase'])].append(float(r['seconds']))
sizes = sorted({k[0] for k in rows}, key=int)
print(f"  {'행 수':>10} {'논리 백업':>11} {'논리 복원':>11} {'물리 백업':>11} {'물리 복원':>11} {'복원 배수':>10}")
for s in sizes:
    def med(kind, phase):
        xs = rows.get((s, kind, phase), [])
        return statistics.median(xs) if xs else 0.0
    lr, pr = med('logical','restore'), med('physical','restore')
    print(f"  {int(s):>10,} {med('logical','backup'):>10.2f}s {lr:>10.2f}s "
          f"{med('physical','backup'):>10.2f}s {pr:>10.2f}s "
          f"{(lr/pr if pr else 0):>9.2f}배")
print()
print("  논리 복원은 SQL 을 다시 실행합니다. 파싱하고 행을 넣고 인덱스를 다시 만듭니다.")
print("  물리 복원은 파일을 옮기고 서버를 띄웁니다. 복원 쪽 배수가 그 차이입니다.")
print("  대신 물리 쪽은 백업할 때 서버를 멈춰야 했습니다(이 랩은 콜드 백업).")
print("  XtraBackup 같은 도구는 그 정지를 없애는 대신 도구 자체가 필요합니다.")
print("  백업 시간만 보고 고르면 안 되고, RTO 는 복원 쪽에서 정해집니다.")
PY
echo
echo "  각 규모 ${REPEAT}회 실행입니다."
} 2>&1 | tee "$OUT/exp7-logical-vs-physical.txt"
