#!/usr/bin/env bash
# 8절의 운영 체크리스트를 실제로 도는 파이프라인으로 옮긴다.
#
# 그동안 "체크리스트로 적었을 뿐 자동 복원 리허설은 다음 과제"라고 적어 뒀다.
# 체크리스트는 지키는 사람이 있어야 지켜지고, 사람은 사고 당일에만 확인한다.
# 그래서 코드로 옮긴다.
#
# 이 스크립트가 하는 일은 하나다. **백업을 믿지 않고 매번 되살려 본다.**
#   1) 백업을 뜬다
#   2) 그 백업이 비어 있지 않은지 본다
#   3) 격리된 인스턴스에 복원한다
#   4) 복원된 데이터가 원본과 같은지 행 수와 체크섬으로 대조한다
#   5) binlog 가 백업 대상인지, 만료가 백업 주기보다 긴지 본다
#   6) 복구 도구가 그 환경에 있는지 본다
#   7) 여기까지 걸린 시간이 RTO 안인지 본다
#
# 그리고 **일부러 망가뜨린 백업을 같이 넣는다.** 검사가 통과만 시키면 검사가 아니다.
# 각 검사가 실제로 걸리는 것을 보여야 그 검사를 믿을 수 있다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
WORK="$OUT/verify-work"; rm -rf "$WORK"; mkdir -p "$WORK"

SRC=a23-mysql          # 원본
DST=a23-restore        # 복원 대상(격리)
ROWS=${ROWS:-200000}
RTO_BUDGET=${RTO_BUDGET:-60}   # 초. 이 안에 못 끝나면 실패로 본다.

M(){ docker exec -i "$1" mysql -uroot -plab -N -B -e "$2" 2>/dev/null; }
MD(){ docker exec -i "$1" mysql -uroot -plab 2>&1; }

ready(){ [ "$(M "$1" 'SELECT 1')" = "1" ]; }
for _ in $(seq 1 90); do ready "$SRC" && ready "$DST" && break; sleep 2; done
ready "$SRC" || { echo "중단: $SRC 가 쿼리를 못 받습니다" >&2; exit 2; }
ready "$DST" || { echo "중단: $DST 가 쿼리를 못 받습니다" >&2; exit 2; }

PASS=0; FAIL=0
say(){ printf "  %-46s %s\n" "$1" "$2"; }
ok(){   PASS=$((PASS+1)); say "$1" "통과 · $2"; }
ng(){   FAIL=$((FAIL+1)); say "$1" "걸림 · $2"; }

{
echo "# 백업 검증 파이프라인"
echo "# MySQL $(M "$SRC" 'SELECT VERSION()'), 원본 ${SRC}, 복원 대상 ${DST}"
echo "# ${ROWS}행, RTO 예산 ${RTO_BUDGET}초"
echo
echo "  8절 체크리스트를 코드로 옮겼습니다. 각 항목이 실제로 걸리는지까지 보려고"
echo "  일부러 망가뜨린 백업을 같이 넣습니다. 통과만 시키는 검사는 검사가 아닙니다."
echo

# ── 원본 준비 ────────────────────────────────────────────────────────────
M "$SRC" "DROP DATABASE IF EXISTS verify; CREATE DATABASE verify"
M "$SRC" "CREATE TABLE verify.t (id BIGINT PRIMARY KEY, amount INT NOT NULL, memo VARCHAR(64))"
# 재귀 CTE 는 cte_max_recursion_depth(기본 1000)에 막힌다. 처음에 그 설정 없이
# 돌렸더니 적재가 0행으로 끝났고, 그런데도 아래 검사가 전부 "걸림"으로 나와
# 파이프라인이 잘 도는 것처럼 보였다. 원본이 비었으니 당연히 다 안 맞은 것이다.
# **이 스크립트가 잡으려던 함정을 이 스크립트가 밟았다.** 세션마다 다시 나는 유형이라
# 적재 직후에 행 수를 확인하고, 안 맞으면 그 자리에서 멈춘다.
M "$SRC" "SET SESSION cte_max_recursion_depth = ${ROWS} + 10;
          INSERT INTO verify.t (id, amount, memo)
          WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < ${ROWS})
          SELECT n, n % 9973, CONCAT('m', n) FROM s"
