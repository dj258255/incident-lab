#!/usr/bin/env bash
# 실험 15. 짝은 맞는데 한도만 넘긴 사고는 대사로 안 잡힌다.
#
# 실험 2 가 만든 사고는 "같은 ref_id 에 지급이 여러 건 붙는" 모양이었다. 그것은
# 지급 쪽이 고장 난 사고다. 그런데 2023년 아르곤 섬 사건의 공개된 설명은 다르다.
#
#   "다수의 계정을 이용하여 비정상적인 방법으로 채널을 반복 재생성하여 보상을 획득"
#
# 채널을 새로 만들면 석상이 새로 생기고, 그 석상을 완성해 상자를 얻고 정상적으로
# 연다. 원장에는 개봉도 지급도 각각 늘어나고 **짝은 전부 맞는다.** 이상한 것은
# 횟수뿐이다. 정상 규칙이 "석상은 매일 1회" 였고, 6월 7일 업데이트로 "원정대당
# 1회" 가 됐다.
#
# 그러면 실험 2 의 대사 계열은 이 사고를 못 잡는다. 짝이 맞으니까. 공지가
# "3,806회 분량" 이라고 회 단위로 셀 수 있었던 근거는 대사가 아니라 **명시된 한도**다.
#
# 재는 것은 검사 넷의 적발과 오탐이다. 조사 성능이 아니라 **정확도**가 주제이므로
# 규모는 작게 두고 표를 따로 만든다. 처음에는 실험 1 의 2,000만 행 원장에 얹었는데,
# account_id 에 인덱스가 없어 지우고 심는 것만으로 전체 스캔이 돌았고 Msg 802
# (버퍼 풀 메모리 부족)로 중단됐다. 정확도를 재는 데 그 규모가 필요하지도 않다.
# 조사 쿼리가 얼마나 읽는지는 실험 4 가 그 원장에서 따로 잰다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

QUOTA_BOX=9            # 하루 1회 상자(얼음 석상의 귀중품 상자 자리)
DAILY_LIMIT=1          # 그 상자의 하루 한도
Q_NORMAL=${Q_NORMAL:-5000}   # 이 상자를 여는 정상 계정
Q_HEAVY=${Q_HEAVY:-40}       # 매일 빠짐없이 1회씩 여는 성실 계정. 한도는 안 넘는다
Q_ABUSE=${Q_ABUSE:-50}       # 어뷰저
ABUSE_DAYS=${ABUSE_DAYS:-3}  # 어뷰저가 몰아서 연 날 수
ABUSE_PER_DAY=${ABUSE_PER_DAY:-12}   # 그날 하루에 연 횟수
SPAN_DAYS=30
BASE='2026-06-28 00:00:00'

wait_ready || exit 2

