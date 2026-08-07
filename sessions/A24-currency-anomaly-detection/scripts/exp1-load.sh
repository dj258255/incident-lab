#!/usr/bin/env bash
# 실험 1. 조사 대상 로그를 만든다.
#
# 게임 재화 원장은 append-only 대용량 테이블이다. 사고가 나면 그 안에서 이상 지급을
# 찾아야 하는데, 찾는 쪽은 사고가 난 뒤에야 이 표를 처음 진지하게 들여다본다.
#
# 사고 모델은 로스트아크 2022-12-28 골드 복사다. 상자 사용 횟수가 차감되지 않아
# 개봉 한 번에 보상이 여러 번 지급됐다. 원장에 남는 흔적은 **같은 ref_id 에 지급이
# 여러 건 붙는 것**이다. 이 세션은 버그를 재현하지 않고 그 흔적만 만든다.
#
# 시각은 고정한다. 사고 창은 2026-07-28 10:00 부터 4시간이다. 실제 사고에서 발견까지
# 17분, 수정까지 4시간이 걸렸다는 공개 기록의 모양을 따랐다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

BASE_START='2026-07-01 00:00:00'
WIN_START='2026-07-28 10:00:00'
WIN_END='2026-07-28 14:00:00'
CHUNK=${CHUNK:-1000000}
# 로그가 걸치는 기간. 행 수와 무관하게 항상 30일을 덮게 계산한다.
# 처음에는 행당 259.2ms 를 상수로 박았는데, 그것은 1,000만 행일 때만 30일이 된다.
# 규모를 줄여 시험하니 데이터가 14시간만 덮어 사고 창에 한 행도 안 들어갔다.
# 덧붙여 30일을 밀리초로 세면 2,592,000,000 이라 DATEADD 의 INT 인자를 넘긴다.
# 초 단위로 세고, 곱셈은 BIGINT 로 한 뒤 결과만 INT 로 줄인다.
SPAN_SEC=2592000

wait_ready || exit 2

