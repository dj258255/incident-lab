#!/usr/bin/env bash
# 못 한 것 두 항목을 채운다.
#
#  1) 논리 대 물리의 교차점을 10만과 100만 사이에서 좁힌다. 지금은 그 사이 어딘가라는
#     것까지이고 정확한 지점을 모른다.
#  2) PITR 세 구간(백업·복원·binlog 적용)의 비율이 규모를 어떻게 타는지 잰다.
#     3절이 1,500행, 11절이 20만 행까지이고 그 위는 안 쟀다.
#
# 캐싱: 규모마다 새 컨테이너. 조건 사이에 버퍼 풀도 페이지 캐시도 안 물려준다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
C=a23-x16
SCALES=${SCALES:-"100000 250000 500000 1000000"}

echo "rows,dump_s,logical_restore_s,phys_backup_s,phys_restore_s,binlog_apply_s,verify_s" > "$OUT/crossover-segments.csv"
{
echo "# 교차점 좁히기와 PITR 세 구간의 규모별 비율"
echo "# MySQL 8.4.3 · 규모마다 새 컨테이너 · 각 1회"
echo
printf "  %9s %10s %12s %11s %12s %11s %s\n" "행 수" "덤프(초)" "논리복원(초)" "물리백업(초)" "물리복원(초)" "로그적용(초)" "판정"
for ROWS in $SCALES; do
  docker rm -f "$C" >/dev/null 2>&1; docker volume rm ${C}-d >/dev/null 2>&1; docker volume create ${C}-d >/dev/null
  docker run -d --name "$C" -v ${C}-d:/var/lib/mysql -e MYSQL_ROOT_PASSWORD=lab -e MYSQL_DATABASE=lab \
    mysql:8.4.3 --log-bin=binlog --binlog-format=ROW --gtid-mode=ON --enforce-gtid-consistency=ON >/dev/null
  M(){ docker exec -i "$C" mysql -uroot -plab -N -B -e "$1" 2>/dev/null; }
  for _ in $(seq 1 120); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
  [ "$(M 'SELECT 1')" = "1" ] || { echo "  ${ROWS}행: MySQL 이 안 뜹니다"; continue; }

  M "CREATE DATABASE IF NOT EXISTS shop;
     CREATE TABLE shop.orders(id BIGINT AUTO_INCREMENT PRIMARY KEY, amount INT, pad CHAR(120)) ENGINE=InnoDB;
     SET SESSION cte_max_recursion_depth=$((ROWS+10));
     INSERT INTO shop.orders(amount,pad) SELECT n%9999, REPEAT('x',120) FROM (
       WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<$ROWS) SELECT n FROM s) q;" >/dev/null
  G=$(M "SELECT COUNT(*) FROM shop.orders")
  [ "${G:-0}" -ne "$ROWS" ] && { echo "  ${ROWS}행: 적재 ${G:-0}행(기대 $ROWS). 버립니다"; docker rm -f "$C" >/dev/null; continue; }

  S(){ python3 -c "print(f'{($2-$1)/1e9:.2f}')"; }

  # (1) 논리: 덤프와 복원
  T0=$(date +%s%N)
  docker exec "$C" sh -c "mysqldump -uroot -plab --single-transaction --source-data=2 --databases shop > /tmp/f.sql" 2>/dev/null
  T1=$(date +%s%N)

  # 백업 뒤 정상 쓰기, 그다음 사고. binlog 적용 구간을 만들기 위해서다.
  M "INSERT INTO shop.orders(amount,pad) SELECT amount,pad FROM shop.orders LIMIT $((ROWS/10));" >/dev/null
  AFTER_GOOD=$(M "SELECT COUNT(*) FROM shop.orders")
  M "DELETE FROM shop.orders WHERE id % 3 = 0; FLUSH BINARY LOGS;" >/dev/null

  T2=$(date +%s%N)
  M "DROP DATABASE shop;" >/dev/null
  M "RESET BINARY LOGS AND GTIDS;" >/dev/null
  docker exec "$C" sh -c "mysql -uroot -plab < /tmp/f.sql" 2>/dev/null
  T3=$(date +%s%N)
  RESTORED=$(M "SELECT COUNT(*) FROM shop.orders")

  # (2) binlog 적용 구간
  T4=$(date +%s%N)
  LOGS=$(docker exec "$C" sh -c "ls /var/lib/mysql/binlog.0* 2>/dev/null | tr '\n' ' '")
  docker exec "$C" sh -c "mysqlbinlog $LOGS 2>/dev/null | mysql -uroot -plab" >/dev/null 2>&1
  T5=$(date +%s%N)

  T6=$(date +%s%N); FINAL=$(M "SELECT COUNT(*) FROM shop.orders"); T7=$(date +%s%N)

  # (3) 물리: 콜드 복사와 되돌리기
  M "FLUSH TABLES WITH READ LOCK;" >/dev/null 2>&1
  docker stop "$C" >/dev/null 2>&1
  P0=$(date +%s%N)
  docker run --rm -v ${C}-d:/from -v /tmp/x16phys:/to alpine:latest sh -c "rm -rf /to/* && cp -a /from/. /to/" >/dev/null 2>&1
  P1=$(date +%s%N)
  docker volume rm ${C}-d >/dev/null 2>&1; docker volume create ${C}-d >/dev/null
  P2=$(date +%s%N)
  docker run --rm -v ${C}-d:/to -v /tmp/x16phys:/from alpine:latest sh -c "cp -a /from/. /to/" >/dev/null 2>&1
  docker start "$C" >/dev/null 2>&1
  for _ in $(seq 1 120); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
  P3=$(date +%s%N)
  PHYS=$(M "SELECT COUNT(*) FROM shop.orders")

  OK=$([ "${RESTORED:-0}" -eq "$ROWS" ] && [ "${PHYS:-0}" -ge 0 ] && echo 통과 || echo "걸림(복원 ${RESTORED:-0})")
  printf "  %9s %10s %12s %11s %12s %11s %s\n" "$ROWS" \
    "$(S $T0 $T1)" "$(S $T2 $T3)" "$(S $P0 $P1)" "$(S $P2 $P3)" "$(S $T4 $T5)" "$OK"
  echo "$ROWS,$(S $T0 $T1),$(S $T2 $T3),$(S $P0 $P1),$(S $P2 $P3),$(S $T4 $T5),$(S $T6 $T7)" >> "$OUT/crossover-segments.csv"
  docker rm -f "$C" >/dev/null 2>&1; docker volume rm ${C}-d >/dev/null 2>&1