SRC_ROWS=$(M "$SRC" "SELECT COUNT(*) FROM verify.t")
if [ "${SRC_ROWS:-0}" -ne "$ROWS" ]; then
  echo "중단: 원본 적재가 ${SRC_ROWS:-0}행입니다(기대 ${ROWS}). 이 상태로 검사하면" >&2
  echo "      모든 대조가 '안 맞음'으로 나와 파이프라인이 도는 것처럼 보입니다." >&2
  exit 2
fi
SRC_SUM=$(M "$SRC" "SELECT COALESCE(SUM(amount),0) FROM verify.t")
SRC_CKS=$(M "$SRC" "CHECKSUM TABLE verify.t" | awk '{print $2}')
echo "  원본 ${SRC_ROWS}행, 합계 ${SRC_SUM}, 체크섬 ${SRC_CKS}"
echo

T_START=$(date +%s%N)

# ── 1) 백업을 뜬다 ───────────────────────────────────────────────────────
echo "## 1) 백업"
docker exec "$SRC" mysqldump -uroot -plab --single-transaction --set-gtid-purged=OFF \
  --databases verify > "$WORK/good.sql" 2>/dev/null
GOOD=$(wc -c < "$WORK/good.sql" | tr -d ' ')
# 망가뜨린 것 셋. 각각 다른 검사에 걸려야 한다.
: > "$WORK/empty.sql"                                    # 비어 있음
head -c 4000 "$WORK/good.sql" > "$WORK/truncated.sql"    # 중간에 잘림
sed 's/^INSERT INTO/-- INSERT INTO/' "$WORK/good.sql" > "$WORK/norows.sql"  # 스키마만
say "정상 백업" "${GOOD} 바이트"
echo

# ── 2) 백업이 비어 있지 않은가 ───────────────────────────────────────────
echo "## 2) 백업이 비어 있지 않은가"
MIN=$(( GOOD / 2 ))
for f in good empty truncated norows; do
  sz=$(wc -c < "$WORK/$f.sql" | tr -d ' ')
  if [ "$sz" -ge "$MIN" ]; then ok "크기 임계 ${MIN}B · $f" "${sz}B"
  else ng "크기 임계 ${MIN}B · $f" "${sz}B"; fi
done
echo "  임계는 직전 정상 백업의 절반으로 잡았습니다. 절대값으로 잡으면 데이터가"
echo "  늘어날 때 임계가 따라가지 못해 조용히 무의미해집니다."
echo

# ── 3) 복원이 되는가 ─────────────────────────────────────────────────────
echo "## 3) 격리된 인스턴스에 복원이 되는가"
restore(){  # $1=파일 이름표. 성공하면 0
  M "$DST" "DROP DATABASE IF EXISTS verify" >/dev/null 2>&1
  M "$DST" "RESET BINARY LOGS AND GTIDS" >/dev/null 2>&1
  local err
  err=$(MD "$DST" < "$WORK/$1.sql")
  case "$err" in *ERROR*) return 1 ;; esac
  return 0
}
for f in good empty truncated norows; do
  if restore "$f"; then ok "복원 실행 · $f" "에러 없음"
  else ng "복원 실행 · $f" "에러"; fi
done
echo "  잘린 덤프는 여기서 걸립니다. 빈 덤프와 스키마만 있는 덤프는 통과합니다."
echo "  **복원이 에러 없이 끝난 것과 데이터가 있는 것은 다릅니다.** 다음 검사가 그 자리입니다."
echo

# ── 4) 복원된 데이터가 맞는가 ────────────────────────────────────────────
echo "## 4) 복원된 데이터가 원본과 같은가"
for f in good empty truncated norows; do
  restore "$f" >/dev/null 2>&1
  r=$(M "$DST" "SELECT COUNT(*) FROM verify.t" 2>/dev/null); r=${r:-0}
  s=$(M "$DST" "SELECT COALESCE(SUM(amount),0) FROM verify.t" 2>/dev/null); s=${s:-0}
  c=$(M "$DST" "CHECKSUM TABLE verify.t" 2>/dev/null | awk '{print $2}'); c=${c:-none}
  if [ "$r" = "$SRC_ROWS" ] && [ "$s" = "$SRC_SUM" ] && [ "$c" = "$SRC_CKS" ]; then
    ok "행 수·합계·체크섬 · $f" "${r}행 체크섬 일치"
  else
    ng "행 수·합계·체크섬 · $f" "${r}행 (원본 ${SRC_ROWS})"
  fi