{
echo "# 실험 1. 조사 대상 로그 적재"
echo "# $(num "$(Q "SELECT LEFT(@@VERSION, 46)")")"
echo
echo "  개봉 로그 ${OPENS}행, 재화 원장 $(( OPENS + OTHERS ))행, 계정 ${ACCOUNTS}개."
echo "  사고 창은 ${WIN_START} 부터 ${WIN_END} 까지 4시간입니다."
echo

Q "IF DB_ID('$DB') IS NULL CREATE DATABASE [$DB];" >/dev/null
# 대량 적재 동안 로그가 부풀지 않게 한다. 이 세션의 주제가 복구가 아니므로 SIMPLE 로 둔다.
Q "ALTER DATABASE [$DB] SET RECOVERY SIMPLE;" >/dev/null

QDX "SET NOCOUNT ON;
DROP TABLE IF EXISTS currency_ledger;
DROP TABLE IF EXISTS box_open_log;
DROP TABLE IF EXISTS truth_accounts;

CREATE TABLE box_open_log (
    open_id    BIGINT       NOT NULL,
    account_id INT          NOT NULL,
    box_id     INT          NOT NULL,
    opened_at  DATETIME2(3) NOT NULL,
    CONSTRAINT PK_box_open_log PRIMARY KEY CLUSTERED (open_id)
);

CREATE TABLE currency_ledger (
    ledger_id  BIGINT IDENTITY(1,1) NOT NULL,
    account_id INT          NOT NULL,
    delta      BIGINT       NOT NULL,
    reason     TINYINT      NOT NULL,   -- 1 상자개봉  2 거래  3 상점
    ref_id     BIGINT       NULL,       -- reason=1 이면 box_open_log.open_id
    created_at DATETIME2(3) NOT NULL,
    CONSTRAINT PK_currency_ledger PRIMARY KEY CLUSTERED (ledger_id)
);

-- 정답지. 탐지 결과를 이것과 대조한다. 조사 쿼리는 이 표를 보지 않는다.
CREATE TABLE truth_accounts (
    account_id   INT PRIMARY KEY,
    extra_rows   INT    NOT NULL DEFAULT 0,
    extra_amount BIGINT NOT NULL DEFAULT 0
);" || exit 2

echo "## 1-1. 개봉 로그"
lo=0
while [ "$lo" -lt "$OPENS" ]; do
  this=$(( OPENS - lo )); [ "$this" -gt "$CHUNK" ] && this=$CHUNK
  QDX "SET NOCOUNT ON;
  WITH n AS (SELECT TOP ($this) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
               FROM sys.all_objects a CROSS JOIN sys.all_objects b CROSS JOIN sys.all_objects c)
  INSERT INTO box_open_log WITH (TABLOCK) (open_id, account_id, box_id, opened_at)
  SELECT $lo + i,
         (($lo + i) % $ACCOUNTS) + 1,
         (($lo + i) % 5) + 1,
         DATEADD(second, CAST(CAST($lo + i AS BIGINT) * $SPAN_SEC / $OPENS AS INT), '$BASE_START')
    FROM n;" || exit 2
  lo=$(( lo + this ))
  printf "\r  적재 %s / %s" "$lo" "$OPENS"
done
echo
GOT_OPEN=$(num "$(QD "SELECT COUNT(*) FROM box_open_log")")
[ "$GOT_OPEN" = "$OPENS" ] || { echo "중단: 개봉 로그가 ${GOT_OPEN}행입니다(기대 ${OPENS})"; exit 2; }

echo "## 1-2. 재화 원장 (개봉 지급분)"
lo=0
while [ "$lo" -lt "$OPENS" ]; do
  this=$(( OPENS - lo )); [ "$this" -gt "$CHUNK" ] && this=$CHUNK
  QDX "SET NOCOUNT ON;
  INSERT INTO currency_ledger WITH (TABLOCK) (account_id, delta, reason, ref_id, created_at)
  SELECT account_id, ((open_id % 7) + 1) * 100, 1, open_id, opened_at
    FROM box_open_log
   WHERE open_id > $lo AND open_id <= $lo + $this;" || exit 2
  lo=$(( lo + this ))
  printf "\r  적재 %s / %s" "$lo" "$OPENS"
done
echo

echo "## 1-3. 재화 원장 (개봉이 아닌 이동)"
lo=0
while [ "$lo" -lt "$OTHERS" ]; do
  this=$(( OTHERS - lo )); [ "$this" -gt "$CHUNK" ] && this=$CHUNK
  QDX "SET NOCOUNT ON;
  WITH n AS (SELECT TOP ($this) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
               FROM sys.all_objects a CROSS JOIN sys.all_objects b CROSS JOIN sys.all_objects c)
  INSERT INTO currency_ledger WITH (TABLOCK) (account_id, delta, reason, ref_id, created_at)
  SELECT (($lo + i) % $ACCOUNTS) + 1,
         CASE WHEN (($lo + i) % 2) = 0 THEN -(((($lo + i) % 11) + 1) * 50)
                                       ELSE  (((($lo + i) % 13) + 1) * 70) END,
         CASE WHEN (($lo + i) % 2) = 0 THEN 3 ELSE 2 END,
         NULL,
         DATEADD(second, CAST(CAST($lo + i AS BIGINT) * $SPAN_SEC / $OTHERS AS INT), '$BASE_START')
    FROM n;" || exit 2
  lo=$(( lo + this ))
  printf "\r  적재 %s / %s" "$lo" "$OTHERS"
done
echo

echo "## 1-4. 사고 흔적 심기"
# 어뷰저는 창 안에서 상자를 반복해서 연다. 처음에는 기존 개봉 중 일부를 골라
# 지급만 덧붙이려 했는데, 계정 분포가 균등해서 4시간 창 안에 계정당 개봉이 1건도
# 안 되는 계정이 대부분이었다. 고른 계정에 개봉이 없으니 심을 자리가 없었다.
# 어뷰저의 개봉 자체를 창 안에 넣는 쪽이 사건의 모양에도 맞다.
PER=$(( DUPE_OPENS / DUPE_ACCOUNTS ))
[ "$PER" -lt 1 ] && PER=1
DUPE_OPENS=$(( PER * DUPE_ACCOUNTS ))
echo "  이상 계정 ${DUPE_ACCOUNTS}개가 창 안에서 각 ${PER}회 개봉하고, 개봉마다 지급이 3건 더 붙습니다."

QDX "SET NOCOUNT ON;
DECLARE @maxOpen BIGINT = (SELECT ISNULL(MAX(open_id), 0) FROM box_open_log);
DECLARE @per INT = $PER, @da INT = $DUPE_ACCOUNTS, @acc INT = $ACCOUNTS;

WITH a AS (SELECT TOP (@da)  ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS ai
             FROM sys.all_objects),
     p AS (SELECT TOP (@per) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS pi
             FROM sys.all_objects)
INSERT INTO box_open_log (open_id, account_id, box_id, opened_at)
SELECT @maxOpen + a.ai * @per + p.pi + 1,
       a.ai * (@acc / @da) + 1,
       1,
       DATEADD(second, (a.ai * @per + p.pi) % 14400, '$WIN_START')
  FROM a CROSS JOIN p;" || exit 2

MAXBEFORE=$(num "$(QD "SELECT $OPENS")")
# 정상 지급 1건
QDX "SET NOCOUNT ON;
INSERT INTO currency_ledger (account_id, delta, reason, ref_id, created_at)
SELECT b.account_id, ((b.open_id % 7) + 1) * 100, 1, b.open_id, b.opened_at
  FROM box_open_log b WHERE b.open_id > $MAXBEFORE;" || exit 2
# 차감되지 않아 덧붙은 지급 3건
QDX "SET NOCOUNT ON;
INSERT INTO currency_ledger (account_id, delta, reason, ref_id, created_at)
SELECT b.account_id, ((b.open_id % 7) + 1) * 100, 1, b.open_id,
       DATEADD(millisecond, 50 * x.k, b.opened_at)
  FROM box_open_log b CROSS JOIN (VALUES (1),(2),(3)) AS x(k)
 WHERE b.open_id > $MAXBEFORE;" || exit 2

QDX "SET NOCOUNT ON;
INSERT INTO truth_accounts (account_id, extra_rows, extra_amount)
SELECT b.account_id, COUNT(*) * 3, SUM(((b.open_id % 7) + 1) * 100) * 3
  FROM box_open_log b WHERE b.open_id > $MAXBEFORE
 GROUP BY b.account_id;" || exit 2

echo "## 1-5. 정상인데 활동이 많은 계정"
# 첫 판에서 통계적 탐지가 오탐 0 으로 나왔다. 균등 분포에서는 어뷰저가 워낙 튀어
# 3시그마로도 깨끗이 갈렸기 때문이다. 그러면 이 데이터셋은 "통계적 탐지도 정확하다"는
# 결론을 내게 되는데, 그것은 데이터가 실제 게임과 다르기 때문에 나온 결론이다.
# 실제로는 정상 고활동 이용자가 있고, 그들이 오탐의 원천이다. 그 계정군을 넣는다.
QDX "SET NOCOUNT ON;
DECLARE @maxOpen BIGINT = (SELECT MAX(open_id) FROM box_open_log);
WITH a AS (SELECT TOP ($HEAVY_ACCOUNTS) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS ai
             FROM sys.all_objects),
     p AS (SELECT TOP ($HEAVY_OPENS)     ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS pi
             FROM sys.all_objects)
INSERT INTO box_open_log (open_id, account_id, box_id, opened_at)
SELECT @maxOpen + a.ai * $HEAVY_OPENS + p.pi + 1,
       ($ACCOUNTS / 2) + a.ai * 7,
       1,
       DATEADD(second, (a.ai * $HEAVY_OPENS + p.pi) % 14400, '$WIN_START')
  FROM a CROSS JOIN p;" || exit 2

HEAVY_FROM=$(( OPENS + DUPE_OPENS ))
QDX "SET NOCOUNT ON;
INSERT INTO currency_ledger (account_id, delta, reason, ref_id, created_at)
SELECT b.account_id, ((b.open_id % 7) + 1) * 100, 1, b.open_id, b.opened_at
  FROM box_open_log b WHERE b.open_id > $HEAVY_FROM;" || exit 2

# 고활동 계정이 이상 계정과 겹치면 오탐 판정이 무의미해진다. 겹치는지 확인한다.
OVERLAP=$(num "$(QD "SELECT COUNT(*) FROM truth_accounts t
                      WHERE t.account_id IN (SELECT DISTINCT account_id FROM box_open_log
                                              WHERE open_id > $HEAVY_FROM)")")
if [ "${OVERLAP:-0}" != "0" ]; then
  echo "  중단: 고활동 계정 ${OVERLAP}개가 이상 계정과 겹칩니다"; exit 2
fi
echo "  정상 고활동 계정 ${HEAVY_ACCOUNTS}개가 창 안에서 각 ${HEAVY_OPENS}회 개봉합니다(지급은 정상 1건씩)."

QD "UPDATE STATISTICS currency_ledger WITH FULLSCAN;
    UPDATE STATISTICS box_open_log   WITH FULLSCAN;" >/dev/null

LEDGER=$(num "$(QD "SELECT COUNT(*) FROM currency_ledger")")
TRUTH=$(num "$(QD "SELECT COUNT(*) FROM truth_accounts")")
EXTRA=$(num "$(QD "SELECT ISNULL(SUM(extra_rows),0) FROM truth_accounts")")
SIZE=$(num "$(QD "SELECT CAST(SUM(a.total_pages) * 8 / 1024 AS varchar(20))
                    FROM sys.allocation_units a
                    JOIN sys.partitions p ON p.partition_id = a.container_id
                   WHERE p.object_id = OBJECT_ID('currency_ledger')")")

echo
ALLOPEN=$(num "$(QD "SELECT COUNT(*) FROM box_open_log")")
printf "  %-22s %s\n" "개봉 로그" "${ALLOPEN}행 (정상 ${GOT_OPEN} + 어뷰저 ${DUPE_OPENS})"
printf "  %-22s %s\n" "재화 원장" "${LEDGER}행 (${SIZE}MB)"
printf "  %-22s %s\n" "이상 계정 (정답)" "${TRUTH}개"
printf "  %-22s %s\n" "덧붙은 지급 건수" "${EXTRA}건"
printf "  %-22s %s\n" "정상 고활동 계정" "${HEAVY_ACCOUNTS}개 (오탐 시험용)"
echo
{ echo "metric,value"
  echo "box_open_log_rows,$GOT_OPEN"
  echo "currency_ledger_rows,$LEDGER"
  echo "ledger_size_mb,$SIZE"
  echo "truth_accounts,$TRUTH"
  echo "extra_payout_rows,$EXTRA"
  echo "window_start,$WIN_START"
  echo "window_end,$WIN_END"; } > "$OUT/dataset.csv"

EXPECT=$(( OPENS + OTHERS + DUPE_OPENS * 4 + HEAVY_ACCOUNTS * HEAVY_OPENS ))  # 어뷰저 개봉 1+3, 고활동 1
if [ "$LEDGER" = "$EXPECT" ]; then
  echo "  원장 행 수가 기대와 같습니다(${EXPECT})."
else
  echo "  **원장이 ${LEDGER}행입니다(기대 ${EXPECT}). 이 데이터셋은 쓰면 안 됩니다.**"
fi
echo
echo "  계정 분포는 균등입니다. 실제 게임은 소수 계정에 활동이 쏠리므로"
echo "  이 데이터셋은 그 쏠림이 탐지에 주는 영향을 말할 수 없습니다."
} 2>&1 | tee "$OUT/exp1-load.txt"
