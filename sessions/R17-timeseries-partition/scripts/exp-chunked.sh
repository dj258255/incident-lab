#!/usr/bin/env bash
# 실험 6: 잘게 쪼갠 DELETE 루프.
# 한 방 DELETE에서는 히스토리 리스트가 3을 넘지 않았다. 공식 문서가 경고하는 조건은
# "소량 배치 삽입·삭제가 비슷한 속도로 반복"이다. 청크 삭제가 정확히 그 패턴이다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/../../.venv/bin/python"
OUT="$ROOT/results"
SQL() { docker exec r17-mysql mysql -uroot -plab spoon -N -B -e "$1" 2>/dev/null; }

"$PY" "$ROOT/scripts/poll.py" 300 "$OUT/chunked-poll.csv" &
POLL=$!
"$PY" "$ROOT/scripts/oltp.py" watch_log_plain 300 "$OUT/chunked-oltp.csv" &
OLTP=$!
sleep 10

date +%s.%N > "$OUT/chunked-start-ts.txt"
CHUNKS=0
while :; do
  AFFECTED=$(SQL "DELETE FROM watch_log_plain WHERE created_at < '2026-07-28' LIMIT 10000; SELECT ROW_COUNT();" | tail -1)
  CHUNKS=$((CHUNKS+1))
  [ "$AFFECTED" -lt 10000 ] && break
done
date +%s.%N > "$OUT/chunked-done-ts.txt"
echo "청크 ${CHUNKS}개 실행" | tee "$OUT/chunked-elapsed.txt"

wait $OLTP $POLL
SQL "SELECT COUNT(*) FROM watch_log_plain;" | tail -1 >> "$OUT/chunked-elapsed.txt"
