#!/usr/bin/env bash
# README 의 "못 한 것" 하나를 잡는다.
#
#   AFTER_COMMIT 대조는 관찰자 한 명, 커밋 한 건입니다
#   "읽힌 값이 사라진다는 것은 보였지만 부하 아래에서 몇 건이 그렇게 되는지는
#    재지 않았습니다."
#
# 한 건짜리 관측은 "이런 일이 가능하다"까지만 말한다. 실제 위험의 크기는 창의 길이와
# 그 창에 들어오는 읽기의 양이 정한다. 그래서 이렇게 잰다.
#
#   쓰기 N 건을 계속 던지고(복제망이 끊겨 있어 전부 매달린다)
#   관찰자 여럿이 그동안 읽은 행을 전부 기록한다
#   소스를 죽이고 복제본을 승격해, 읽혔던 행 중 몇 건이 사라졌는지 센다
#
# AFTER_SYNC 와 AFTER_COMMIT 을 같은 방식으로 돌려 나란히 놓는다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
WRITERS=${WRITERS:-8}
OBSERVERS=${OBSERVERS:-4}
WINDOW=${WINDOW:-12}

S(){ docker exec r01-source mysql -uroot -plab -N -B -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }
R(){ docker exec r01-replica mysql -uroot -plab -N -B -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }
NET=$(docker inspect r01-source -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')

wait_up(){ for _ in $(seq 1 90); do [ "$(S 'SELECT 1')" = "1" ] && return 0; sleep 2; done; return 1; }

setup_semi(){ # $1=AFTER_SYNC|AFTER_COMMIT
  S "INSTALL PLUGIN rpl_semi_sync_source SONAME 'semisync_source.so'" >/dev/null 2>&1 || true
  R "INSTALL PLUGIN rpl_semi_sync_replica SONAME 'semisync_replica.so'" >/dev/null 2>&1 || true
  S "SET GLOBAL rpl_semi_sync_source_enabled=1;
     SET GLOBAL rpl_semi_sync_source_wait_point='$1';
     SET GLOBAL rpl_semi_sync_source_timeout=600000" >/dev/null 2>&1
  R "SET GLOBAL rpl_semi_sync_replica_enabled=1; STOP REPLICA IO_THREAD; START REPLICA IO_THREAD" >/dev/null 2>&1
  sleep 2
}

run_case(){ # $1=wait_point
  local WP="$1"
  echo
  echo "### wait_point = $WP"

  # 환경 되돌리기
  docker start r01-source >/dev/null 2>&1 || true
  wait_up || { echo "  소스가 다시 뜨지 않았습니다"; return 1; }
  docker network connect "$NET" r01-replica >/dev/null 2>&1 || true
  R "START REPLICA" >/dev/null 2>&1 || true
  sleep 3
  S "DROP TABLE IF EXISTS spoon.obs;
     CREATE TABLE spoon.obs (id INT AUTO_INCREMENT PRIMARY KEY, tag VARCHAR(20)) ENGINE=InnoDB" >/dev/null
  sleep 2
  setup_semi "$WP"

  # 복제망을 끊는다. 이제 ack 가 오지 않는다.
  docker network disconnect "$NET" r01-replica >/dev/null 2>&1 || true
  sleep 1

  # 쓰기 여럿. 각각 커밋에서 매달린다.
  for w in $(seq 1 "$WRITERS"); do
    docker exec -d r01-source bash -c \
      "for i in \$(seq 1 50); do
         mysql -uroot -plab -N -B -e \"INSERT INTO spoon.obs (tag) VALUES ('w$w')\" >/dev/null 2>&1
       done"
  done

  # 관찰자 여럿. 그동안 보인 id 를 전부 적는다.
  docker exec r01-source bash -c "rm -f /tmp/seen-*.txt" >/dev/null 2>&1 || true
  for o in $(seq 1 "$OBSERVERS"); do
    docker exec -d r01-source bash -c \
      "END=\$(( \$(date +%s) + $WINDOW ))
       while [ \$(date +%s) -lt \$END ]; do
         mysql -uroot -plab -N -B -e 'SELECT id FROM spoon.obs' >> /tmp/seen-$o.txt 2>/dev/null
         sleep 0.2
       done"
  done
  sleep "$WINDOW"
  sleep 2

  SEEN=$(docker exec r01-source bash -c "cat /tmp/seen-*.txt 2>/dev/null | sort -n | uniq | wc -l" | tr -d ' ')
  docker exec r01-source bash -c "cat /tmp/seen-*.txt 2>/dev/null | sort -n | uniq" > "$OUT/seen-${WP}.txt" 2>/dev/null || true
  ONSRC=$(S "SELECT COUNT(*) FROM spoon.obs")
  echo "  매달린 창 ${WINDOW}초 동안"
  echo "    소스에 들어간 행 = ${ONSRC:-?}"
  echo "    관찰자 ${OBSERVERS}명이 실제로 읽은 서로 다른 행 = ${SEEN:-0}"

  # 소스를 죽이고 복제본을 승격한다.
  docker kill r01-source >/dev/null 2>&1 || true
  docker network connect "$NET" r01-replica >/dev/null 2>&1 || true
  sleep 2
  R "STOP REPLICA; RESET REPLICA ALL" >/dev/null 2>&1 || true
  R "SET GLOBAL read_only=0; SET GLOBAL super_read_only=0" >/dev/null 2>&1 || true
  SURVIVED=$(R "SELECT COUNT(*) FROM spoon.obs")
  echo "    승격 후 복제본에 남은 행 = ${SURVIVED:-0}"
  LOST=$(( ${SEEN:-0} - ${SURVIVED:-0} ))
  [ "$LOST" -lt 0 ] && LOST=0
  echo "    **읽혔는데 사라진 행 = ${LOST}**"
  echo "$WP,${ONSRC:-0},${SEEN:-0},${SURVIVED:-0},$LOST" >> "$OUT/after-commit-load.csv"
}

{
echo "# AFTER_COMMIT 을 부하 아래에서"
echo "# 쓰기 ${WRITERS}개, 관찰자 ${OBSERVERS}명, 창 ${WINDOW}초. 각 조건 1회 실행입니다."
wait_up || { echo "중단: r01-source 가 쿼리를 받지 못합니다" >&2; exit 2; }
echo "# MySQL $(S 'SELECT VERSION()')"
: > "$OUT/after-commit-load.csv"
echo "wait_point,on_source,seen_by_observers,survived,lost" >> "$OUT/after-commit-load.csv"

run_case AFTER_SYNC
run_case AFTER_COMMIT

echo
echo "## 정리"
column -s, -t "$OUT/after-commit-load.csv" 2>/dev/null || cat "$OUT/after-commit-load.csv"
echo
echo "  AFTER_SYNC 는 ack 를 받기 전에는 엔진에 커밋하지 않으므로 관찰자가 못 봅니다."
echo "  못 본 것은 사라져도 아무도 모릅니다. AFTER_COMMIT 은 먼저 커밋하고 ack 를"
echo "  기다리므로 그 사이 관찰자가 봅니다. 본 것이 사라지는 것이 이 설정의 대가입니다."
echo "  한 건짜리 관측은 '가능하다'까지이고, 위 표의 마지막 열이 그 크기입니다."
echo
echo "  환경을 되돌립니다."
docker start r01-source >/dev/null 2>&1 || true
} 2>&1 | tee "$OUT/exp-after-commit-load.txt"
