#!/usr/bin/env bash
# 프라이머리 단일 노드에서 서브트랜잭션 절벽의 두 경계를 잰다.
#
#   사용법: ./run-primary.sh <라벨> <서브트랜잭션수> [리더수] [측정초]
#
# 경계가 둘이다.
#   1) 64      : PGPROC_MAX_CACHED_SUBXIDS. 넘으면 리더가 pg_subtrans를 보기 시작한다
#   2) 65,536  : SLRU 32페이지 x 페이지당 2,048 XID. 넘으면 그 조회가 빗나간다
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
LABEL="$1"; NSUB="$2"; CLIENTS="${3:-64}"; DUR="${4:-20}"
P() { docker exec a19-primary psql -U postgres -d spoon -qAt -c "$1"; }

P "SELECT pg_stat_reset_shared('slru')" >/dev/null
# 16 에는 이 GUC 가 없다. SHOW 로 물으면 에러 문자열이 그대로 값에 들어가므로
# pg_settings 에서 읽고 없으면 "없음(16 이하)"으로 적는다.
BUFS=$(P "SELECT COALESCE((SELECT setting FROM pg_settings WHERE name='subtransaction_buffers'),'없음(16 이하, 32 고정)')")

if [ "$NSUB" -gt 0 ]; then
  bash "$ROOT/scripts/p-long-tx.sh" "$NSUB" $((DUR + 40)) 500000 > "$OUT/$LABEL-longtx.log" 2>&1 &
  LTX=$!
  # DO 블록이 서브트랜잭션을 다 만들고 pg_sleep에 들어갈 때까지 기다린다.
  for _ in $(seq 1 600); do
    [ "$(P "SELECT count(*) FROM pg_stat_activity WHERE query LIKE 'SELECT pg_sleep%'")" = "1" ] && break
    sleep 0.5
  done
  # XID 카운터를 서브트랜잭션 범위 너머로 민다. 이게 없으면 리더 스냅샷의
  # xmax가 서브트랜잭션 XID보다 작아 XidInMVCCSnapshot이 즉시 끝나 버린다.
  TOP=$(P "SELECT backend_xid FROM pg_stat_activity WHERE query LIKE 'SELECT pg_sleep%'")
  TARGET=$((TOP + NSUB + 2000))
  for _ in $(seq 1 60); do
    [ "$(P "SELECT txid_current()")" -ge "$TARGET" ] && break
    docker exec a19-primary pgbench -U postgres -d spoon -n -f /scripts/burn.sql -c 8 -j 4 -T 2 >/dev/null 2>&1
  done
else
  LTX=""
fi

# 대기 샘플 파일을 비우고 시작한다. 이걸 빼면 반복 측정에서 회차마다 누적돼
# 회차별 비중을 갈라낼 수 없다(A19 4회 측정에서 235 → 464 → 686 → 920으로 늘었다).
: > "$OUT/$LABEL-waits.txt"
( END=$(( $(date +%s) + DUR ))
  while [ "$(date +%s)" -lt "$END" ]; do
    P "SELECT coalesce(wait_event_type,'CPU')||'/'||coalesce(wait_event,'-') FROM pg_stat_activity WHERE state='active' AND query LIKE 'SELECT amount%'" >> "$OUT/$LABEL-waits.txt"
    sleep 0.2
  done ) &
SAMP=$!
docker exec a19-primary pgbench -U postgres -d spoon -n -M prepared \
  -f /scripts/p-reader.sql -c "$CLIENTS" -j 4 -T "$DUR" -P 5 > "$OUT/$LABEL-reader.txt" 2>&1
wait $SAMP 2>/dev/null || true
SL=$(P "SELECT blks_hit||' '||blks_read FROM pg_stat_slru WHERE lower(name) IN ('subtransaction','subtrans')")
echo "$SL" > "$OUT/$LABEL-slru.txt"
[ -n "$LTX" ] && { P "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE 'SELECT pg_sleep%'" >/dev/null; wait $LTX 2>/dev/null; }

TPS=$(grep -E "^tps = " "$OUT/$LABEL-reader.txt"|head -1|awk '{print $3}')
LAT=$(grep -E "^latency average" "$OUT/$LABEL-reader.txt"|awk '{print $4}')
SW=$(grep -c "SubtransSLRU" "$OUT/$LABEL-waits.txt" 2>/dev/null || echo 0)
TOTW=$(wc -l < "$OUT/$LABEL-waits.txt" 2>/dev/null || echo 0)
printf '%-13s 서브TX=%-7s 버퍼=%-6s tps=%-12s 지연=%-7sms SLRU(hit read)=%-18s SubtransSLRU대기=%s/%s\n' \
  "$LABEL" "$NSUB" "$BUFS" "${TPS:-?}" "${LAT:-?}" "$SL" "$SW" "$TOTW"
