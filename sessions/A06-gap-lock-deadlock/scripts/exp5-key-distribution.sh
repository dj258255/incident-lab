#!/usr/bin/env bash
# 키 분포와 테이블 크기가 데드락 발생률을 정하는가.
#
# KINTO 는 이 유형을 운영에서 만나고 나서 부하 시험이 왜 통과했는지를 이렇게 적었다.
#   "we used random values (UUIDs) for the request_id ... no deadlock occurred during the tests"
# 이 세션은 인덱스 유무를 축으로 잡았지 키 분포를 축으로 잡지 않았다.
#
# 계측에서 두 번 미끄러졌고 그 자국을 남겨 둔다.
#  1) error log 를 grep 해 데드락을 셌더니 0 이 나왔다. 실제로는 215건이 났고
#     패턴이 안 맞았을 뿐이다. 클라이언트가 받은 ERROR 1213 으로 바꿨다.
#  2) 동시 실행을 컨테이너 안으로 옮기면서 mysql 의 stderr 를 /dev/null 로 버렸다.
#     그러자 전 조건이 "데드락 0건, 성공 200건"으로 나왔다. 아무것도 안 재고 있었다.
#     에러를 컨테이너 안 파일에 모으고 그 파일을 세는 방식으로 고쳤다.
# 두 번 다 0 이 "안 났다"와 "못 셌다"를 구분하지 못하는 계측이었다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
C=a06-keydist; ROUNDS=${ROUNDS:-25}; CONC=${CONC:-8}; PRELOAD=${PRELOAD:-200000}
EF=/tmp/errs

docker rm -f "$C" >/dev/null 2>&1
docker run -d --name "$C" -e MYSQL_ROOT_PASSWORD=lab -e MYSQL_DATABASE=lab mysql:8.4.3 >/dev/null
M(){ docker exec -i "$C" mysql -uroot -plab -N -B lab -e "$1" 2>/dev/null; }
for _ in $(seq 1 90); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(M 'SELECT 1')" = "1" ] || { echo "중단: MySQL 이 안 뜹니다" >&2; exit 2; }

M "CREATE TABLE payments(
     id BIGINT AUTO_INCREMENT PRIMARY KEY,
     request_id VARCHAR(64) NOT NULL,
     amount INT NOT NULL,
     UNIQUE KEY uq_req (request_id)) ENGINE=InnoDB;"
docker exec "$C" sh -c ": > $EF"

# KINTO 의 결제 처리 3단계를 그대로 옮긴다. 2단계(결제 대행사 호출)가 0.25초 sleep 이다.
# 실제 데드락 출력의 ACTIVE 6~7 sec 가 그 왕복이었고, 이 구간이 없으면 갭 락을 쥐는
# 시간이 밀리초라 같은 코드로도 데드락이 잘 안 난다.
run_round(){ # $1=seq|uuid $2=회차
  local kind="$1" r="$2" keys=() i
  for i in $(seq 1 "$CONC"); do
    if [ "$kind" = seq ]; then keys+=("ITEM001-20260801-$(printf '%07d' $((r*100+i)))")
    else keys+=("$(uuidgen)"); fi
  done
  docker exec -i "$C" bash -s -- "$EF" "${keys[@]}" <<'INNER'
ef="$1"; shift
i=0
for k in "$@"; do
  i=$((i+1))
  (
    e="/tmp/e.$$.$i"
    if mysql -uroot -plab lab -e "
        SET SESSION innodb_lock_wait_timeout=5;
        START TRANSACTION;
        SELECT id FROM payments WHERE request_id='$k' FOR UPDATE;
        SELECT SLEEP(0.25);
        INSERT INTO payments(request_id,amount) VALUES('$k',1000);
        COMMIT;" >/dev/null 2>"$e"; then
      r=OK
    elif grep -q 'ERROR 1213' "$e"; then r=DEADLOCK
    elif grep -q 'ERROR 1205' "$e"; then r=LOCKWAIT
    else r="OTHER $(head -c 80 "$e" | tr -d '\n')"; fi
    # 한 줄씩만 붙인다. 짧은 줄의 append 는 원자적이라 여덟이 동시에 써도 안 섞인다.
    echo "$r" >> "$ef"
    rm -f "$e"
  ) &
done
wait
INNER
}
# grep -c 는 **줄**을 센다. 여덟 프로세스가 같은 파일에 >> 로 붙이면 두 에러가 한 줄에
# 섞여 들어가고, 그러면 2건이 1건으로 세어진다. 1차 측정에서 실패 175건 중 144건만
# 잡힌 이유가 이것이다. 발생 **횟수**로 센다.
# 트랜잭션마다 한 줄씩 결과를 남기므로 그 줄을 센다. 성공+데드락+기타가 시도 수와
# 같은지로 계측 자체를 검산할 수 있다.
tally(){ docker exec "$C" sh -c "grep -c '^$1' $EF" 2>/dev/null | tr -d ' ' | head -1; }
pct(){ python3 -c "print(f'{$1*100/$2:.1f}%')"; }

