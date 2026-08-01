#!/usr/bin/env bash
# 열린 트랜잭션이 버퍼 풀 축소를 막는가.
#
# 이 세션은 축소 3.5초에 374.9ms 정지를 쟀다. 그때 부하는 짧은 조회여서 페이지에 락을
# 쥔 채 오래 머무는 트랜잭션이 없었다. MySQL 공식 블로그는 그 조건을 이렇게 적는다.
#   "If a transaction has locks on any of the pages in the chunk to be freed, then the
#    relocation of those pages should wait for the transaction end. So high transaction
#    throughput or long running transactions can potentially block the buffer pool
#    resize operation."
# 축소가 3.5초가 아니라 트랜잭션이 끝날 때까지라는 뜻이다. 그것을 확인한다.
#
# 시간이 아니라 **완료 여부**를 본다. 에뮬레이션도 아니고 호스트도 같지만, 이 질문의
# 답은 초 단위 수치가 아니라 "끝났는가 / 안 끝났는가"다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
C=a08-shrink; HOLD=${HOLD:-25}   # 트랜잭션을 쥐고 있을 시간(초)

docker rm -f "$C" >/dev/null 2>&1
docker run -d --name "$C" -e MYSQL_ROOT_PASSWORD=lab -e MYSQL_DATABASE=lab mysql:8.4.3 \
  --innodb-buffer-pool-size=2G --innodb-buffer-pool-chunk-size=128M \
  --innodb-buffer-pool-instances=1 >/dev/null
M(){ docker exec -i "$C" mysql -uroot -plab -N -B lab -e "$1" 2>&1; }
for _ in $(seq 1 90); do [ "$(M 'SELECT 1' | tail -1)" = "1" ] && break; sleep 2; done
[ "$(M 'SELECT 1' | tail -1)" = "1" ] || { echo "중단: MySQL 이 안 뜹니다" >&2; exit 2; }

# 1차 시도는 300,000행(약 90MB)이었고 목표가 256M 이라 **잠긴 페이지가 전부
# 남는 쪽에 들어갔다.** 그러면 "해제할 청크 안의 페이지에 락이 있는가"라는 조건이
# 아예 서지 않는다. 축소가 1초에 끝난 것은 안 막힌 것이 아니라 막을 것이 없었던 것이다.
# 데이터를 목표보다 크게 만들어 잠긴 페이지가 해제 대상에 들어가게 한다.
ROWS=2000000
M "CREATE TABLE t(id INT PRIMARY KEY, pad CHAR(200)) ENGINE=InnoDB;
   SET SESSION cte_max_recursion_depth=$((ROWS+10));
   INSERT INTO t SELECT n, REPEAT('x',200) FROM (
     WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<$ROWS) SELECT n FROM s) q;" >/dev/null
GOT=$(M "SELECT COUNT(*) FROM t" | tail -1)
[ "${GOT:-0}" -ne "$ROWS" ] && { echo "중단: 적재가 ${GOT:-0}행입니다(기대 $ROWS)" >&2; docker rm -f "$C" >/dev/null; exit 2; }
M "SELECT COUNT(*) FROM t" >/dev/null   # 버퍼 풀에 올린다

status(){ M "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_resize_status'" | tail -1; }
size(){    M "SELECT @@innodb_buffer_pool_size" | tail -1; }

shrink_and_watch(){ # $1 = with_tx | no_tx
  local mode="$1" t0 t1 done_at="" i st
  if [ "$mode" = with_tx ]; then
    # 페이지에 락을 쥔 채 머무는 트랜잭션을 연다
    docker exec -d "$C" mysql -uroot -plab lab -e \
      "START TRANSACTION; SELECT * FROM t WHERE id BETWEEN 1 AND 1500000 FOR UPDATE; SELECT SLEEP($HOLD); COMMIT;"
    sleep 3
    local held; held=$(M "SELECT COUNT(*) FROM performance_schema.data_locks WHERE OBJECT_NAME='t'" | tail -1)
    local dl; dl=$(M "SELECT DATA_LENGTH FROM information_schema.tables WHERE table_schema='lab' AND table_name='t'" | tail -1)
    printf "  %-30s %sM (목표 크기 256M)\n" "테이블 크기" "$(( ${dl:-0} / 1048576 ))"
    if [ "${held:-0}" -lt 100 ]; then
      echo "  중단: 락을 쥔 트랜잭션이 안 섰습니다(락 ${held:-0}개). 이 상태로 재면" >&2
      echo "        '안 막혔다'가 나와도 조건이 없어서 안 막힌 것입니다." >&2
      return 1
    fi
    printf "  %-30s %s개\n" "연 트랜잭션이 쥔 락" "$held"
  fi
  # 리사이즈 상태 변수는 **직전 리사이즈의 완료 문자열을 그대로 들고 있다.**
  # 그래서 "completed 가 보이면 끝"으로 판정하면 시작하자마자 0초가 나온다.
  # 직전 값을 기억해 두고 그것과 달라진 뒤에야 판정한다.
  local before; before=$(status)
  t0=$(date +%s)
  M "SET GLOBAL innodb_buffer_pool_size = 268435456;" >/dev/null   # 2G -> 256M
  for i in $(seq 1 90); do
    st=$(status)
    if [ "$st" != "$before" ]; then
      case "$st" in *ompleted*) done_at=$(( $(date +%s) - t0 )); break;; esac
    fi
    sleep 1
  done
  t1=$(date +%s)
  printf "  %-30s %s\n" "시작 전 status" "$before"
  printf "  %-30s %s\n" "최종 status" "$(status)"
  local sz; sz=$(size); printf "  %-30s %sM\n" "최종 buffer pool size" "$(( ${sz:-0} / 1048576 ))"
  if [ -n "$done_at" ]; then printf "  %-30s **%s초**\n" "축소 완료까지" "$done_at"
  else printf "  %-30s **%s초 안에 안 끝났습니다**\n" "축소 완료까지" "$((t1-t0))"; fi
  echo
}

{
echo "# 열린 트랜잭션이 버퍼 풀 축소를 막는가"
echo "# MySQL $(M 'SELECT VERSION()' | tail -1) · 2G -> 256M · 청크 128M · 인스턴스 1"
echo "# 트랜잭션은 ${HOLD}초 동안 20만 행에 FOR UPDATE 를 쥡니다"
echo
echo "## 조건 A. 여는 트랜잭션 없음"
shrink_and_watch no_tx
M "SET GLOBAL innodb_buffer_pool_size = 2147483648;" >/dev/null; sleep 8
echo "## 조건 B. 20만 행에 락을 쥔 트랜잭션이 열려 있음"
shrink_and_watch with_tx
} 2>&1 | tee "$OUT/exp3-shrink-blocked.txt"
docker rm -f "$C" >/dev/null 2>&1
