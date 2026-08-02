#!/usr/bin/env bash
# XtraBackup 으로 무중단 물리 백업을 재 본다.
#
# 10절이 물리 백업은 콜드라 무중단이 안 된다고 적고, XtraBackup 은 이미지를 확보하지
# 못해 안 썼다고 적었다. **확인해 보니 percona/percona-xtrabackup:8.4 가 있다.**
# 안 찾아보고 못 한다고 적은 것이라 지금 잰다.
#
# 보는 것 셋이다.
#   1) 백업 중 쓰기가 계속 되는가 (콜드 백업과 갈리는 지점)
#   2) prepare 와 복원이 실제로 되는가
#   3) 백업 크기와 소요가 mysqldump·콜드 물리와 어떻게 다른가
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
SRC=a23-xtra-src; NET=a23-xtra-net; ROWS=${ROWS:-1000000}; PW=lab
cleanup(){ docker rm -f "$SRC" >/dev/null 2>&1; docker volume rm a23-xtra-data >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
trap cleanup EXIT; cleanup
docker network create "$NET" >/dev/null
docker volume create a23-xtra-data >/dev/null
# 백업 대상은 **호스트 디렉터리**로 둔다. 도커 볼륨을 쓰면 MySQL 데이터 볼륨이 999:999,
# xtrabackup 이미지가 만든 백업 볼륨이 1001:0 으로 소유자가 갈려서 한 uid 로 양쪽을
# 못 쓴다. 데이터를 읽으면 백업에 못 쓰고 백업에 쓰면 데이터를 못 읽는다.
BKDIR=${BKDIR:-/tmp/a23-xtrabackup}
rm -rf "$BKDIR" && mkdir -p "$BKDIR" && chmod 777 "$BKDIR"

docker run -d --name "$SRC" --network "$NET" -e MYSQL_ROOT_PASSWORD=$PW -e MYSQL_DATABASE=lab \
  -v a23-xtra-data:/var/lib/mysql -v "$BKDIR":/backup mysql:8.4.3 >/dev/null
M(){ docker exec -i "$SRC" mysql -uroot -p$PW -N -B lab -e "$1" 2>/dev/null; }
for _ in $(seq 1 90); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(M 'SELECT 1')" = "1" ] || { echo "중단: MySQL 이 안 뜹니다" >&2; exit 2; }

M "CREATE TABLE t(id BIGINT AUTO_INCREMENT PRIMARY KEY, v INT, pad CHAR(120)) ENGINE=InnoDB;
   SET SESSION cte_max_recursion_depth=$((ROWS+10));
   INSERT INTO t(v,pad) SELECT n%997, REPEAT('x',120) FROM (
     WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<$ROWS) SELECT n FROM s) q;" >/dev/null
G=$(M "SELECT COUNT(*) FROM t")
[ "${G:-0}" -ne "$ROWS" ] && { echo "중단: 적재 ${G:-0}행(기대 $ROWS)" >&2; exit 2; }