preload(){ # 무작위 UUID 로 채워 갭을 잘게 쪼갠다
  M "SET SESSION cte_max_recursion_depth=$((PRELOAD+10));
     INSERT INTO payments(request_id,amount)
     SELECT CONCAT('seed-', UUID()), 1 FROM (
       WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<$PRELOAD)
       SELECT n FROM s) t;" >/dev/null
  local got; got=$(M "SELECT COUNT(*) FROM payments")
  if [ "${got:-0}" -ne "$PRELOAD" ]; then
    echo "중단: 사전 적재가 ${got:-0}행입니다(기대 $PRELOAD). 갭이 잘다는 조건이 안 섰습니다" >&2
    docker rm -f "$C" >/dev/null; exit 2
  fi
}

echo "table_state,kind,deadlocks,inserted,attempted" > "$OUT/gap-key-distribution.csv"
{
echo "# 키 분포와 테이블 크기가 데드락을 정하는가"
echo "# MySQL $(M 'SELECT VERSION()') · 동시 $CONC · 각 $ROUNDS 회차 · 트랜잭션 안 0.25초 대기"
echo "# 데드락은 클라이언트가 받은 ERROR 1213 을 셉니다. 성공은 실제로 들어간 행 수입니다."
echo
printf "  %-9s %-7s %-12s %-12s %s\n" "테이블" "키" "데드락" "들어간 행" "데드락률"
for state in empty preload; do
  M "TRUNCATE payments" >/dev/null
  [ "$state" = preload ] && preload
  SEED=$(M "SELECT COUNT(*) FROM payments")
  for kind in seq uuid; do
    docker exec "$C" sh -c ": > $EF"
    for r in $(seq 1 "$ROUNDS"); do run_round "$kind" "$r"; done
    DL=$(tally DEADLOCK); LW=$(tally LOCKWAIT); OKC=$(tally OK); OTH=$(tally OTHER)
    NOW=$(M "SELECT COUNT(*) FROM payments"); INS=$((NOW-SEED)); N=$((ROUNDS*CONC))
    printf "  %-9s %-7s %-12s %-12s %s\n" \
      "$([ $state = empty ] && echo '비었음' || echo "$((SEED/1000))천행")" \
      "$([ $kind = seq ] && echo '순차' || echo 'UUID')" \
      "$DL / $N" "$INS / $N" "$(pct $DL $N)"
    echo "$state,$kind,$DL,$INS,$N" >> "$OUT/gap-key-distribution.csv"
    # 계측 검산. 넷의 합이 시도 수와 다르면 결과를 못 받은 트랜잭션이 있다는 뜻이다.
    SUM=$((OKC+DL+LW+OTH))
    [ "$SUM" -ne "$N" ] && echo "      주의: 결과를 받은 트랜잭션이 $SUM 건입니다(시도 $N). 이 줄은 인용하면 안 됩니다"
    [ "$OKC" -ne "$INS" ] && echo "      주의: OK 가 $OKC 건인데 들어간 행은 $INS 행입니다"
    [ "${LW:-0}" -gt 0 ] && echo "      락 대기 타임아웃 $LW 건이 섞였습니다"
    [ "${OTH:-0}" -gt 0 ] && echo "      기타 실패 $OTH 건: $(docker exec "$C" sh -c "grep -m1 '^OTHER' $EF" 2>/dev/null | cut -c1-80)"
    M "DELETE FROM payments WHERE request_id NOT LIKE 'seed-%'" >/dev/null
  done
done
echo
echo "  마지막 조건의 결과 분포:"
docker exec "$C" sh -c "cut -d' ' -f1 $EF | sort | uniq -c" 2>/dev/null | sed 's/^/    /'
} 2>&1 | tee "$OUT/exp5-key-distribution.txt"
docker rm -f "$C" >/dev/null 2>&1
