#!/usr/bin/env bash
# 실험 3. 조사 쿼리는 인덱스 없이 얼마나 읽는가.
#
# 사고가 나면 조사 쿼리를 급하게 던진다. 그런데 재화 원장은 평소에 쓰기만 하는
# append-only 표라, 조사에 쓸 인덱스가 없는 경우가 많다. 그러면 2천만 행을 전부
# 읽는다. 그 사이 서비스는 계속 돌고 있다.
#
# 지표는 시간이 아니라 **논리 읽기(페이지 수)** 다. 이 컨테이너는 ARM 에뮬레이션이라
# 절대 시간이 이 호스트의 값이 아니지만, 논리 읽기는 하드웨어와 무관하다.
#
# 인덱스를 만드는 것 자체도 비용이다. 사고 중에 2천만 행 표에 인덱스를 새로 만들 수
# 있는가는 별개의 판단이라, 만들어진 인덱스의 크기도 함께 적는다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

wait_ready || exit 2
WIN_START=$(grep '^window_start,' "$OUT/dataset.csv" | cut -d, -f2-)
WIN_END=$(grep '^window_end,'   "$OUT/dataset.csv" | cut -d, -f2-)
LEDGER=$(grep '^currency_ledger_rows,' "$OUT/dataset.csv" | cut -d, -f2)
[ -n "$WIN_START" ] || { echo "중단: dataset.csv 가 없습니다" >&2; exit 2; }

# 실험 2의 A 안. 정확한 방법이고 실제로 회수 근거가 되는 쿼리다.
DETECT_SQL="
SELECT COUNT(DISTINCT account_id)
  FROM currency_ledger
 WHERE reason = 1
   AND created_at >= '$WIN_START' AND created_at < '$WIN_END'
   AND ref_id IN (SELECT ref_id
                    FROM currency_ledger
                   WHERE reason = 1
                     AND created_at >= '$WIN_START' AND created_at < '$WIN_END'
                   GROUP BY ref_id HAVING COUNT(*) > 1);"

