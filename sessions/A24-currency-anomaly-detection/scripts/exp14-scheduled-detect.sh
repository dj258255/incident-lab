#!/usr/bin/env bash
# 실험 14. 사고를 안 뒤에 도는 쿼리에서, 사고를 알려 주는 배치로.
#
# 이 세션의 조사 쿼리는 전부 **사고를 안 다음에** 창을 정해 한 번 도는 것이다.
# 못 한 것에 이렇게 적었다.
#   "탐지를 주기적으로 도는 형태로 안 만들었습니다. 매일 돌며 이상을 먼저 알려 주는
#    배치는 만들지 않았습니다."
#
# 한 번 도는 쿼리를 주기 배치로 옮기면 새 문제가 셋 생긴다. 그것을 만들고 확인한다.
#   1 어디까지 봤는지 기억해야 한다        안 그러면 매번 전체를 다시 읽는다
#   2 같은 사고를 두 번 알리면 안 된다     경보가 반복되면 아무도 안 본다
#   3 늦게 도착한 행을 놓치면 안 된다      시각 순서와 도착 순서는 다르다
#
# 3번이 제일 조용히 틀리는 자리다. created_at 을 워터마크로 쓰면, 배치가 지나간
# 뒤에 그보다 이른 created_at 을 가진 행이 들어올 때 영영 안 읽힌다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

W_START='2026-08-05 10:00:00'
BATCH_MIN=${BATCH_MIN:-60}     # 배치가 한 번에 보는 창(분)
ROUNDS=${SCAN_ROUNDS:-6}

wait_ready || exit 2
[ -f "$OUT/dataset.csv" ] || { echo "중단: 실험 1을 먼저 돌립니다" >&2; exit 2; }

{
echo "# 실험 14. 주기적으로 도는 탐지 배치"
echo
echo "  ${W_START} 부터 ${BATCH_MIN}분 창을 ${ROUNDS}번 밀며 돕니다."
echo "  사고는 그중 한 창에 들어 있고, 배치는 그것을 모릅니다."
echo

# ── 상태 표와 프로시저 ────────────────────────────────────────────────
# 워터마크를 표에 둔다. 배치가 죽었다 살아나도 이어서 돈다(A25 의 last_done 과 같은 생각).
QDX "SET NOCOUNT ON;
DROP TABLE IF EXISTS detect_alert;
DROP TABLE IF EXISTS detect_state;
CREATE TABLE detect_state (
    name       VARCHAR(50)  NOT NULL PRIMARY KEY,
    watermark  DATETIME2(3) NOT NULL,   -- 여기까지 봤다
    last_run   DATETIME2(3) NULL,
    runs       INT          NOT NULL DEFAULT 0
);
CREATE TABLE detect_alert (
    alert_id   INT IDENTITY(1,1) PRIMARY KEY,
    detector   VARCHAR(30)  NOT NULL,
    account_id INT          NOT NULL,
    ref_id     BIGINT       NULL,
    win_start  DATETIME2(3) NOT NULL,
    win_end    DATETIME2(3) NOT NULL,
    raised_at  DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),
    -- 같은 사고를 두 번 안 알린다. 무엇을 '같은 것'으로 볼지가 이 제약에 들어간다.
    CONSTRAINT UQ_alert UNIQUE (detector, account_id, ref_id)
);" || exit 2

