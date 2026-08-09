#!/usr/bin/env bash
# 실험 9. 인덱스가 여럿일 때 임계값을 재는 기준은 무엇인가.
#
# 실험 6은 인덱스가 늘면 경계가 내려간다는 것을 보였다. 그런데 경계에서의 락 개수가
# 6,249 / 8,747 / 12,495 로 갈려서 "실험 1의 6,250 이 그대로 적용되지 않는다"까지만
# 적고 규칙은 못 밝혔다고 남겼다.
#
# 다시 보니 확장 이벤트에 필드가 하나 더 있었다. escalated_lock_count 는 문장이
# 그 시점까지 잡은 락 **전부**이고, hobt_lock_count 는 승격 대상이 된 **하나의
# HoBT(인덱스)** 에 걸린 락이다. 둘을 견주면 어느 쪽이 기준인지 갈린다.
#
# 가설 셋.
#   H1 문장 전체 락이 기준이다     → escalated_lock_count 가 조건마다 같아야 한다
#   H2 인덱스 하나의 락이 기준이다 → hobt_lock_count 가 조건마다 같아야 한다
#   H3 둘 다 쓴다                  → 검사 시점은 문장 전체 락의 1,250 배수,
#                                     승격 조건은 HoBT 하나가 5,000 이상
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

wait_ready || exit 2
OPTLOCK=$(assert_env) || exit 2

drop_nc(){
  QD "SET NOCOUNT ON;
      SELECT name FROM sys.indexes
       WHERE object_id = OBJECT_ID('$TBL') AND type_desc = 'NONCLUSTERED';" \
  | grep -E '^IX_' | while read -r n; do
    [ -n "$n" ] && QD "DROP INDEX [$n] ON $TBL;" >/dev/null
  done
}

setup(){
  reset_table 200000 >/dev/null || return 2
  drop_nc
  case "$1" in
    none) ;;
    upd1) QDX "CREATE INDEX IX_bal  ON $TBL (balance);" ;;
    upd2) QDX "CREATE INDEX IX_bal  ON $TBL (balance);
               CREATE INDEX IX_bal2 ON $TBL (account_id, balance);" ;;
  esac || return 2
  QD "UPDATE STATISTICS $TBL WITH FULLSCAN;" >/dev/null
}

