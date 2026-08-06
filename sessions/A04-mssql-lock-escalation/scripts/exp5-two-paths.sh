#!/usr/bin/env bash
# 실험 5. 같은 행 수인데 통계가 없으면 승격한다.
#
# 실험 1의 경계(테이블 락 6,250개)를 다시 재려다 같은 6,231행이 어떤 때는 승격하고
# 어떤 때는 안 하는 것을 봤다. 다른 것은 통계뿐이었다.
#
# 처음에는 "통계가 없으면 승격이 아니라 처음부터 테이블 락을 잡는다"고 적었다.
# 확장 이벤트가 0건으로 보였기 때문이다. 그런데 5회 반복하니 5회 모두 이벤트가
# 1건씩 났다. 0건은 재현되지 않는 관측이었고 결론을 철회했다.
#
# 반복이 말해 주는 것은 다르다. 임계값 6,250 자체는 그대로인데, 통계가 없으면
# **같은 행 수에 락을 더 많이 잡아** 그 선을 넘는다. 배치 크기를 맞춰 두어도
# 통계가 낡으면 그 크기가 지키던 여유가 사라진다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
N=${N:-6231}

wait_ready || exit 2

# reset_table 은 통계를 만들어 준다. 통계 없는 상태를 보려면 만들기 전 상태가 필요하다.
load_without_stats(){
  local rows=$1 got
  Q "IF DB_ID('$DB') IS NULL CREATE DATABASE [$DB]" >/dev/null
  QD "SET NOCOUNT ON;
      DROP TABLE IF EXISTS $TBL;
      CREATE TABLE $TBL (account_id INT NOT NULL PRIMARY KEY,
                         currency_type TINYINT NOT NULL, balance BIGINT NOT NULL);
      WITH n AS (SELECT TOP ($rows) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
                 FROM sys.all_objects a CROSS JOIN sys.all_objects b)
      INSERT INTO $TBL (account_id, currency_type, balance) SELECT i, i % 3, 100000 FROM n;" >/dev/null
  got=$(num "$(QD "SELECT COUNT(*) FROM $TBL")")
  [ "$got" = "$rows" ] || { echo "중단: 적재가 ${got}행입니다(기대 ${rows})" >&2; return 2; }
}

probe(){  # "승격여부,KEY,PAGE,테이블락,이벤트수,승격시점락수"
  xe_reset
  local shape cnt at
  shape=$(lock_shape "$1")
  cnt=$(xe_count)
  at=$(xe_events | head -1 | cut -d'|' -f1); at=${at:--}
  echo "${shape},${cnt},${at}"
}

ROUNDS=${ROUNDS:-5}

{
echo "# 실험 5. 테이블 락이 잡힌 것과 승격이 일어난 것은 다른 사건이다"
echo
echo "  같은 ${N}행 갱신을 통계 유무만 바꿔 각 ${ROUNDS}회 돌립니다."
echo "  회차마다 테이블을 새로 적재하므로 조건 사이가 새지 않습니다."
echo "  dm_tran_locks 의 모양과 확장 이벤트의 발생 여부를 함께 봅니다."
echo
: > "$OUT/two-paths.csv"
echo "run,condition,table_x_lock,key_locks,page_locks,table_locks,escalation_events,escalated_lock_count" >> "$OUT/two-paths.csv"

printf "  %-8s %-22s %-10s %-12s %-12s %s\n" "회차" "조건" "KEY락" "테이블락" "승격 이벤트" "승격 시점 락수"
NS_SHAPES=""; WS_SHAPES=""
for r in $(seq 1 "$ROUNDS"); do
  load_without_stats 200000 || exit 2
  IFS=, read -r e1 k1 p1 t1 v1 a1 <<<"$(probe "$N")"
  printf "  %-8s %-22s %-10s %-12s %-12s %s\n" "$r" "통계 없음" "$k1" "$t1" "${v1}건" "$a1"
  echo "$r,no_stats,$e1,$k1,$p1,$t1,$v1,$a1" >> "$OUT/two-paths.csv"
  NS_SHAPES="$NS_SHAPES $e1/$v1"

  QD "UPDATE STATISTICS $TBL WITH FULLSCAN" >/dev/null
  IFS=, read -r e2 k2 p2 t2 v2 a2 <<<"$(probe "$N")"
  printf "  %-8s %-22s %-10s %-12s %-12s %s\n" "$r" "통계 있음" "$k2" "$t2" "${v2}건" "$a2"
  echo "$r,with_stats,$e2,$k2,$p2,$t2,$v2,$a2" >> "$OUT/two-paths.csv"
  WS_SHAPES="$WS_SHAPES $e2/$v2"
done

echo
NS_UNIQ=$(echo $NS_SHAPES | tr ' ' '\n' | sort -u | tr '\n' ' ')
WS_UNIQ=$(echo $WS_SHAPES | tr ' ' '\n' | sort -u | tr '\n' ' ')
echo "  통계 없음 회차별 (테이블X락/승격이벤트): ${NS_SHAPES}"
echo "  통계 있음 회차별 (테이블X락/승격이벤트): ${WS_SHAPES}"
echo
if [ "$(echo $WS_UNIQ | wc -w)" -eq 1 ] && [ "$WS_UNIQ" = "0/0 " ]; then
  echo "  **통계가 있으면 ${ROUNDS}회 모두 같습니다.** ${N}행은 행 락 ${k2}개를 잡고 승격하지 않습니다."
else
  echo "  **통계가 있어도 회차마다 갈립니다(${WS_UNIQ}). 이 조건은 인용하면 안 됩니다.**"
fi
if [ "$(echo $NS_UNIQ | wc -w)" -gt 1 ]; then
  echo "  **통계가 없으면 회차마다 갈립니다(${NS_UNIQ}).** 같은 배치, 같은 행 수인데"
  echo "  어떤 회차는 행 락을 잡고 어떤 회차는 테이블 락을 잡습니다."
else
  echo "  통계가 없을 때는 ${ROUNDS}회 모두 ${NS_UNIQ} 였습니다."
fi
echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  임계값 자체는 안 움직입니다. 두 조건 다 승격이 일어날 때는 락 6,2xx개에서"
echo "  일어납니다. 움직이는 것은 **같은 행 수에 락을 몇 개 잡느냐** 입니다."
echo
echo "  통계가 있으면 ${N}행에 락 6,249개를 잡고 선 안쪽에 머뭅니다."
echo "  통계가 없으면 같은 ${N}행에 락을 더 잡아 선을 넘고 승격합니다."
echo
echo "  운영으로 옮기면 이렇습니다. 배치 크기를 5,000행으로 정해 두어도 그 숫자가"
echo "  지키던 여유는 통계가 낡으면 사라질 수 있습니다. 대량 보정 전에 통계를"
echo "  갱신하는 것이 배치 크기를 정하는 것만큼 중요합니다."
echo
echo "  덧붙여, 테이블 락이 걸렸다고 전부 승격은 아닙니다. 실험 4의 100만행 전체"
echo "  갱신은 페이지 락 2,718개를 잡고 승격 이벤트가 0건이었습니다. 옵티마이저가"
echo "  락 단위를 먼저 고르고, 승격은 그중 행 락을 고른 경우에만 일어나는 뒷일입니다."
echo "  dm_tran_locks 만 보면 그 구분이 안 보이므로 확장 이벤트를 함께 봐야 합니다."
} 2>&1 | tee "$OUT/exp5-two-paths.txt"