# 탐지 프로시저. 창을 하나 보고 워터마크를 옮긴다.
# 워터마크 이동과 경보 기록을 **같은 트랜잭션**에 둔다. 밖에서 옮기면 경보를 쓰다
# 죽었을 때 그 창을 건너뛴다(A25 실험 3과 같은 이유).
QF "SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
CREATE OR ALTER PROCEDURE usp_ScanWindow
    @minutes INT,
    @lag_minutes INT = 0,          -- 늦게 도착하는 행을 기다리는 시간
    @scanned INT OUTPUT,
    @raised  INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @from DATETIME2(3), @to DATETIME2(3);

    SELECT @from = watermark FROM detect_state WHERE name = 'ledger_scan';
    IF @from IS NULL THROW 50050, N'상태 행이 없습니다', 1;
    SET @to = DATEADD(minute, @minutes, @from);

    BEGIN TRAN;
        -- 참조 중복. 이 세션의 A 방법이다.
        INSERT INTO detect_alert (detector, account_id, ref_id, win_start, win_end)
        SELECT 'dup_ref', l.account_id, l.ref_id, @from, @to
          FROM currency_ledger l
          JOIN (SELECT ref_id FROM currency_ledger
                 WHERE reason = 1 AND created_at >= @from AND created_at < @to
                 GROUP BY ref_id HAVING COUNT(*) > 1) d ON d.ref_id = l.ref_id
         WHERE l.reason = 1 AND l.created_at >= @from AND l.created_at < @to
           AND NOT EXISTS (SELECT 1 FROM detect_alert a
                            WHERE a.detector = 'dup_ref' AND a.account_id = l.account_id
                              AND a.ref_id = l.ref_id)
         GROUP BY l.account_id, l.ref_id;
        SET @raised = @@ROWCOUNT;

        SELECT @scanned = COUNT(*) FROM currency_ledger
         WHERE reason = 1 AND created_at >= @from AND created_at < @to;

        -- 워터마크를 옮긴다. @lag_minutes 만큼 뒤로 물러서면 늦게 온 행을 다시 본다.
        UPDATE detect_state
           SET watermark = DATEADD(minute, -@lag_minutes, @to),
               last_run  = SYSDATETIME(),
               runs      = runs + 1
         WHERE name = 'ledger_scan';
    COMMIT;
END
GO" >/dev/null

# ── 데이터 ────────────────────────────────────────────────────────────
# 정상 지급을 창 전체에 깔고, 사고(같은 참조로 두 번 지급)를 세 번째 창에 심는다.
W_END=$(numsp "$(QD "SET NOCOUNT ON;
SELECT CONVERT(varchar(23), DATEADD(minute, $(( BATCH_MIN * ROUNDS )), CAST('$W_START' AS DATETIME2(3))), 121);")")
# 사고를 창의 **끝 가까이**에 둔다. 늦게 도착하는 행은 대개 경계 근처다.
# 처음에는 창 한가운데(+10분)에 뒀는데, 그러면 10분짜리 지연 워터마크로는 거기까지
# 못 물러나 C 도 B 와 똑같이 놓쳤다. 그것은 지연이 소용없다는 뜻이 아니라
# **지연 폭이 도착 지연보다 커야 한다**는 뜻이고, 실험이 그 조건을 안 만든 것이었다.
LATE_GAP=5   # 창 끝에서 이만큼 앞
INCIDENT_AT=$(numsp "$(QD "SET NOCOUNT ON;
SELECT CONVERT(varchar(23), DATEADD(minute, $(( BATCH_MIN * 3 - LATE_GAP )), CAST('$W_START' AS DATETIME2(3))), 121);")")