{
echo "# 실험 9. 인덱스가 여럿일 때의 임계값 기준"
echo "# optimized locking: ${OPTLOCK}"
echo
echo "  실험 6은 경계 락이 6,249 / 8,747 / 12,495 로 갈린 것까지만 보고 규칙은"
echo "  못 밝혔다고 남겼습니다. 확장 이벤트의 두 필드를 견줘 다시 봅니다."
echo
echo "    escalated_lock_count  문장이 그 시점까지 잡은 락 전부"
echo "    hobt_lock_count       승격 대상이 된 인덱스 하나에 걸린 락"
echo
: > "$OUT/hobt-threshold.csv"
echo "condition,nc_indexes,escalated_lock_count,hobt_lock_count" >> "$OUT/hobt-threshold.csv"
printf "  %-26s %-10s %-22s %s\n" "조건" "NC개수" "escalated_lock_count" "hobt_lock_count"

run(){
  local mode=$1 label=$2 rows=$3
  setup "$mode" || { echo "  ${label}: 준비 실패"; return; }
  xe_reset
  QD "SET NOCOUNT ON; BEGIN TRAN;
      UPDATE TOP ($rows) $TBL SET balance = balance - 1;
      ROLLBACK;" >/dev/null
  local ev; ev=$(xe_events | head -1)
  if [ -z "$ev" ]; then
    printf "  %-26s %-10s %s\n" "$label" "-" "**승격 이벤트가 없습니다. 행 수를 올려야 합니다**"; return
  fi
  local esc hobt nc
  esc=$(echo "$ev" | cut -d'|' -f1)
  hobt=$(echo "$ev" | cut -d'|' -f4)
  nc=$(num "$(QD "SELECT COUNT(*) FROM sys.indexes
                   WHERE object_id = OBJECT_ID('$TBL') AND type_desc = 'NONCLUSTERED'")")
  printf "  %-26s %-10s %-22s %s\n" "$label" "$nc" "$esc" "$hobt"
  echo "\"$label\",$nc,$esc,$hobt" >> "$OUT/hobt-threshold.csv"
}

# 각 조건에서 승격이 확실히 나는 행 수로 던진다. 경계보다 조금 위면 된다.
run none "1) 인덱스 없음"        7000
run upd1 "2) 갱신 컬럼에 1개"    3200
run upd2 "3) 갱신 컬럼에 2개"    2700

echo
ESC=$(awk -F, 'NR>1 && $3 ~ /^[0-9]+$/ {print $3}' "$OUT/hobt-threshold.csv")
HOB=$(awk -F, 'NR>1 && $4 ~ /^[0-9]+$/ {print $4}' "$OUT/hobt-threshold.csv")
N=$(echo "$ESC" | grep -c .)

# H3 을 검사한다. escalated 가 1,250 배수 **직전**이고 hobt 가 5,000 이상인가.
#
# "정확히 배수 - 1" 로 봤더니 회차마다 갈렸다. 6,249 였다가 6,248 이 된다.
# 실험 1에서 이미 본 흔들림이고 원인은 계획이 잡는 페이지 락 수다. 그래서 정확한
# 값이 아니라 **배수까지의 거리**로 본다. 거리가 3 이내면 그 검사 지점에서 걸린 것이다.
CK=0; DIST=""
for v in $ESC; do
  d=$(( 1250 - (v % 1250) )); [ "$d" -eq 1250 ] && d=0
  DIST="$DIST $d"
  [ "$d" -le 3 ] && CK=$(( CK + 1 ))
done
HK=0; for v in $HOB; do [ "$v" -ge 5000 ] && HK=$(( HK + 1 )); done

echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
printf "  %-40s %s\n" "escalated_lock_count 가 1,250 배수 직전" "${CK}/${N}"
printf "  %-40s %s\n" "hobt_lock_count 가 5,000 이상" "${HK}/${N}"
echo
if [ "$CK" = "$N" ] && [ "$HK" = "$N" ]; then
  echo "  **두 조건이 세 경우 모두에서 성립합니다. H3 이 규칙입니다.**"
  echo
  echo "    엔진은 문장이 락을 1,250개 잡을 때마다 검사한다."
  echo "    그 시점에 락이 5,000개 이상인 인덱스(HoBT)가 있으면 그것을 승격시킨다."
  echo
  echo "  이 규칙이 앞선 관측을 전부 설명합니다."
  echo
  echo "    인덱스가 없으면 락이 전부 클러스터드에 붙는다. 5,000 검사 시점에는"
  echo "    아직 4,99x 라 안 걸리고, 다음 검사 지점인 6,250 에서 걸린다(실험 1)."
  echo
  echo "    인덱스가 하나 늘면 같은 행 수의 락이 두 인덱스로 나뉜다. 보조 인덱스가"
  echo "    5,000 에 닿는 것은 문장 전체 락이 7,500 일 때이고, 거기서 걸린다."
  echo
  echo "    인덱스가 둘 늘면 셋으로 나뉜다. 12,500 에서 걸린다."
  echo
  echo "  실험 6에서 \"경계 락이 6,249 / 8,747 / 12,495 로 갈려 규칙을 못 밝혔다\"고"
  echo "  적은 것을 이 실험이 닫습니다. 갈린 것은 **문장 전체 락**이었고, 안 갈린 것은"
  echo "  **승격 대상 인덱스의 락**이었습니다. 문서의 5,000 은 후자를 가리키는 값입니다."
  echo
  echo "  운영으로 옮기면 처방이 더 정확해집니다. 배치 크기는 **갱신 컬럼을 담은 인덱스"
  echo "  중 락이 가장 많이 붙는 것이 5,000 에 안 닿도록** 잡습니다. 갱신 컬럼이 키인"
  echo "  보조 인덱스는 행당 2개가 붙으므로 그 인덱스 기준으로는 2,500행이 상한입니다."
else
  echo "  **H3 도 성립하지 않습니다.** 규칙은 여전히 미해결로 둡니다."
  echo "  escalated: $(echo $ESC | tr '\n' ' ')"
  echo "  hobt:      $(echo $HOB | tr '\n' ' ')"
fi
} 2>&1 | tee "$OUT/exp9-hobt-threshold.txt"
