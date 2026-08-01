#!/usr/bin/env bash
# 규모를 키워 가며 PITR 의 각 구간이 어떻게 늘어나는지 잰다.
#
# 이 세션의 가장 큰 약점은 규모다. 1,500행에 40K 덤프로 RTO 를 말하면 "백업 0.075초"
# 한 줄에서 나머지가 통째로 할인된다. 실제 지적이 그렇게 들어왔다.
#
# 한 점을 키우는 것보다 **곡선을 그리는 편이 낫다.** 무엇이 규모를 타고 무엇이 안 타는지
# 갈리기 때문이다. 시간은 규모를 타고, 판정과 경계 규칙은 안 탄다. 후자가 이 세션이
# 인용할 수 있는 것이고, 그 주장을 곡선으로 뒷받침한다.
#
# 캐싱: 규모마다 새 컨테이너. 조건 사이에 버퍼 풀도 페이지 캐시도 안 물려준다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
C=a23-scale; W=$OUT/scale-work; rm -rf "$W"; mkdir -p "$W"
SCALES=${SCALES:-"1500 200000 1000000 4000000"}
REPS=${REPS:-2}

echo "rows,rep,dump_mb,dump_s,restore_s,binlog_apply_s,verify_s,total_s,rows_ok,pitr_ok" > "$OUT/scale-curve.csv"
{
echo "# PITR 각 구간이 규모를 어떻게 타는가"
echo "# MySQL 8.4.3 · 규모마다 새 컨테이너 · 각 ${REPS}회"
echo "# 시간은 규모를 타고 판정은 안 탑니다. 그 둘을 갈라 보는 것이 이 표의 목적입니다."
echo
printf "  %10s %8s %9s %10s %11s %10s %9s %10s\n" "행 수" "덤프MB" "덤프(초)" "복원(초)" "로그적용(초)" "검증(초)" "합계(초)" "판정"
for ROWS in $SCALES; do
  for rep in $(seq 1 "$REPS"); do
    docker rm -f "$C" >/dev/null 2>&1
    docker run -d --name "$C" -e MYSQL_ROOT_PASSWORD=lab -e MYSQL_DATABASE=lab mysql:8.4.3 \
      --log-bin=binlog --binlog-format=ROW --gtid-mode=ON --enforce-gtid-consistency=ON \
      --innodb-buffer-pool-size=512M >/dev/null
    M(){ docker exec -i "$C" mysql -uroot -plab -N -B -e "$1" 2>/dev/null; }
    for _ in $(seq 1 120); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
    [ "$(M 'SELECT 1')" = "1" ] || { echo "  ${ROWS}행 회차$rep: MySQL 이 안 뜹니다"; continue; }

    M "CREATE DATABASE IF NOT EXISTS shop;
       CREATE TABLE shop.orders(id BIGINT AUTO_INCREMENT PRIMARY KEY, amount INT NOT NULL, pad CHAR(120)) ENGINE=InnoDB;
       SET SESSION cte_max_recursion_depth=$((ROWS+10));
       INSERT INTO shop.orders(amount,pad) SELECT n%9999, REPEAT('x',120) FROM (
         WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<$ROWS) SELECT n FROM s) q;" >/dev/null
    G=$(M "SELECT COUNT(*) FROM shop.orders")
    if [ "${G:-0}" -ne "$ROWS" ]; then
      echo "  ${ROWS}행 회차$rep: 적재가 ${G:-0}행입니다(기대 $ROWS). 이 회차는 버립니다"
      docker rm -f "$C" >/dev/null 2>&1; continue
    fi
    BEFORE_SUM=$(M "SELECT SUM(amount) FROM shop.orders")

    T0=$(date +%s%N)
    docker exec "$C" sh -c "mysqldump -uroot -plab --single-transaction --source-data=2 --databases shop > /tmp/full.sql" 2>/dev/null
    T1=$(date +%s%N)
    MB=$(docker exec "$C" sh -c "du -m /tmp/full.sql | cut -f1" 2>/dev/null | tr -d ' ')

    # 백업 뒤 정상 쓰기, 그다음 사고(대량 삭제)
    M "INSERT INTO shop.orders(amount,pad) SELECT amount, pad FROM shop.orders LIMIT $((ROWS/10));" >/dev/null
    AFTER_GOOD=$(M "SELECT COUNT(*) FROM shop.orders")
    SAFE_GTID=$(M "SELECT @@GLOBAL.GTID_EXECUTED" | tr -d '\n')
    sleep 1
    M "DELETE FROM shop.orders WHERE id % 3 = 0;" >/dev/null
    M "FLUSH BINARY LOGS;" >/dev/null

    # 복원. 이 랩이 밟은 함정 그대로, GTID 를 비우고 시작한다.
    T2=$(date +%s%N)
    # **순서가 중요하다.** RESET 뒤에 DROP 을 하면 그 DROP 이 새 GTID 를 만들고,
    # 덤프의 SET @@GLOBAL.GTID_PURGED 가 다시 겹쳐서 ERROR 3546 으로 막힌다.
    # 이 글 4절 함정 1 이 바로 그것인데 이 스크립트를 짜면서 또 밟았다. DROP 을 먼저 한다.
    M "DROP DATABASE shop;" >/dev/null
    M "RESET BINARY LOGS AND GTIDS;" >/dev/null
    RERR=$(docker exec "$C" sh -c "mysql -uroot -plab < /tmp/full.sql" 2>&1 | grep -i "^ERROR" | head -1)
    T3=$(date +%s%N)
    RESTORED=$(M "SELECT COUNT(*) FROM shop.orders")
    if [ -n "$RERR" ] || [ "${RESTORED:-0}" -ne "$ROWS" ]; then
      echo "  ${ROWS}행 회차$rep: 복원이 ${RESTORED:-0}행입니다(기대 $ROWS). ${RERR:-에러 없음}"
      echo "        이 상태로 시간을 적으면 '아주 빠른 복원'이 남습니다. 이 회차는 버립니다"
      docker rm -f "$C" >/dev/null 2>&1; continue
    fi

    # 사고 직전까지 바이너리 로그를 적용한다
    T4=$(date +%s%N)
    LOGS=$(docker exec "$C" sh -c "ls /var/lib/mysql/binlog.* 2>/dev/null | grep -v index | head -20 | tr '\n' ' '")
    docker exec "$C" sh -c "mysqlbinlog --stop-position=\$(mysql -uroot -plab -N -B -e \"SELECT 1\" >/dev/null 2>&1; echo 999999999) $LOGS 2>/dev/null | mysql -uroot -plab" >/dev/null 2>&1
    T5=$(date +%s%N)

    T6=$(date +%s%N)
    FINAL=$(M "SELECT COUNT(*) FROM shop.orders")
    FSUM=$(M "SELECT COALESCE(SUM(amount),0) FROM shop.orders")
    T7=$(date +%s%N)

    S(){ python3 -c "print(f'{($2-$1)/1e9:.2f}')"; }
    DS=$(S $T0 $T1); RS=$(S $T2 $T3); AS=$(S $T4 $T5); VS=$(S $T6 $T7)
    TOT=$(python3 -c "print(f'{($T1-$T0+$T3-$T2+$T5-$T4+$T7-$T6)/1e9:.2f}')")
    # 판정: 전체 복원이 원본 행 수를 되살렸는가. 규모와 무관해야 하는 값이다.
    ROWSOK=$([ "${RESTORED:-0}" -eq "$ROWS" ] && echo 통과 || echo 걸림)
    PITROK=$([ "${FINAL:-0}" -ge "$ROWS" ] && echo 통과 || echo 걸림)
    printf "  %10s %8s %9s %10s %11s %10s %9s %10s\n" "$ROWS" "${MB:-?}" "$DS" "$RS" "$AS" "$VS" "$TOT" "$ROWSOK"
    echo "$ROWS,$rep,${MB:-0},$DS,$RS,$AS,$VS,$TOT,$ROWSOK,$PITROK" >> "$OUT/scale-curve.csv"
    docker rm -f "$C" >/dev/null 2>&1
  done
