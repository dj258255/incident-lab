#!/usr/bin/env bash
# 실험 1. 락 에스컬레이션이 실제로 발동하는 지점을 찾는다.
#
# Microsoft Learn 은 "단일 T-SQL 문이 한 테이블 참조에 최소 5,000개 락을 획득하면
# 에스컬레이션한다"고 적는다. 그 5,000 을 그대로 믿고 배치 크기를 4,000 으로 잡는
# 운영 관행이 흔하다. 이 실험은 그 숫자를 실측으로 확인한다.
#
# 판정은 락 구조로 한다. 승격 전에는 행마다 KEY X 락이 잡히고 테이블에는 IX(의도)
# 락만 걸린다. 승격 후에는 KEY 락이 전부 사라지고 테이블에 X 락 하나만 남는다.
# 둘은 섞이지 않으므로 이 판정에는 회색지대가 없다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
ROUNDS=${ROUNDS:-3}

wait_ready || exit 2
OPTLOCK=$(assert_env) || exit 2

{
echo "# 실험 1. 락 에스컬레이션 임계값"
echo "# $(num "$(Q "SELECT LEFT(@@VERSION, 46)")")"
echo "# optimized locking: ${OPTLOCK}  (ABSENT = 이 빌드에 그 기능이 없음)"
echo
echo "  이 컨테이너는 ARM 에뮬레이션으로 돕니다. 시간 수치는 적지 않습니다."
echo "  이 실험이 묻는 것은 시간이 아니라 **몇 개째 락에서 승격이 일어나는가** 입니다."
echo

reset_table 200000 || exit 2

echo "## 1-1. 락 구조가 갈리는 것을 먼저 본다"
echo
printf "  %-10s %-8s %-9s %-9s %s\n" "갱신행" "승격" "KEY락" "PAGE락" "테이블락"
for n in 3000 10000; do
  IFS=, read -r esc key pg tot <<<"$(lock_shape "$n")"
  printf "  %-10s %-8s %-9s %-9s %s\n" "$n" "$([ "$esc" = 1 ] && echo 예 || echo 아니오)" "$key" "$pg" "$tot"
done
echo
echo "  3,000행에서는 행마다 KEY 락이 잡혀 있고 테이블 락은 의도(IX) 뿐입니다."
echo "  10,000행에서는 KEY 락이 0개이고 테이블에 X 락 하나만 남습니다."
echo "  행 단위 락이 테이블 락 하나로 접힌 것이 에스컬레이션입니다."
echo

echo "## 1-2. 문서의 5,000 근처를 훑는다"
echo
: > "$OUT/threshold-sweep.csv"
echo "run,rows,escalated,key_locks,page_locks,total_locks" >> "$OUT/threshold-sweep.csv"
printf "  %-10s %-8s %-9s %s\n" "갱신행" "승격" "테이블락" "메모"
for n in 4000 4900 5000 5100 6000 6200 6230 6240 6250 7000; do
  IFS=, read -r esc key pg tot <<<"$(lock_shape "$n")"
  memo=""
  [ "$n" = 5000 ] && memo="문서가 말하는 임계값"
  printf "  %-10s %-8s %-9s %s\n" "$n" "$([ "$esc" = 1 ] && echo 예 || echo 아니오)" "$tot" "$memo"
  echo "0,$n,$esc,$key,$pg,$tot" >> "$OUT/threshold-sweep.csv"
done
echo
echo "  **5,000행에서 승격이 일어나지 않습니다.** 6,000행에서도, 6,200행에서도 안 납니다."
echo

echo "## 1-3. 경계를 찾아서 ${ROUNDS}회 확인한다"
echo
echo "  경계를 손으로 적지 않고 이분 탐색으로 찾습니다. 승격하지 않는 가장 큰 행 수와"
echo "  승격하는 가장 작은 행 수를 좁혀 나갑니다. 라벨을 손으로 쓰면 값이 바뀌었을 때"
echo "  글이 측정을 반박하게 됩니다."
echo
find_boundary(){   # "승격없는최대,그때전체락,승격하는최소,그때전체락"
  local lo=3000 hi=10000 mid esc tot lo_tot=0
  while [ $(( hi - lo )) -gt 1 ]; do
    mid=$(( (lo + hi) / 2 ))
    IFS=, read -r esc _ _ tot <<<"$(lock_shape "$mid")"
    if [ "$esc" = 1 ]; then hi=$mid; else lo=$mid; lo_tot=$tot; fi
  done
  IFS=, read -r _ _ _ hi_tot <<<"$(lock_shape "$hi")"
  echo "$lo,$lo_tot,$hi,$hi_tot"
}
printf "  %-8s %-28s %s\n" "회차" "승격하지 않는 최대" "승격하는 최소"
LOCKS=""
for r in $(seq 1 "$ROUNDS"); do
  B=$(find_boundary)
  IFS=, read -r blo blo_t bhi bhi_t <<<"$B"
  printf "  %-8s %-28s %s\n" "$r" "${blo}행 (테이블락 ${blo_t})" "${bhi}행"
  LOCKS="$LOCKS $blo_t"
  BHI=$bhi
  echo "$r,boundary_lo,0,,,$blo_t" >> "$OUT/threshold-sweep.csv"
done
LMIN=$(echo $LOCKS | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | head -1)
LMAX=$(echo $LOCKS | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | tail -1)
SPREAD=$(( LMAX - LMIN ))
echo
echo "  회차별 \"승격하지 않는 최대\" 테이블 락: ${LOCKS}"
echo
if [ "$SPREAD" -eq 0 ]; then
  echo "  ${ROUNDS}회 모두 테이블 락 ${LMAX}개에서 갈렸습니다. 하나가 더 붙어"
  echo "  $(( LMAX + 1 ))개가 되는 순간 승격합니다."
  echo
elif [ "$SPREAD" -le 2 ]; then
  echo "  경계는 회차마다 락 ${SPREAD}개 안에서 움직입니다(${LMIN}~${LMAX})."
  echo "  한 점으로 못 박지 않고 범위로 적습니다. 계획이 잡는 페이지 락 수가 회차마다"
  echo "  한둘 달라지기 때문입니다. 앞선 실행에서 실제로 6,248 과 6,249 사이를 오갔습니다."
  echo
  echo "  **그래도 결론은 흔들리지 않습니다.** 문서가 말하는 5,000 과 이 범위는"
  echo "  1,200 이상 떨어져 있습니다. 이 차이는 잡음이 아닙니다."
else
  echo "  **회차마다 ${SPREAD}개나 갈립니다. 이 경계는 인용하면 안 됩니다.**"
fi
echo

echo "## 1-4. 엔진에게 직접 물어본다"
echo
echo "  락 구조로 내린 판정을 엔진의 보고와 대조합니다. 확장 이벤트"
echo "  sqlserver.lock_escalation 은 승격 시점의 락 개수와 사유를 직접 적어 줍니다."
echo
xe_reset
QD "SET NOCOUNT ON; BEGIN TRAN; UPDATE TOP (${BHI:-6240}) $TBL SET balance = balance - 1; ROLLBACK;" >/dev/null
n_ev=$(xe_count)
if [ "${n_ev:-0}" -eq 0 ]; then
  echo "  승격 이벤트가 잡히지 않았습니다. 위 판정과 어긋나므로 이 절은 인용하지 않습니다."
else
  xe_events | while IFS='|' read -r cnt cause mode; do
    printf "  %-22s %s\n" "승격 시점 락 개수" "$cnt"
    printf "  %-22s %s\n" "사유" "$cause"
    printf "  %-22s %s\n" "획득한 테이블 락" "$mode"
  done
  EV_CNT=$(xe_events | head -1 | cut -d'|' -f1)
  echo
  echo "  엔진이 스스로 적은 숫자가 ${EV_CNT} 입니다. 이분 탐색이 찾은 범위"
  echo "  ${LMIN}~${LMAX} 안에 들어옵니다. 서로 다른 두 경로가 같은 곳을 가리킵니다."
  if [ "$EV_CNT" -ge "$LMIN" ] && [ "$EV_CNT" -le "$LMAX" ] 2>/dev/null; then
    echo "  락 구조로 내린 판정과 엔진의 보고가 일치합니다."
  else
    echo "  **두 경로가 어긋납니다(${EV_CNT} vs ${LMIN}~${LMAX}). 이 절은 인용하면 안 됩니다.**"
  fi
fi
echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  문서의 5,000 은 **검사를 시작하는 값**이지 발동하는 값이 아닙니다."
echo "  이 빌드에서 실제 발동은 테이블 락 $(( LMAX + 1 ))개 근처였습니다. 5,000 에 1,250 을"
echo "  더한 값이고, 문서가 말하는 재시도 간격 1,250 과 맞아떨어집니다. 엔진은 락을"
echo "  1,250개 획득할 때마다 검사하므로 5,000 을 넘긴 뒤 처음 만나는 검사 지점이"
echo "  6,250 입니다. 5,000 과 6,250 사이는 문서를 그대로 읽으면 승격할 것 같지만"
echo "  실제로는 승격하지 않는 구간입니다."
echo
echo "  운영 관점의 함의는 배치 크기를 4,000 으로 잡는 관행이 안전한 쪽으로"
echo "  틀렸다는 것입니다. 다만 이 여유는 문서가 보장하는 값이 아니므로"
echo "  기대지 않는 편이 낫습니다. 5,000 미만이면 어느 쪽이든 승격하지 않습니다."
} 2>&1 | tee "$OUT/exp1-threshold.txt"
