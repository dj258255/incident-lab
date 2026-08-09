#!/usr/bin/env bash
# 실험 4. 사고가 난 뒤에 인덱스를 만들 수 있는가.
#
# 실험 3은 조사용 인덱스가 있으면 논리 읽기가 229,614 에서 482 로 떨어진다는 것을
# 보였다. 그런데 재화 원장은 평소에 쓰기만 하는 표라 그 인덱스가 없는 경우가 많다.
#
# 그래서 운영 절차서에 "사고 중에 2,000만 행 표에 인덱스를 만드는 것은 그 자체가
# 위험한 작업이다. 평소 비용과 사고 때 전체를 읽는 비용을 견준다"고 적어 두었다.
# **견주라고 해 놓고 견줄 근거를 안 줬다.** 이 실험이 그 자리를 채운다.
#
# 조건 둘이다. 만드는 인덱스는 같고 옵션만 다르다.
#   OFF  기본. 만드는 동안 표에 공유 락(S)이 걸려 쓰기가 막힌다
#   ON   온라인 빌드. Developer·Enterprise 에서만 된다
#
# 인덱스를 만드는 동안 원장에 쓰면서 몇 번이나 막히는지 센다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"

wait_ready || exit 2
LEDGER=$(grep '^currency_ledger_rows,' "$OUT/dataset.csv" | cut -d, -f2)
WIN_START=$(grep '^window_start,' "$OUT/dataset.csv" | cut -d, -f2-)
[ -n "$LEDGER" ] || { echo "중단: dataset.csv 가 없습니다. 실험 1을 먼저 돌립니다" >&2; exit 2; }

now_ms(){ python3 -c 'import time;print(int(time.time()*1000))'; }

# 인덱스를 만드는 동안 원장에 계속 쓴다.
#
# 처음에는 조회로 쟀는데 두 조건 다 한 번도 안 막혔다. 오프라인 인덱스 빌드가
# 잡는 것은 스키마 수정 락이 아니라 **공유 락(S)** 이기 때문이다. 읽기는 함께 설 수
# 있고 쓰기만 막힌다. 재화 원장은 append-only 라 사고 중에도 계속 쌓이므로,
# 막히는 쪽을 재려면 탐침이 쓰기여야 한다.
writer_start(){
  rm -f "$OUT/.stop"; : > "$OUT/.reader"
  ( while [ ! -f "$OUT/.stop" ]; do
      t0=$(now_ms)
      docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
        -Q "SET NOCOUNT ON;
            INSERT INTO currency_ledger (account_id, delta, reason, ref_id, created_at)
            VALUES (1, 10, 2, NULL, SYSDATETIME());" >/dev/null 2>&1
      echo $(( $(now_ms) - t0 )) >> "$OUT/.reader"
    done ) &
  READER_PID=$!
}
reader_stop(){ touch "$OUT/.stop"; wait "$READER_PID" 2>/dev/null; rm -f "$OUT/.stop"; }

# 인덱스 빌드가 잡는 락을 표본한다. 어떤 종류인지가 판정의 핵심이다.
locks_start(){
  rm -f "$OUT/.lockstop"; : > "$OUT/.locks"
  ( while [ ! -f "$OUT/.lockstop" ]; do
      docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
        -Q "SET NOCOUNT ON;
            SELECT l.request_mode
              FROM sys.dm_tran_locks l
              JOIN sys.dm_exec_requests r ON r.session_id = l.request_session_id
             WHERE l.resource_type = 'OBJECT'
               AND l.resource_associated_entity_id = OBJECT_ID('currency_ledger')
               AND r.command LIKE '%INDEX%';" 2>/dev/null \
        | grep -E '^(Sch-M|Sch-S|X|S|IX|IS)$' >> "$OUT/.locks"
    done ) &
  LOCK_PID=$!
}
locks_stop(){ touch "$OUT/.lockstop"; wait "$LOCK_PID" 2>/dev/null; rm -f "$OUT/.lockstop"; }

