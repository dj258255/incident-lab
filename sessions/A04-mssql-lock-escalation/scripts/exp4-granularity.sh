#!/usr/bin/env bash
# 실험 4. 규모를 키웠더니 승격이 사라졌다.
#
# 실험 3을 100만행으로 돌렸다가 이상한 것을 봤다. 20만행에서는 승격이 나던 것이
# 100만행에서는 한 번도 안 났다. 규모를 키웠는데 승격이 사라진 것이다.
#
# 락 구조를 열어 보니 이유가 나왔다. 100만행 갱신에서 엔진이 잡은 것은 행 락이
# 아니라 페이지 락 2,718개였다. 페이지 하나에 수백 행이 들어가므로 락 개수가
# 임계값 근처에도 못 간다. 승격을 안 한 것이 아니라 **승격할 만큼 락을 안 잡았다.**
#
# 이 실험은 그 전환이 어디서 일어나는지를 규모별로 훑는다. 실험 1의 결론(임계값은
# 6,250)은 행 락을 잡는 규모에서만 의미가 있고, 그 밖에서는 다른 이야기가 된다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

wait_ready || exit 2

# 테이블 전체를 한 문장으로 갱신했을 때의 락 구조를 본다.
# 실험 1의 lock_shape 는 TOP (n) 으로 일부만 갱신하지만, 여기서는 전체 갱신의
# 계획이 어떤 락 단위를 고르는지가 질문이므로 WHERE 없이 전부 갱신한다.
full_update_shape(){
  num "$(QD "SET NOCOUNT ON;
    BEGIN TRAN;
    UPDATE $TBL SET balance = balance - 1;
    SELECT CAST(SUM(CASE WHEN resource_type='OBJECT' AND request_mode='X' THEN 1 ELSE 0 END) AS varchar(4))
         + ',' + CAST(SUM(CASE WHEN resource_type='KEY'  THEN 1 ELSE 0 END) AS varchar(12))
         + ',' + CAST(SUM(CASE WHEN resource_type='PAGE' THEN 1 ELSE 0 END) AS varchar(12))
         + ',' + CAST(SUM(CASE WHEN resource_type <> 'DATABASE' THEN 1 ELSE 0 END) AS varchar(12))
      FROM sys.dm_tran_locks WHERE request_session_id = @@SPID;
    ROLLBACK;")"
}

{
echo "# 실험 4. 규모를 키웠더니 승격이 사라졌다"
echo
echo "  실험 3을 100만행으로 돌렸을 때 승격이 한 번도 안 났습니다. 20만행에서는"
echo "  나던 것이 규모를 키우니 사라졌습니다. 그 이유를 규모별로 확인합니다."
echo
echo "  테이블 전체를 한 문장으로 갱신하고, 엔진이 무슨 단위의 락을 잡았는지 봅니다."
echo

: > "$OUT/granularity.csv"
echo "rows,escalated,key_locks,page_locks,table_locks,escalation_events,granularity" >> "$OUT/granularity.csv"
printf "  %-12s %-8s %-12s %-12s %-12s %-12s %s\n" "테이블 행수" "승격" "KEY락" "PAGE락" "테이블락" "승격 이벤트" "엔진이 고른 단위"

for rows in 50000 100000 200000 400000 600000 1000000; do
  reset_table "$rows" || continue
  xe_reset
  IFS=, read -r esc key pg tot <<<"$(full_update_shape)"
  ev=$(xe_count)
  if   [ "$esc" = 1 ];                     then gran="테이블 (승격됨)"
  elif [ "${key:-0}" -gt 0 ];              then gran="행"
  elif [ "${pg:-0}" -gt 0 ];               then gran="페이지"
  else                                          gran="판별 불가"
  fi
  printf "  %-12s %-8s %-12s %-12s %-12s %-12s %s\n" \
    "$rows" "$([ "$esc" = 1 ] && echo 예 || echo 아니오)" "$key" "$pg" "$tot" "${ev}건" "$gran"
  echo "$rows,$esc,$key,$pg,$tot,$ev,$gran" >> "$OUT/granularity.csv"
done

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  엔진은 갱신할 양을 보고 락 단위를 먼저 고릅니다. 양이 적으면 행 락을 잡고,"
echo "  그러다 6,250개를 넘기면 테이블 락으로 승격합니다. 양이 많으면 아예 처음부터"
echo "  페이지 락을 잡습니다. 페이지 하나에 수백 행이 들어가니 락 개수가 임계값"
echo "  근처에도 못 가고, 그래서 **승격이 일어나지 않습니다.**"
echo
echo "  승격이 없다고 안전한 것은 아닙니다. 페이지 락도 그 페이지에 든 행 전부를"
echo "  막습니다. 보정 대상이 아닌 계정이 같은 페이지에 있으면 똑같이 막힙니다."
echo "  달라지는 것은 **막히는 범위가 테이블 전체냐 페이지 단위냐** 입니다."
echo
echo "  실험 1의 6,250 은 행 락을 잡는 규모에서만 쓸 수 있는 숫자입니다."
echo "  \"배치를 5,000행 미만으로\" 라는 처방은 그래서 규모와 무관하게 맞습니다."
echo "  5,000행 배치는 어느 쪽이든 행 락 5,000개 이하이고 승격 검사에 안 걸립니다."
} 2>&1 | tee "$OUT/exp4-granularity.txt"