{
echo "# XtraBackup 으로 무중단 물리 백업"
echo "# MySQL $(M 'SELECT VERSION()') · $ROWS 행 · percona/percona-xtrabackup:8.4"
echo

# 백업 중에도 쓰기가 되는지 보려고, 백업 도는 동안 계속 INSERT 를 던진다.
docker exec -d "$SRC" bash -c "
  for i in \$(seq 1 100000); do
    mysql -uroot -p$PW lab -e \"INSERT INTO t(v,pad) VALUES(9999,'live')\" >/dev/null 2>&1
  done"
sleep 1
BEFORE=$(M "SELECT COUNT(*) FROM t WHERE v=9999")

T0=$(date +%s%N)
BK=$(docker run --rm --network "$NET" -v a23-xtra-data:/var/lib/mysql -v "$BKDIR":/backup \
  --user 999:999 percona/percona-xtrabackup:8.4 xtrabackup --backup --target-dir=/backup/full \
  --datadir=/var/lib/mysql --user=root --password=$PW --host="$SRC" 2>&1 | tail -3)
T1=$(date +%s%N)
AFTER=$(M "SELECT COUNT(*) FROM t WHERE v=9999")
echo "$BK" | grep -qi "completed OK" && BKOK=성공 || BKOK="실패"
printf "  %-30s %s\n" "백업 판정" "$BKOK"
printf "  %-30s %s초\n" "백업 소요" "$(python3 -c "print(f'{($T1-$T0)/1e9:.1f}')")"
printf "  %-30s %s건 → %s건\n" "백업 중 들어온 쓰기" "${BEFORE:-0}" "${AFTER:-0}"
if [ "$BKOK" != 성공 ]; then
  echo "  **백업이 실패했습니다. 아래 줄은 전부 인용하면 안 됩니다.**"
  echo "$BK" | grep -iE "^.*ERROR" | head -2 | sed 's/^/      /'
elif [ "${AFTER:-0}" -gt "${BEFORE:-0}" ]; then
  echo "  **백업이 도는 동안 쓰기가 계속됐습니다.** 콜드 백업과 갈리는 지점입니다."
else
  echo "  **백업 중 쓰기가 안 늘었습니다.** 부하 생성이 안 섰을 수 있어 이 줄은 못 씁니다."
fi

SZ=$(du -sm "$BKDIR/full" 2>/dev/null | cut -f1)
printf "  %-30s %sMB\n" "백업 크기" "${SZ:-?}"

T2=$(date +%s%N)
PR=$(docker run --rm -v "$BKDIR":/backup --user 999:999 percona/percona-xtrabackup:8.4 \
  xtrabackup --prepare --target-dir=/backup/full 2>&1 | tail -2)
T3=$(date +%s%N)
echo "$PR" | grep -qi "completed OK" && PROK=성공 || PROK=실패
printf "  %-30s %s (%s초)\n" "prepare 판정" "$PROK" "$(python3 -c "print(f'{($T3-$T2)/1e9:.1f}')")"

# 복원. 데이터 디렉터리를 비우고 백업을 되돌린 뒤 새 서버로 띄운다.
docker rm -f "$SRC" >/dev/null 2>&1
docker volume rm a23-xtra-data >/dev/null 2>&1; docker volume create a23-xtra-data >/dev/null
# **새 볼륨은 root 소유라 copy-back 이 못 쓴다.** cannot open the destination stream 이
# 나고, 그 실패를 놓치면 뒤에서 복원 0행이 나온다. 미리 소유자를 맞춘다.
docker run --rm -v a23-xtra-data:/var/lib/mysql alpine:latest chown 999:999 /var/lib/mysql >/dev/null 2>&1
T4=$(date +%s%N)
docker run --rm -v a23-xtra-data:/var/lib/mysql -v "$BKDIR":/backup --user 999:999 percona/percona-xtrabackup:8.4 \
  xtrabackup --copy-back --target-dir=/backup/full --datadir=/var/lib/mysql > /tmp/cb.log 2>&1
grep -qi "completed OK" /tmp/cb.log || { echo "  **copy-back 실패**: $(grep -m1 -i error /tmp/cb.log)"; }
docker run -d --name "$SRC" --network "$NET" -e MYSQL_ROOT_PASSWORD=$PW \
  -v a23-xtra-data:/var/lib/mysql mysql:8.4.3 >/dev/null
for _ in $(seq 1 90); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
T5=$(date +%s%N)
R=$(M "SELECT COUNT(*) FROM t")
printf "  %-30s %s초\n" "복원 + 기동" "$(python3 -c "print(f'{($T5-$T4)/1e9:.1f}')")"
printf "  %-30s %s행\n" "복원 후 행 수" "${R:-복원 실패}"
echo
if [ "${R:-0}" -ge "$ROWS" ]; then
  echo "  **무중단 물리 백업이 성립합니다.** 서버를 멈추지 않고 뜬 백업으로 복원까지 됐습니다."
else
  echo "  **복원이 기대에 못 미칩니다(${R:-0}행).** 이 회차는 인용하면 안 됩니다."
fi
echo "$ROWS,$BKOK,$PROK,${SZ:-0},${R:-0}" > "$OUT/xtrabackup.csv"
} 2>&1 | tee "$OUT/exp15-xtrabackup.txt"