QDX "SET NOCOUNT ON;
DELETE FROM currency_ledger WHERE created_at >= '$W_START' AND created_at < '$W_END';
WITH a AS (SELECT TOP (3000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
             FROM sys.all_objects x CROSS JOIN sys.all_objects y)
INSERT INTO currency_ledger WITH (TABLOCK) (account_id, delta, reason, ref_id, created_at)
SELECT 2000000 + rn, 300, 1, 2100000000 + rn,
       DATEADD(minute, (rn * 7) % $(( BATCH_MIN * ROUNDS )), '$W_START')
  FROM a;" || exit 2

# 사고. 계정 40개가 같은 참조로 두 번씩 받았다.
QDX "SET NOCOUNT ON;
WITH a AS (SELECT TOP (40) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
             FROM sys.all_objects)
INSERT INTO currency_ledger (account_id, delta, reason, ref_id, created_at)
SELECT 2500000 + rn, 300, 1, 2200000000 + rn, '$INCIDENT_AT' FROM a;
WITH a AS (SELECT TOP (40) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
             FROM sys.all_objects)
INSERT INTO currency_ledger (account_id, delta, reason, ref_id, created_at)
SELECT 2500000 + rn, 300, 1, 2200000000 + rn, '$INCIDENT_AT' FROM a;" || exit 2
QD "UPDATE STATISTICS currency_ledger WITH FULLSCAN;" >/dev/null

echo "  사고는 ${INCIDENT_AT} 에 있습니다. 계정 40개가 같은 참조로 두 번씩 받았습니다."
echo "  세 번째 창이 끝나기 ${LATE_GAP}분 전이라, 지연 워터마크 10분이면 다시 읽는 범위에 듭니다."
echo

: > "$OUT/scheduled.csv"
echo "mode,round,window_start,scanned,raised,total_alerts" >> "$OUT/scheduled.csv"

run_mode(){ # $1=라벨 $2=lag 분 $3=늦게 도착시킬지(Y/N)
  local label=$1 lag=$2 late=$3
  QDX "SET NOCOUNT ON;
  DELETE FROM detect_alert;
  DELETE FROM detect_state;
  INSERT INTO detect_state (name, watermark) VALUES ('ledger_scan', '$W_START');" || return 2
  # 늦게 도착하는 행을 만든다. 이미 지나간 시각으로 나중에 들어오는 지급이다.
  [ "$late" = "Y" ] && QD "DELETE FROM currency_ledger
     WHERE reason = 1 AND created_at = '$INCIDENT_AT' AND account_id >= 2500000
       AND ledger_id IN (SELECT MAX(ledger_id) FROM currency_ledger
                          WHERE reason = 1 AND created_at = '$INCIDENT_AT' AND account_id >= 2500000
                          GROUP BY account_id);" >/dev/null

  echo "### $label"
  printf "  %-8s %-24s %-10s %-10s %s\n" "회차" "창 시작" "읽은 행" "새 경보" "누적 경보"
  local r
  for r in $(seq 1 "$ROUNDS"); do
    local wm; wm=$(numsp "$(QD "SET NOCOUNT ON;
      SELECT CONVERT(varchar(23), watermark, 121) FROM detect_state WHERE name='ledger_scan';")")
    local o; o=$(QD "SET NOCOUNT ON;
      DECLARE @s INT, @a INT;
      EXEC usp_ScanWindow @minutes = $BATCH_MIN, @lag_minutes = $lag, @scanned = @s OUTPUT, @raised = @a OUTPUT;
      SELECT CAST(@s AS varchar(12)) + ',' + CAST(@a AS varchar(12));")
    IFS=, read -r sc ra <<<"$(num "$o")"
    # 세 번째 회차가 끝난 뒤 늦은 행이 도착한다.
    if [ "$late" = "Y" ] && [ "$r" = "3" ]; then
      QD "SET NOCOUNT ON;
      WITH a AS (SELECT TOP (40) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn FROM sys.all_objects)
      INSERT INTO currency_ledger (account_id, delta, reason, ref_id, created_at)
      SELECT 2500000 + rn, 300, 1, 2200000000 + rn, '$INCIDENT_AT' FROM a;" >/dev/null
      echo "    (여기서 늦게 도착한 지급 40건이 들어옵니다)"
    fi
    local tot; tot=$(num "$(QD "SELECT COUNT(*) FROM detect_alert")")
    printf "  %-8s %-24s %-10s %-10s %s\n" "$r" "$wm" "${sc:-0}" "${ra:-0}" "$tot"
    echo "\"$label\",$r,\"$wm\",${sc:-0},${ra:-0},$tot" >> "$OUT/scheduled.csv"
  done
  local final; final=$(num "$(QD "SELECT COUNT(*) FROM detect_alert")")
  echo "  최종 경보 ${final}건 (기대 40건)"
  echo
  LAST_FINAL="$final"
}

run_mode "A 워터마크만, 늦은 도착 없음" 0 N
A_FINAL="$LAST_FINAL"
run_mode "B 워터마크만, 늦은 도착 있음" 0 Y
B_FINAL="$LAST_FINAL"
run_mode "C 워터마크를 10분 물려 둠, 늦은 도착 있음" 10 Y
C_FINAL="$LAST_FINAL"

# 정리
QD "DELETE FROM currency_ledger WHERE created_at >= '$W_START' AND created_at < '$W_END';
    DROP TABLE IF EXISTS detect_alert; DROP TABLE IF EXISTS detect_state;
    DROP PROCEDURE IF EXISTS usp_ScanWindow;" >/dev/null
QD "UPDATE STATISTICS currency_ledger WITH FULLSCAN;" >/dev/null

echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
printf "  %-40s %s\n" "A 늦은 도착이 없으면" "${A_FINAL}/40"
printf "  %-40s %s\n" "B 늦은 도착이 있으면" "${B_FINAL}/40"
printf "  %-40s %s\n" "C 워터마크를 물려 두면" "${C_FINAL}/40"
echo
echo "  **A 는 사고가 든 회차에서 정확히 잡습니다.** 창을 밀며 도는 것만으로 됩니다."
echo "  회차마다 새 경보만 세므로 같은 사고를 두 번 알리지 않습니다. 유일 제약이"
echo "  (탐지기, 계정, 참조)로 걸려 있어 배치를 다시 돌려도 중복이 안 쌓입니다."
echo
if [ "${B_FINAL:-0}" -lt "${C_FINAL:-0}" ]; then
  echo "  **B 가 놓칩니다.** 배치가 그 창을 지나간 뒤에 같은 시각의 행이 도착했고,"
  echo "  워터마크는 이미 그 앞에 있어 다시 안 봅니다. **오류도 경보도 없이 사라집니다.**"
  echo "  created_at 은 그 일이 일어난 시각이지 DB 에 도착한 시각이 아닙니다."
  echo "  둘의 순서가 다를 수 있다는 것이 이 구멍의 뿌리입니다."
  echo
  echo "  **C 는 워터마크를 창 끝이 아니라 10분 뒤로 물려 둡니다.** 매번 겹치는 구간을"
  echo "  다시 읽으므로 늦게 온 행을 잡습니다. 다시 읽어도 유일 제약이 중복 경보를"
  echo "  막아 주기 때문에 겹쳐 읽는 것이 안전합니다."
  echo
  echo "  다만 **지연 폭이 도착 지연보다 넓어야 합니다.** 처음에 사고를 창 한가운데"
  echo "  두었을 때는 10분 지연으로 못 물러나 C 도 놓쳤습니다. 얼마나 늦게 도착하는지"
  echo "  모르면 그 폭을 정할 수 없고, 그것은 **DB 가 아니라 지급 경로가 답할 문제**입니다."
else
  echo "  이 회차에서는 B 와 C 가 갈리지 않았습니다. 사고가 창 끝에서 ${LATE_GAP}분 앞인데"
  echo "  지연 폭이 그보다 작으면 C 도 못 물러납니다. **지연 워터마크는 도착 지연보다"
  echo "  넓어야 값을 합니다.** 이 회차는 그 조건을 못 맞춘 것입니다."
fi
echo
echo "  운영으로 옮기면 이렇게 됩니다."
echo
echo "    워터마크를 표에 두고 **경보 기록과 같은 트랜잭션에서** 옮긴다"
echo "    워터마크를 창 끝이 아니라 **도착 지연보다 넓게 물려** 둔다. 겹쳐 읽는다"
echo "    같은 사고의 정의를 유일 제약으로 못 박는다. 겹쳐 읽어도 중복이 안 쌓인다"
echo "    경보는 조사 대상이지 회수 근거가 아니다. 근거는 이 세션의 대사 쿼리가 만든다"
echo
echo "  마지막 줄이 중요합니다. 주기 배치가 하는 일은 **사람을 부르는 것**까지입니다."
echo "  실험 2와 9가 보인 대로 회수 근거는 결정론적 대사에서 나와야 하고, 그것은"
echo "  경보를 받은 뒤에 사람이 창을 정해 돌리는 쿼리입니다."
} 2>&1 | tee "$OUT/exp14-scheduled-detect.txt"
