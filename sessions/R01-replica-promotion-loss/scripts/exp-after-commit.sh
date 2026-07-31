#!/usr/bin/env bash
# README 의 "못 한 것" 세 항목을 잰다.
#
#   1) AFTER_COMMIT 비교. AFTER_SYNC 와 무엇이 다른가
#   2) 반동기의 평상시 지연 비용. 커밋 자체의 소요를 직접 잰다
#   3) 복구. 옛 소스에서 차집합을 뽑아 병합하는 경로를 실행한다
#
# 1번의 핵심은 "다른 클라이언트가 이미 읽은 값이 사라지는" 시나리오다.
#   AFTER_SYNC   : 복제본이 ack 한 뒤에 소스가 엔진에 커밋한다.
#                  따라서 다른 클라이언트가 읽을 수 있게 된 값은 이미 복제본에 있다.
#   AFTER_COMMIT : 소스가 먼저 엔진에 커밋하고 그 뒤에 ack 를 기다린다.
#                  ack 를 기다리는 그 창에서 다른 클라이언트가 그 값을 읽을 수 있고,
#                  그 순간 소스가 죽으면 읽힌 값이 사라진다.
#
# 그래서 1번은 "관찰자"를 하나 더 둔다. 커밋 직후 그 값을 읽는 세션이다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NET="${NET:-r01-repl-net}"
OUT="$ROOT/results"; mkdir -p "$OUT"
S(){ docker exec r01-source  mysql -uroot -plab -N -B -e "$1" 2>/dev/null; }
R(){ docker exec r01-replica mysql -uroot -plab -N -B -e "$1" 2>/dev/null; }
log(){ echo "[$(date '+%H:%M:%S')] $*"; }

wait_up(){ for _ in $(seq 1 90); do [ "$(S 'SELECT 1')" = "1" ] && return 0; sleep 2; done; return 1; }

# ── 반동기 설정 ─────────────────────────────────────────────────────────
setup_semi(){ # $1=AFTER_SYNC|AFTER_COMMIT
  S "INSTALL PLUGIN rpl_semi_sync_source SONAME 'semisync_source.so';" 2>/dev/null || true
  R "INSTALL PLUGIN rpl_semi_sync_replica SONAME 'semisync_replica.so';" 2>/dev/null || true
  S "SET GLOBAL rpl_semi_sync_source_enabled=1;
     SET GLOBAL rpl_semi_sync_source_timeout=8000;
     SET GLOBAL rpl_semi_sync_source_wait_point=$1;"
  R "SET GLOBAL rpl_semi_sync_replica_enabled=1; STOP REPLICA IO_THREAD; START REPLICA IO_THREAD;"
  sleep 3
  echo "  wait_point = $(S "SELECT @@rpl_semi_sync_source_wait_point")"
  echo "  반동기 상태 = $(S "SHOW STATUS LIKE 'Rpl_semi_sync_source_status'" | awk '{print $2}')"
}

# ── 1) 커밋 지연을 직접 잰다 ────────────────────────────────────────────
commit_latency(){ # $1=라벨
  # 커밋 100건의 소요를 밀리초로 잰다. 커밋 간격이 아니라 커밋 자체다.
  docker exec r01-source bash -c "
    for i in \$(seq 1 100); do
      s=\$(date +%s%N)
      mysql -uroot -plab -N -B -e \"INSERT INTO spoon.sponsor (seq, user_id, amount) VALUES (0, 1, 1000)\" >/dev/null 2>&1
      e=\$(date +%s%N)
      echo \$(( (e-s)/1000 ))
    done" 2>/dev/null | python3 -c "
import sys,statistics as st
v=sorted(int(x) for x in sys.stdin if x.strip().isdigit())
if not v: print('  [$1] 표본 없음'); raise SystemExit
print(f'  [$1] 커밋 100건 중앙값 {st.median(v)/1000:.2f}ms, p95 {v[int(len(v)*0.95)]/1000:.2f}ms, 최대 {v[-1]/1000:.2f}ms')"
}