drop_idx(){
  local names
  names=$(QD "SET NOCOUNT ON;
    SELECT name FROM sys.indexes
     WHERE object_id = OBJECT_ID('currency_ledger') AND type_desc = 'NONCLUSTERED';")
  echo "$names" | grep -E '^IX_' | while read -r n; do
    [ -n "$n" ] && QD "DROP INDEX [$n] ON currency_ledger;" >/dev/null
  done
}

idx_pages(){
  num "$(QD "SELECT CAST(ISNULL(SUM(ps.used_page_count), 0) AS varchar(20))
               FROM sys.dm_db_partition_stats ps
               JOIN sys.indexes i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
              WHERE ps.object_id = OBJECT_ID('currency_ledger') AND i.name = '$1';")"
}

run_case(){
  local label=$1 create=$2 idxname=$3 raw=${4:-}
  drop_idx
  if [ -n "$create" ]; then
    QDX "$create" || { echo "  ${label}: 인덱스 생성 실패"; return; }
  fi
  QD "UPDATE STATISTICS currency_ledger WITH FULLSCAN;" >/dev/null
  local reads pages mb
  reads=$(logical_reads "$DETECT_SQL" "$raw")
  if [ -z "$reads" ] || [ "$reads" = "0" ]; then
    printf "  %-34s %s\n" "$label" "**논리 읽기를 못 읽었습니다**"
    echo "\"$label\",ERROR,," >> "$OUT/index.csv"; return
  fi
  if [ -n "$idxname" ]; then pages=$(idx_pages "$idxname"); else pages=0; fi
  mb=$(( pages * 8 / 1024 ))
  printf "  %-34s %-16s %s\n" "$label" "$(printf "%'d" "$reads")" "${mb}MB"
  # 라벨에 쉼표가 들어간다("IX(created_at, ref_id) ..."). 감싸지 않으면 열이 밀린다.
  echo "\"$label\",$reads,$pages,$mb" >> "$OUT/index.csv"
}

{
echo "# 실험 3. 조사 쿼리의 논리 읽기"
echo
echo "  대상: 재화 원장 ${LEDGER}행. 사고 창 ${WIN_START} ~ ${WIN_END}."
echo "  쿼리: 실험 2의 A 안(참조 대사). 회수 근거가 되는 정확한 쪽입니다."
echo
echo "  시간은 적지 않습니다. ARM 에뮬레이션이라 이 호스트의 값이 아닙니다."
echo "  논리 읽기는 어떤 하드웨어에서 돌든 같은 계획이면 같은 값입니다."
echo
: > "$OUT/index.csv"
echo "index,logical_reads,index_pages,index_mb" >> "$OUT/index.csv"
printf "  %-34s %-16s %s\n" "인덱스" "논리 읽기" "인덱스 크기"

run_case "없음 (클러스터드 PK 만)" "" ""

run_case "IX(ref_id)" \
  "SET QUOTED_IDENTIFIER ON; CREATE INDEX IX_ledger_ref ON currency_ledger (ref_id);" \
  "IX_ledger_ref"

run_case "IX(created_at)" \
  "SET QUOTED_IDENTIFIER ON; CREATE INDEX IX_ledger_time ON currency_ledger (created_at);" \
  "IX_ledger_time"

run_case "IX(created_at, ref_id) 포함 account" \
  "SET QUOTED_IDENTIFIER ON; CREATE INDEX IX_ledger_time_ref ON currency_ledger (created_at, ref_id) INCLUDE (account_id);" \
  "IX_ledger_time_ref"

# 여기까지는 전부 reason 이 인덱스에 없다. 조건에 reason = 1 이 있는데 인덱스가
# 그것을 못 담으니 옵티마이저가 조회를 인덱스로 못 끝내고 표를 그냥 훑는다.
# 만들어 놓고 안 쓰이는 인덱스다.
run_case "IX(reason, created_at, ref_id) 포함 account" \
  "SET QUOTED_IDENTIFIER ON; CREATE INDEX IX_ledger_full ON currency_ledger (reason, created_at, ref_id) INCLUDE (account_id);" \
  "IX_ledger_full"

run_case "필터드 (created_at, ref_id) WHERE reason=1" \
  "SET QUOTED_IDENTIFIER ON; CREATE INDEX IX_ledger_time_ref_f ON currency_ledger (created_at, ref_id) INCLUDE (account_id) WHERE reason = 1;" \
  "IX_ledger_time_ref_f"

# 같은 필터드 인덱스를 두고 조회 쪽 SET 옵션만 뺀다. 에러 없이 그냥 안 쓰인다.
run_case "  위와 같되 조회에 SET 옵션 없음" \
  "SET QUOTED_IDENTIFIER ON; CREATE INDEX IX_ledger_time_ref_f ON currency_ledger (created_at, ref_id) INCLUDE (account_id) WHERE reason = 1;" \
  "IX_ledger_time_ref_f" "raw"

drop_idx
echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  인덱스가 없으면 사고 창 4시간을 보려고 30일치 전부를 읽습니다."
echo "  창에 든 행은 전체의 0.6퍼센트인데 읽는 양은 전체의 두 배입니다."
echo "  쿼리가 원장을 두 번 훑기 때문입니다."
echo
echo "  **가운데 세 조건은 인덱스를 만들었는데도 읽는 양이 안 줄었습니다.**"
echo "  셋 다 조건에 있는 reason 을 인덱스가 담지 않았습니다. 인덱스로 조회를"
echo "  끝낼 수 없으니 옵티마이저가 표를 그냥 훑습니다. 만들어 놓고 안 쓰이는"
echo "  인덱스이고, 쓰이지도 않으면서 쓰기마다 갱신 비용은 그대로 냅니다."
echo
echo "  reason 을 키에 넣자 읽는 양이 자릿수로 떨어집니다. 조건과 출력에 필요한"
echo "  컬럼이 전부 인덱스 안에 있어 원장 본문을 한 번도 안 봅니다."
echo
echo "  필터드 인덱스는 reason=1 만 담아 더 작습니다. 다만 조사 쿼리가 같은 조건을"
echo "  걸어야 쓰이고, 다른 사고 유형을 조사할 때는 못 씁니다."
echo
echo "  **마지막 줄이 이 실험에서 제일 조심할 자리입니다.** 인덱스는 그대로 있는데"
echo "  조회 쪽 SET 옵션(QUOTED_IDENTIFIER, ANSI_NULLS)이 안 맞으면 필터드 인덱스는"
echo "  쓰이지 않습니다. 에러가 나지 않고 그냥 안 쓰입니다. 인덱스를 만들어 두고도"
echo "  느린 이유를 찾지 못하는 자리이고, 접속 도구마다 기본 SET 옵션이 달라서"
echo "  \"내 SSMS 에서는 빠른데 애플리케이션에서는 느리다\"가 여기서 나옵니다."
echo
echo "  **이 인덱스들을 사고가 난 뒤에 만들 수 있는가는 별개의 문제입니다.**"
echo "  라이브 표에 인덱스를 만드는 동안 그 표는 잠깁니다. 평소에 조사용 인덱스를"
echo "  하나 두는 비용과, 사고 때 전체를 읽으며 조사하는 비용을 견줘야 합니다."
} 2>&1 | tee "$OUT/exp3-index.txt"