done
echo "  **행 수를 '0보다 큰가'로 보면 안 됩니다.** 정확히 같은지 봐야 합니다."
echo "  이 랩이 10절에서 그 자리를 밟았습니다. GTID 충돌로 복원이 중간에 멈췄는데"
echo "  종료 코드가 0 이라 '복원 0.06초' 라는 아주 좋아 보이는 값이 남았습니다."
echo

# ── 5) binlog 가 백업 대상인가, 만료가 백업 주기보다 긴가 ────────────────
echo "## 5) binlog"
LOGBIN=$(M "$SRC" "SELECT @@log_bin")
EXPIRE=$(M "$SRC" "SELECT @@binlog_expire_logs_seconds")
BACKUP_CYCLE=${BACKUP_CYCLE:-86400}
[ "$LOGBIN" = "1" ] && ok "log_bin 켜짐" "RPO 를 백업 주기 밑으로 내릴 수 있음" \
                    || ng "log_bin 켜짐" "꺼져 있으면 RPO = 백업 주기"
if [ "${EXPIRE:-0}" -gt "$BACKUP_CYCLE" ]; then
  ok "binlog 만료 > 백업 주기" "${EXPIRE}초 > ${BACKUP_CYCLE}초"
else
  ng "binlog 만료 > 백업 주기" "${EXPIRE}초 <= ${BACKUP_CYCLE}초 · 사이가 빈다"
fi
echo

# ── 6) 복구 도구가 그 환경에 있는가 ──────────────────────────────────────
echo "## 6) 복구 도구가 그 환경에 있는가"
for tool in mysqldump mysql mysqlbinlog; do
  if docker exec "$DST" sh -c "command -v $tool >/dev/null 2>&1"; then
    ok "$tool" "복원 대상에 있음"
  else
    ng "$tool" "복원 대상에 없음"
  fi
done
echo "  이 랩이 4절 함정 2에서 밟은 자리입니다. \`mysql:8.4\` 이미지에 \`mysqlbinlog\` 가"
echo "  없고, 그 사실이 사고 당일에 드러나면 늦습니다."
echo

# ── 7) 여기까지가 RTO 안인가 ─────────────────────────────────────────────
echo "## 7) 복구 시간이 RTO 안인가"
restore good >/dev/null 2>&1
T_END=$(date +%s%N)
ELAPSED=$(echo "scale=1; ($T_END - $T_START) / 1000000000" | bc)
if [ "$(echo "$ELAPSED <= $RTO_BUDGET" | bc)" = "1" ]; then
  ok "리허설 전체 소요" "${ELAPSED}초 <= 예산 ${RTO_BUDGET}초"
else
  ng "리허설 전체 소요" "${ELAPSED}초 > 예산 ${RTO_BUDGET}초"
fi
echo "  이 값은 추정이 아니라 방금 실제로 되살려 본 시간입니다."
echo

echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo "  통과 ${PASS}건, 걸림 ${FAIL}건."
echo
echo "  걸림이 0 이면 이 파이프라인을 의심해야 합니다. 망가뜨린 백업 셋을 일부러"
echo "  넣었으므로 걸림이 나오는 것이 정상입니다. **검사가 통과만 시키면 그 검사는**"
echo "  **아무것도 안 지키고 있는 것입니다.**"
echo
echo "  망가진 백업이 어느 검사에 걸리는지 정리하면 이렇습니다."
printf "  %-14s %-12s %-12s %-12s\n" "백업" "크기" "복원 실행" "데이터 대조"
printf "  %-14s %-12s %-12s %-12s\n" "정상" "통과" "통과" "통과"
printf "  %-14s %-12s %-12s %-12s\n" "빈 파일" "걸림" "통과" "걸림"
printf "  %-14s %-12s %-12s %-12s\n" "중간에 잘림" "걸림" "걸림" "걸림"
printf "  %-14s %-12s %-12s %-12s\n" "스키마만" "걸림" "통과" "걸림"
echo
echo "  **빈 파일과 스키마만 있는 덤프는 복원 실행을 통과합니다.** 크기 검사와"
echo "  데이터 대조가 없으면 그 둘이 정상 백업으로 기록됩니다. 세 검사가 서로를"
echo "  대신하지 못한다는 뜻입니다."
echo
echo "  이 실행은 1회입니다."
} 2>&1 | tee "$OUT/exp10-verify-pipeline.txt"