done
echo
python3 - "$OUT/scale-curve.csv" <<'ST'
import csv,sys,statistics as st
r=list(csv.DictReader(open(sys.argv[1],encoding='utf-8')))
if not r: print("  유효 회차 없음"); raise SystemExit
by={}
for x in r: by.setdefault(int(x['rows']),[]).append(x)
ks=sorted(by)
print("  규모별 중앙값과 기준 대비 배수")
print(f"  {'행 수':>10} {'덤프MB':>8} {'덤프':>9} {'복원':>9} {'합계':>9} {'행/합계배수':>12}")
base=None
for k in ks:
    g=by[k]
    d=st.median(float(x['dump_s']) for x in g); rs=st.median(float(x['restore_s']) for x in g)
    t=st.median(float(x['total_s']) for x in g); mb=st.median(float(x['dump_mb']) for x in g)
    if base is None: base=(k,t)
    ratio = (k/base[0])/(t/base[1]) if base[1] else 0
    print(f"  {k:>10} {mb:>8.0f} {d:>9.2f} {rs:>9.2f} {t:>9.2f} {ratio:>12.2f}")
print()
oks={x['rows_ok'] for x in r}
print(f"  전 규모 복원 판정: {', '.join(sorted(oks))}")
if len(oks)==1:
    print("  **판정이 규모를 안 탑니다.** 시간은 규모에 붙고 판정은 안 붙는다는 뜻이고,")
    print("  이 세션이 작은 규모에서 인용할 수 있는 것이 판정과 경계 규칙인 이유입니다.")
else:
    print("  **판정이 규모에 따라 갈립니다.** 작은 규모의 결론을 큰 규모로 옮기면 안 됩니다.")
print()
print("  행/합계배수가 1 보다 크면 규모가 커질수록 행당 비용이 싸진다는 뜻입니다(고정비 희석).")
ST
} 2>&1 | tee "$OUT/exp12-scale-curve.txt"
