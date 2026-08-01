#!/usr/bin/env bash
# 문자셋 전환 중 대기가 어느 규모에서 1205 로 바뀌는지 찾는다.
# 본문 8절은 전환 창 안의 표본이 두 건뿐이었다. 쓰기가 통째로 멈추는 바람에 창 안에
# 시도가 두 건밖에 안 들어갔고, 락 대기 타임아웃을 넘기는 지점은 재지 않았다고 적었다.
#
# CONVERT TO CHARACTER SET 은 테이블을 재작성하며 배타 MDL 을 요구한다. 뒤에 선 쓰기는
# lock_wait_timeout 을 기다리다 초과하면 ER_LOCK_WAIT_TIMEOUT(1205) 을 받는다.
# 행 수를 키워 전환 시간을 늘리면서 그 경계를 찾는다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
C=r14-lt; LWT=${LWT:-5}
# 1차 시도는 LWT=5 에 200만 행이었는데 전환이 4.0초라 경계를 안 넘겼다.
# 경계를 감싸려면 타임아웃을 낮추거나 행을 키워야 한다. 둘 다 손잡이로 둔다.

echo "rows,convert_sec,attempts,ok,err1205,other" > "$OUT/lock-timeout.csv"
{
echo "# 문자셋 전환 중 쓰기가 1205 로 바뀌는 지점"
echo "# lock_wait_timeout = ${LWT}초 · 전환 중 0.5초 간격으로 쓰기를 시도합니다"
echo
printf "  %10s %12s %10s %8s %10s %8s\n" "행 수" "전환(초)" "시도" "성공" "1205" "기타"
for ROWS in ${ROWLIST:-100000 500000 2000000}; do
  docker rm -f "$C" >/dev/null 2>&1
  docker run -d --name "$C" -e MYSQL_ROOT_PASSWORD=lab -e MYSQL_DATABASE=lab mysql:8.4.3 >/dev/null
  M(){ docker exec -i "$C" mysql -uroot -plab -N -B lab -e "$1" 2>/dev/null; }
  for _ in $(seq 1 90); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
  M "CREATE TABLE t(id INT AUTO_INCREMENT PRIMARY KEY, s VARCHAR(120) CHARACTER SET latin1) ENGINE=InnoDB;
     SET SESSION cte_max_recursion_depth=$((ROWS+10));
     INSERT INTO t(s) SELECT REPEAT('a',100) FROM (
       WITH RECURSIVE q(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM q WHERE n<$ROWS) SELECT n FROM q) z;" >/dev/null
  G=$(M "SELECT COUNT(*) FROM t")
  [ "${G:-0}" -ne "$ROWS" ] && { echo "  적재 ${G:-0}행(기대 $ROWS), 건너뜀"; docker rm -f "$C" >/dev/null; continue; }
  : > /tmp/r14-w.log
  # 전환 중 계속 쓰기를 시도한다
  docker exec -d "$C" bash -c "
    for i in \$(seq 1 200); do
      mysql -uroot -plab lab -e \"SET SESSION lock_wait_timeout=$LWT;
        INSERT INTO t(s) VALUES('probe');\" >/dev/null 2>>/tmp/w.err
      echo done >> /tmp/w.cnt
      sleep 0.5
    done"
  sleep 1
  t0=$(date +%s%N)
  M "ALTER TABLE t CONVERT TO CHARACTER SET utf8mb4;" >/dev/null
  t1=$(date +%s%N); SEC=$(python3 -c "print(f'{($t1-$t0)/1e9:.1f}')")
  sleep 1
  ATT=$(docker exec "$C" sh -c "wc -l < /tmp/w.cnt" 2>/dev/null | tr -d ' ')
  E1205=$(docker exec "$C" sh -c "grep -o 'ERROR 1205' /tmp/w.err | wc -l" 2>/dev/null | tr -d ' ')
  EALL=$(docker exec "$C" sh -c "grep -o 'ERROR [0-9]*' /tmp/w.err | wc -l" 2>/dev/null | tr -d ' ')
  OTHER=$(( ${EALL:-0} - ${E1205:-0} ))
  OK=$(( ${ATT:-0} - ${EALL:-0} ))
  printf "  %10s %12s %10s %8s %10s %8s\n" "$ROWS" "$SEC" "${ATT:-0}" "$OK" "${E1205:-0}" "$OTHER"
  echo "$ROWS,$SEC,${ATT:-0},$OK,${E1205:-0},$OTHER" >> "$OUT/lock-timeout.csv"
  docker rm -f "$C" >/dev/null 2>&1
done
echo
echo "  전환이 lock_wait_timeout(${LWT}초)보다 오래 걸리기 시작하면 뒤에 선 쓰기가"
echo "  기다리다 못해 1205 를 받습니다. 그 전까지는 기다렸다가 성공합니다."
} 2>&1 | tee "$OUT/exp3-lock-timeout.txt"