{
echo "# AFTER_COMMIT 대조, 반동기의 평상시 지연, 복구 경로"
echo

wait_up || { echo "중단: r01-source 가 쿼리를 받지 못합니다" >&2; exit 2; }
echo "# MySQL $(S 'SELECT VERSION()')"
echo

# ── A) 평상시 커밋 지연 ─────────────────────────────────────────────────
echo "## 1) 반동기의 평상시 커밋 지연"
echo "  커밋 간격이 아니라 커밋 문장 자체의 왕복을 잽니다."
echo
S "SET GLOBAL rpl_semi_sync_source_enabled=0" 2>/dev/null || true
sleep 1
commit_latency "비동기"
setup_semi AFTER_SYNC >/dev/null
commit_latency "반동기 AFTER_SYNC"
setup_semi AFTER_COMMIT >/dev/null
commit_latency "반동기 AFTER_COMMIT"
echo
echo "  두 노드가 같은 호스트의 컨테이너라 이 왕복은 실제 가용영역 사이보다 짧습니다."
echo "  절대값이 아니라 세 조건의 상대 비교로만 읽어야 합니다."
echo

# ── B) AFTER_COMMIT 에서 읽힌 값이 사라지는가 ───────────────────────────
echo "## 2) AFTER_COMMIT: 다른 클라이언트가 읽은 값이 사라지는가"
echo
for WP in AFTER_SYNC AFTER_COMMIT; do
  echo "### wait_point = $WP"
  # 환경을 되돌린다.
  docker start r01-source >/dev/null 2>&1 || true
  wait_up || { echo "  소스가 다시 뜨지 않았습니다"; continue; }
  docker network connect "$NET" r01-replica >/dev/null 2>&1 || true
  R "START REPLICA" >/dev/null 2>&1 || true
  sleep 3
  S "DROP TABLE IF EXISTS spoon.obs; CREATE TABLE spoon.obs (id INT AUTO_INCREMENT PRIMARY KEY, tag VARCHAR(20)) ENGINE=InnoDB" >/dev/null
  sleep 2
  setup_semi "$WP"

  # 복제망을 끊는다. 이제 ack 가 오지 않는다.
  docker network disconnect "$NET" r01-replica >/dev/null 2>&1 || true
  sleep 1

  # 커밋을 던지고(ack 를 못 받아 매달린다) 그동안 다른 세션이 그 값을 읽는지 본다.
  docker exec -d r01-source bash -c \
    "mysql -uroot -plab -N -B -e \"INSERT INTO spoon.obs (tag) VALUES ('probe')\" > /tmp/ins.txt 2>&1"
  sleep 2
  SEEN=$(S "SELECT COUNT(*) FROM spoon.obs WHERE tag='probe'")
  echo "  커밋이 매달린 상태에서 다른 세션이 읽은 행 수 = ${SEEN:-?}"
  if [ "${SEEN:-0}" -gt 0 ]; then
    echo "  → 이미 읽혔습니다. 여기서 소스가 죽으면 읽힌 값이 사라집니다."
  else
    echo "  → 아직 안 보입니다. 복제본이 ack 하기 전에는 다른 세션도 못 읽습니다."
  fi

  # 소스를 죽이고 복제본을 승격해 그 값이 남아 있는지 본다.
  docker kill r01-source >/dev/null 2>&1
  sleep 2
  R "STOP REPLICA; RESET REPLICA ALL" >/dev/null 2>&1
  SURV=$(R "SELECT COUNT(*) FROM spoon.obs WHERE tag='probe'")
  echo "  승격한 복제본에 남은 행 수 = ${SURV:-?}"
  if [ "${SEEN:-0}" -gt 0 ] && [ "${SURV:-0}" -eq 0 ]; then
    echo "  → **읽힌 값이 사라졌습니다.** AFTER_COMMIT 의 lossy 구간입니다."
  elif [ "${SEEN:-0}" -eq 0 ]; then
    echo "  → 읽히지 않았으므로 사라질 것도 없습니다. AFTER_SYNC 가 막는 자리입니다."
  else
    echo "  → 읽혔고 살아남았습니다."
  fi
  echo
done

# ── C) 복구 경로 ────────────────────────────────────────────────────────
echo "## 3) 복구: 옛 소스에서 차집합을 뽑아 병합한다"
echo
echo "  먼저 유실을 만든다. 비동기로 두고 복제망을 끊은 채 쓰기를 넣은 뒤 소스를 죽인다."
docker start r01-source >/dev/null 2>&1
wait_up || { echo "  옛 소스가 다시 뜨지 않아 복구를 못 합니다"; exit 0; }
docker network connect "$NET" r01-replica >/dev/null 2>&1 || true
S "SET GLOBAL rpl_semi_sync_source_enabled=0" >/dev/null 2>&1
R "STOP REPLICA; RESET REPLICA ALL" >/dev/null 2>&1
R "CHANGE REPLICATION SOURCE TO SOURCE_HOST='source', SOURCE_USER='root', SOURCE_PASSWORD='lab',
     SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1; START REPLICA" >/dev/null 2>&1
sleep 4
BASE=$(R "SELECT COUNT(*) FROM spoon.sponsor")
echo "  분단 직전 양쪽 행 수 = $(S "SELECT COUNT(*) FROM spoon.sponsor") / ${BASE:-?}"
docker network disconnect "$NET" r01-replica >/dev/null 2>&1 || true
sleep 1
# 복제본에 못 간 쓰기 50건. 비동기라 소스는 바로 성공을 돌려준다.
docker exec r01-source bash -c "for i in \$(seq 1 50); do
  mysql -uroot -plab -N -B -e \"INSERT INTO spoon.sponsor (seq, user_id, amount) VALUES (9999, 7, 5000)\" >/dev/null 2>&1
done" 2>/dev/null
echo "  분단 중 소스에만 들어간 쓰기 50건 (클라이언트는 전부 성공을 받았다)"
docker kill r01-source >/dev/null 2>&1
sleep 2
R "STOP REPLICA; RESET REPLICA ALL" >/dev/null 2>&1
echo "  소스 강제 종료 후 복제본을 승격했다"
docker start r01-source >/dev/null 2>&1
wait_up || { echo "  옛 소스가 다시 뜨지 않아 복구를 못 합니다"; exit 0; }
OLD=$(S "SELECT COUNT(*) FROM spoon.sponsor")
NEW=$(R "SELECT COUNT(*) FROM spoon.sponsor")
echo "  옛 소스 행 수 = ${OLD:-?}, 승격된 복제본 행 수 = ${NEW:-?}"
GAP=$(( ${OLD:-0} - ${NEW:-0} ))
echo "  차이 = ${GAP}행 (이것이 유실량입니다)"
if [ "$GAP" -gt 0 ]; then
  echo "  옛 소스에만 있는 id 를 뽑아 새 소스로 옮깁니다."
  S "SELECT id, seq, user_id, amount FROM spoon.sponsor ORDER BY id DESC LIMIT $GAP" > /tmp/r01-gap.tsv 2>/dev/null
  echo "  뽑은 행 수 = $(wc -l < /tmp/r01-gap.tsv | tr -d ' ')"
  # 새 소스에 없는 것만 넣는다. id 를 그대로 쓰면 승격 후 새로 들어온 행과 부딪힐 수 있다.
  while IFS=$'\t' read -r id seq uid amt; do
    [ -z "${id:-}" ] && continue
    docker exec r01-replica mysql -uroot -plab -N -B \
      -e "INSERT IGNORE INTO spoon.sponsor (id, seq, user_id, amount) VALUES ($id, $seq, $uid, $amt)" 2>/dev/null
  done < /tmp/r01-gap.tsv
  AFTER=$(R "SELECT COUNT(*) FROM spoon.sponsor")
  echo "  병합 후 새 소스 행 수 = ${AFTER:-?} (병합 전 ${NEW:-?})"
  echo "  회수한 행 = $(( ${AFTER:-0} - ${NEW:-0} ))행 / 유실 ${GAP}행"
  echo
  echo "  **이 경로가 성립하는 조건이 좁습니다.** 옛 소스가 다시 떠야 하고, id 가 겹치지"
  echo "  않아야 하고, 그 사이 새 소스에 들어온 쓰기와 순서가 뒤섞여도 되는 데이터여야"
  echo "  합니다. 후원 정산처럼 순서가 의미를 갖는 데이터에서는 이 병합이 답이 아닙니다."
else
  echo "  유실이 없어 병합할 것이 없습니다."
fi
echo
echo "## 정리"
echo "  각 조건 1회 실행입니다."
} 2>&1 | tee "$OUT/exp-after-commit.txt"