{
echo "# 실험 4. 사고 중에 인덱스를 만들 수 있는가"
echo
echo "  재화 원장 ${LEDGER}행. 만드는 인덱스는 실험 3에서 가장 적게 읽은 것과 같습니다."
echo "  만드는 동안 원장에 계속 쓰면서 몇 번 막히는지 셉니다. 재화 원장은"
echo "  append-only 라 사고 중에도 계속 쌓입니다."
echo
echo "  시간은 적지 않습니다. ARM 에뮬레이션이라 이 호스트의 값이 아닙니다."
echo "  막힌 쓰기 수와 그때 잡힌 락 종류를 봅니다. 둘 다 시간이 아닙니다."
echo

: > "$OUT/index-build.csv"
echo "online,probes,blocked,max_probe_ms,lock_modes,build_ok" >> "$OUT/index-build.csv"
printf "  %-14s %-14s %-12s %-24s %s\n" "ONLINE" "막힌 쓰기" "최대 지연" "빌드가 잡은 테이블 락" "결과"

run_case(){
  local online=$1
  QD "SET QUOTED_IDENTIFIER ON; DROP INDEX IF EXISTS IX_build ON currency_ledger;" >/dev/null
  writer_start; locks_start
  local out
  out=$(QD "SET QUOTED_IDENTIFIER ON;
            SET ANSI_NULLS ON;
            CREATE INDEX IX_build ON currency_ledger (reason, created_at, ref_id)
              INCLUDE (account_id) WITH (ONLINE = $online);")
  locks_stop; reader_stop

  local ok probes blocked maxms modes
  if echo "$out" | grep -qE '^(Msg|메시지) [0-9]+'; then
    ok="**빌드 실패**"; echo "$out" | grep -E '^(Msg|메시지)' | head -1
  else
    ok="빌드 성공"
  fi
  probes=$(awk 'END{print NR+0}' "$OUT/.reader")
  blocked=$(awk '$1>2000{c++} END{print c+0}' "$OUT/.reader")
  maxms=$(sort -n "$OUT/.reader" | tail -1); maxms=${maxms:-0}
  modes=$(sort -u "$OUT/.locks" | tr '\n' ' ' | sed 's/ $//'); modes=${modes:-관측 안 됨}

  printf "  %-14s %-14s %-12s %-24s %s\n" "$online" "${blocked}/${probes}회" "${maxms}ms" "$modes" "$ok"
  echo "$online,$probes,$blocked,$maxms,\"$modes\",$ok" >> "$OUT/index-build.csv"
}

run_case OFF
run_case ON

QD "SET QUOTED_IDENTIFIER ON; DROP INDEX IF EXISTS IX_build ON currency_ledger;" >/dev/null
rm -f "$OUT/.reader" "$OUT/.locks"

echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  기본값(OFF)으로 만들면 빌드가 끝날 때까지 그 표에 **쓰기가 막힙니다.**"
echo "  잡히는 락은 공유 락(S)입니다. 읽기는 함께 설 수 있어 조회는 지나갑니다."
echo "  처음에 조회로 쟀다가 한 번도 안 막혀서 설계를 다시 봤습니다."
echo
echo "  재화 원장은 append-only 라 사고 중에도 계속 쌓입니다. 쓰기가 막히면 그 지급과"
echo "  소모가 전부 줄을 서고, 그것은 서비스가 멈춘 것과 같습니다."
echo
echo "  ONLINE = ON 은 쓰기가 지나갑니다. 잡는 락이 의도 공유(IS)라 쓰기와 함께 설 수"
echo "  있기 때문입니다. 대신 두 가지 대가가 있습니다."
echo "  에디션이 Enterprise 나 Developer 여야 하고, 빌드 중 변경분을 따로 모으느라"
echo "  tempdb 와 트랜잭션 로그를 더 씁니다. 이 랩에서는 그 양을 재지 않았습니다."
echo
echo "  그래서 사고 중 판단은 이렇게 갈립니다."
echo
echo "    ONLINE 이 되는 에디션이다        → 만든다. 쓰기가 안 막힌다"
echo "    Standard 이하다                  → 만들지 않는다. 전체를 읽으며 조사한다"
echo "    조사가 한 번으로 끝난다          → 만들지 않는다. 빌드 비용이 더 크다"
echo "    같은 조사를 여러 번 돌려야 한다  → 만든다"
echo
echo "  운영 절차서가 \"견주라\"고만 적어 두었던 자리에 이 표를 넣습니다."
} 2>&1 | tee "$OUT/exp4-index-build.txt"