{
echo "# 실험 15. 짝은 맞는데 한도만 넘긴 사고"
echo "# $(num "$(Q "SELECT LEFT(@@VERSION, 46)")")"
echo
echo "  box_id = ${QUOTA_BOX} 를 하루 ${DAILY_LIMIT}회 상자로 둡니다. ${SPAN_DAYS}일 치입니다."
echo "  정상 ${Q_NORMAL}개 · 매일 여는 성실 계정 ${Q_HEAVY}개 · 어뷰저 ${Q_ABUSE}개."
echo "  어뷰저는 ${ABUSE_DAYS}일 동안 하루 ${ABUSE_PER_DAY}회씩 엽니다. 개봉마다 지급은 1건씩 정상입니다."
echo "  실험 1 의 원장은 건드리지 않습니다. 정확도만 재므로 표를 따로 씁니다."
echo

# ── 심기 ──────────────────────────────────────────────────────────────────
# 실험 1 과 같은 스키마를 쓰되 표는 따로 둔다. DROP 이라 다시 돌려도 같은 결과가 나온다.
QDX "SET NOCOUNT ON;
DROP TABLE IF EXISTS q_currency_ledger;
DROP TABLE IF EXISTS q_box_open_log;
DROP TABLE IF EXISTS truth_quota;

CREATE TABLE q_box_open_log (
    open_id    BIGINT       NOT NULL,
    account_id INT          NOT NULL,
    box_id     INT          NOT NULL,
    opened_at  DATETIME2(3) NOT NULL,
    CONSTRAINT PK_q_box_open_log PRIMARY KEY CLUSTERED (open_id)
);
CREATE TABLE q_currency_ledger (
    ledger_id  BIGINT IDENTITY(1,1) NOT NULL,
    account_id INT          NOT NULL,
    delta      BIGINT       NOT NULL,
    reason     TINYINT      NOT NULL,
    ref_id     BIGINT       NULL,
    created_at DATETIME2(3) NOT NULL,
    CONSTRAINT PK_q_currency_ledger PRIMARY KEY CLUSTERED (ledger_id)
);
-- 정답지. 조사 쿼리는 이 표를 안 본다.
CREATE TABLE truth_quota (account_id INT PRIMARY KEY, over_opens INT NOT NULL);" || exit 2

echo "## 15-1. 정상 계정 — 한도 안에서 띄엄띄엄"
# 계정마다 여는 날이 다르고, 한 날에 한 번만 연다.
QDX "SET NOCOUNT ON;
WITH a AS (SELECT TOP ($Q_NORMAL) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS ai
             FROM sys.all_objects x CROSS JOIN sys.all_objects y),
     d AS (SELECT TOP ($SPAN_DAYS) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS di
             FROM sys.all_objects)
INSERT INTO q_box_open_log (open_id, account_id, box_id, opened_at)
SELECT a.ai * $SPAN_DAYS + d.di + 1,
       600001 + a.ai,
       $QUOTA_BOX,
       DATEADD(minute, (a.ai * 7 + d.di * 13) % 1440, DATEADD(day, d.di, '$BASE'))
  FROM a CROSS JOIN d
 WHERE d.di % 9 = a.ai % 9;" || exit 2

echo "## 15-2. 성실 계정 — 30일 내내 매일 1회 (한도는 안 넘김)"
QDX "SET NOCOUNT ON;
DECLARE @b BIGINT = $(( Q_NORMAL * SPAN_DAYS + 1000 ));
WITH a AS (SELECT TOP ($Q_HEAVY) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS ai
             FROM sys.all_objects),
     d AS (SELECT TOP ($SPAN_DAYS) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS di
             FROM sys.all_objects)
INSERT INTO q_box_open_log (open_id, account_id, box_id, opened_at)
SELECT @b + a.ai * $SPAN_DAYS + d.di,
       610001 + a.ai,
       $QUOTA_BOX,
       DATEADD(minute, (a.ai * 11 + d.di * 17) % 1440, DATEADD(day, d.di, '$BASE'))
  FROM a CROSS JOIN d;" || exit 2

echo "## 15-3. 어뷰저 — 채널을 다시 만들어 같은 날 여러 번"
QDX "SET NOCOUNT ON;
DECLARE @b BIGINT = $(( (Q_NORMAL + Q_HEAVY + 100) * SPAN_DAYS + 2000 ));
WITH a AS (SELECT TOP ($Q_ABUSE) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS ai
             FROM sys.all_objects),
     d AS (SELECT TOP ($ABUSE_DAYS)     ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS di
             FROM sys.all_objects),
     k AS (SELECT TOP ($ABUSE_PER_DAY)  ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS ki
             FROM sys.all_objects)
INSERT INTO q_box_open_log (open_id, account_id, box_id, opened_at)
SELECT @b + a.ai * ($ABUSE_DAYS * $ABUSE_PER_DAY) + d.di * $ABUSE_PER_DAY + k.ki,
       620001 + a.ai,
       $QUOTA_BOX,
       DATEADD(minute, (a.ai * 3 + k.ki * 37) % 1440, DATEADD(day, d.di * 5 + 2, '$BASE'))
  FROM a CROSS JOIN d CROSS JOIN k;" || exit 2

echo "## 15-4. 지급 — 개봉 1건에 지급 1건. 전부 짝이 맞습니다"
QDX "SET NOCOUNT ON;
INSERT INTO q_currency_ledger (account_id, delta, reason, ref_id, created_at)
SELECT b.account_id, ((b.open_id % 7) + 1) * 100, 1, b.open_id, b.opened_at
  FROM q_box_open_log b;" || exit 2

QDX "SET NOCOUNT ON;
INSERT INTO truth_quota (account_id, over_opens)
SELECT account_id, SUM(c - $DAILY_LIMIT)
  FROM (SELECT account_id, CAST(opened_at AS DATE) AS d, COUNT(*) AS c
          FROM q_box_open_log
         WHERE box_id = $QUOTA_BOX AND account_id >= 620001
         GROUP BY account_id, CAST(opened_at AS DATE)) t
 WHERE c > $DAILY_LIMIT
 GROUP BY account_id;" || exit 2

OPENS_N=$(num "$(QD "SELECT COUNT(*) FROM q_box_open_log")")
LEDG_N=$(num "$(QD "SELECT COUNT(*) FROM q_currency_ledger")")
printf "  %-26s %s\n" "개봉" "${OPENS_N}행"
printf "  %-26s %s\n" "지급" "${LEDG_N}행"
printf "  %-26s %s\n" "개봉 수 = 지급 수" "$( [ "$OPENS_N" = "$LEDG_N" ] && echo YES || echo NO )"
TRUTH=$(num "$(QD "SELECT COUNT(*) FROM truth_quota")")
OVER=$(num "$(QD "SELECT ISNULL(SUM(over_opens),0) FROM truth_quota")")
printf "  %-26s %s\n" "정답지" "어뷰저 ${TRUTH}개 계정 · 한도 초과 ${OVER}회"
[ "${TRUTH:-0}" -gt 0 ] || { echo "중단: 정답지가 비었습니다" >&2; exit 2; }
echo

# ── 검사 넷 ───────────────────────────────────────────────────────────────
# 실험 2 의 score() 와 같은 틀이되 정답지가 truth_quota 다.
score(){   # $1=라벨  $2=#found (account_id) 를 채우는 SQL
  local label=$1 sql=$2 r
  r=$(QD "SET NOCOUNT ON;
  DROP TABLE IF EXISTS #found;
  CREATE TABLE #found (account_id INT PRIMARY KEY);
  $sql
  SELECT CAST((SELECT COUNT(*) FROM #found f JOIN truth_quota t ON t.account_id = f.account_id) AS varchar(12))
       + ',' + CAST((SELECT COUNT(*) FROM #found) AS varchar(12))
       + ',' + CAST((SELECT COUNT(*) FROM truth_quota t
                      WHERE NOT EXISTS (SELECT 1 FROM #found f WHERE f.account_id = t.account_id)) AS varchar(12));")
  if echo "$r" | grep -qE '^(Msg|메시지) [0-9]+'; then
    printf "  %-14s %s\n" "$label" "**질의 실패**"
    echo "$r" | grep -E '^(Msg|메시지)' | head -2
    return
  fi
  local v hit tot miss fp
  v=$(echo "$r" | head -1 | tr -d ' \r')
  hit=$(echo "$v" | cut -d, -f1); tot=$(echo "$v" | cut -d, -f2); miss=$(echo "$v" | cut -d, -f3)
  fp=$(( tot - hit ))
  printf "  %-14s %-8s %-10s %-8s %s\n" "$label" "${tot}개" "${hit}/${TRUTH}" "${miss}개" "${fp}개"
}

echo "## 15-5. 검사 넷을 겨룹니다"
printf "  %-14s %-8s %-10s %-8s %s\n" "방법" "지목" "적발" "놓침" "오탐"

# A 참조 대사 — 같은 ref_id 에 지급이 두 건 이상 붙었나
score "A 참조 대사" "
INSERT INTO #found (account_id)
SELECT DISTINCT account_id FROM (
  SELECT l.account_id, l.ref_id
    FROM q_currency_ledger l
   WHERE l.reason = 1 AND l.ref_id IS NOT NULL
   GROUP BY l.account_id, l.ref_id
  HAVING COUNT(*) > 1) t;"

# C 개봉 대사 — 개봉 수와 지급 수가 맞나
score "C 개봉 대사" "
INSERT INTO #found (account_id)
SELECT o.account_id
  FROM (SELECT account_id, COUNT(*) c FROM q_box_open_log
         WHERE box_id = $QUOTA_BOX GROUP BY account_id) o
  JOIN (SELECT account_id, COUNT(*) c FROM q_currency_ledger
         WHERE reason = 1 GROUP BY account_id) g
    ON g.account_id = o.account_id
 WHERE g.c <> o.c;"

# B 통계 이탈 — 총 획득량이 평균에서 3시그마를 넘나
score "B 통계 이탈" "
DECLARE @m FLOAT, @s FLOAT;
SELECT @m = AVG(CAST(v AS FLOAT)), @s = STDEV(CAST(v AS FLOAT))
  FROM (SELECT account_id, SUM(delta) v FROM q_currency_ledger
         WHERE reason = 1 GROUP BY account_id) t;
INSERT INTO #found (account_id)
SELECT account_id FROM (SELECT account_id, SUM(delta) v FROM q_currency_ledger
         WHERE reason = 1 GROUP BY account_id) t
 WHERE CAST(v AS FLOAT) > @m + 3 * @s;"

# D 한도 초과 — 하루 1회인 상자를 같은 날 두 번 이상 열었나
score "D 한도 초과" "
INSERT INTO #found (account_id)
SELECT DISTINCT account_id
  FROM (SELECT account_id, CAST(opened_at AS DATE) d, COUNT(*) c
          FROM q_box_open_log
         WHERE box_id = $QUOTA_BOX
         GROUP BY account_id, CAST(opened_at AS DATE)) t
 WHERE c > $DAILY_LIMIT;"

echo
echo "## 15-6. 회수 규모는 한도가 정합니다"
# 한도가 있으면 회수 대상을 "회" 로 셀 수 있다. 공지의 3,806회가 그 단위다.
CALC=$(QD "SET NOCOUNT ON;
WITH per AS (SELECT account_id, CAST(opened_at AS DATE) d, COUNT(*) c
               FROM q_box_open_log WHERE box_id = $QUOTA_BOX
              GROUP BY account_id, CAST(opened_at AS DATE))
SELECT CAST(COUNT(DISTINCT account_id) AS varchar(12)) + ',' + CAST(SUM(c - $DAILY_LIMIT) AS varchar(12))
  FROM per WHERE c > $DAILY_LIMIT;")
C_ACC=$(echo "$CALC" | head -1 | tr -d ' \r' | cut -d, -f1)
C_OVER=$(echo "$CALC" | head -1 | tr -d ' \r' | cut -d, -f2)
printf "  %-26s %s\n" "산정한 계정" "${C_ACC}개"
printf "  %-26s %s\n" "산정한 한도 초과 개봉" "${C_OVER}회"
printf "  %-26s %s\n" "정답과 일치" "$( [ "$C_ACC" = "$TRUTH" ] && [ "$C_OVER" = "$OVER" ] && echo YES || echo NO )"

echo
echo "## 15-7. 총 획득량으로는 갈리지 않습니다 (N 정상 / C 성실 / D 어뷰저)"
QD "SET NOCOUNT ON;
SELECT CASE WHEN account_id >= 620001 THEN 'D-abuser'
            WHEN account_id >= 610001 THEN 'C-daily  '
            ELSE 'N-normal ' END AS grp,
       COUNT(*) AS accounts, MIN(v) AS min_v, AVG(v) AS avg_v, MAX(v) AS max_v
  FROM (SELECT account_id, SUM(delta) v FROM q_currency_ledger
         WHERE reason = 1 GROUP BY account_id) t
 GROUP BY CASE WHEN account_id >= 620001 THEN 'D-abuser'
               WHEN account_id >= 610001 THEN 'C-daily  '
               ELSE 'N-normal ' END
 ORDER BY 1;" | sed 's/^/  /'

echo
echo "## 15-8. 3시그마 경계가 어디에 떨어졌나"
QD "SET NOCOUNT ON;
DECLARE @m FLOAT, @s FLOAT;
SELECT @m = AVG(CAST(v AS FLOAT)), @s = STDEV(CAST(v AS FLOAT))
  FROM (SELECT account_id, SUM(delta) v FROM q_currency_ledger
         WHERE reason = 1 GROUP BY account_id) t;
SELECT CAST(ROUND(@m,1) AS varchar(20)) AS mean,
       CAST(ROUND(@s,1) AS varchar(20)) AS sd,
       CAST(ROUND(@m + 3*@s,1) AS varchar(20)) AS cut3sigma;" | sed 's/^/  /'
} 2>&1 | tee "$OUT/exp15-quota-breach.txt"