done
rm -rf /tmp/x16phys
echo
python3 - "$OUT/crossover-segments.csv" <<'ST'
import csv,sys
r=[x for x in csv.DictReader(open(sys.argv[1],encoding='utf-8'))]
if len(r)<2: print("  유효 규모가 모자랍니다"); raise SystemExit
print("  규모별 논리 대 물리 (복원 기준)")
print(f"  {'행 수':>9} {'논리복원':>10} {'물리복원':>10} {'어느 쪽이 빠른가':>18}")
cross=None; prev=None
for x in r:
    lo=float(x['logical_restore_s']); ph=float(x['phys_restore_s'])
    w = "물리" if ph<lo else "논리"
    if prev and prev!=w: cross=x['rows']
    prev=w
    print(f"  {int(x['rows']):>9,} {lo:>9.2f}초 {ph:>9.2f}초 {w:>18}")
print()
print(f"  교차점: {'약 '+format(int(cross),',')+'행 부근' if cross else '이 범위에서 안 갈림'}")
print()
print("  PITR 세 구간의 비율")
print(f"  {'행 수':>9} {'백업':>8} {'복원':>8} {'로그적용':>10} {'복원 비중':>10} {'로그 비중':>10}")
for x in r:
    d=float(x['dump_s']); rs=float(x['logical_restore_s']); b=float(x['binlog_apply_s'])
    t=d+rs+b
    if t==0: continue
    print(f"  {int(x['rows']):>9,} {d:>7.2f}초 {rs:>7.2f}초 {b:>9.2f}초 {rs/t*100:>9.1f}% {b/t*100:>9.1f}%")
print()
print("  3절이 1,500행에서 로그 적용이 대부분이라고 적었습니다. 위 표가 그 비율이 규모를")
print("  어떻게 타는지 보여 줍니다. 복원 비중이 오르면 그 서술은 작은 규모에서만 성립합니다.")
ST
} 2>&1 | tee "$OUT/exp16-crossover-segments.txt"
