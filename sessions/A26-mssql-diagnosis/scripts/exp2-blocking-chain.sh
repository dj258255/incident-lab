#!/usr/bin/env bash
# 실험 2. 막힌 세션이 아니라 막은 세션을 찾는다.
#
# 대기 통계가 LCK_M_IS 를 가리켰다면 다음 질문은 "누가 막고 있는가" 다.
# 그런데 sys.dm_exec_requests 의 blocking_session_id 를 그냥 보면 **중간 세션**이
# 나온다. A 가 B 를 막고 B 가 C 를 막으면, C 를 조회할 때 나오는 것은 B 다.
# B 를 죽여도 A 가 그대로라 다시 막힌다.
#
# 뿌리를 찾아야 한다. 그리고 뿌리는 보통 아무것도 안 하고 있다. 트랜잭션을 열어
# 둔 채 노는 세션이라 dm_exec_requests 에 아예 안 나온다.
#
# 세 세션으로 사슬을 만들고, 두 방법을 견준다.
#   순진한 조회   blocking_session_id 를 그대로 본다
#   재귀 추적     사슬을 따라 뿌리까지 간다
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
HOLD=${HOLD:-25}

wait_ready || exit 2
setup_db || exit 2

{
echo "# 실험 2. 막은 세션이 아니라 뿌리를 찾는다"
echo
echo "  세 세션으로 사슬을 만듭니다."
echo "    A  트랜잭션을 열고 한 행을 갱신한 뒤 아무것도 안 한다 (뿌리)"
echo "    B  같은 행을 갱신하려다 A 에게 막힌다"
echo "    C  같은 행을 조회하려다 B 뒤에 줄을 선다"
echo

# A: 뿌리. 갱신만 하고 **아무것도 안 한다.**
#
# 처음에는 WAITFOR DELAY 로 버티게 했는데, 그러면 그것이 실행 중인 요청이라
# dm_exec_requests 에 그대로 나온다. 실제 사고의 뿌리는 트랜잭션을 열어 둔 채
# 클라이언트가 노는 세션이다. 배치를 보낸 뒤 표준입력을 열어 둬 연결만 살린다.
( echo "SET NOCOUNT ON;"
  echo "BEGIN TRAN;"
  echo "UPDATE account_currency SET balance = balance - 1 WHERE account_id = 1;"
  echo "GO"
  sleep "$HOLD" ) | docker exec -i "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" >/dev/null 2>&1 &
PA=$!
sleep 4
# B: A 에게 막힌다
docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
  -Q "SET NOCOUNT ON; BEGIN TRAN;
      UPDATE account_currency SET balance = balance - 2 WHERE account_id = 1;
      COMMIT;" >/dev/null 2>&1 &
PB=$!
sleep 3
# C: B 뒤에 줄을 선다
docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" \
  -Q "SELECT balance FROM account_currency WHERE account_id = 1;" >/dev/null 2>&1 &
PC=$!
sleep 4

echo "## 2-1. 순진한 조회"
echo
echo "  막힌 세션마다 blocking_session_id 를 그대로 봅니다."
echo
QD "SET NOCOUNT ON;
SELECT CAST(r.session_id AS varchar(8)) + '|' + CAST(r.blocking_session_id AS varchar(8))
     + '|' + r.wait_type + '|' + CAST(r.wait_time AS varchar(12))
  FROM sys.dm_exec_requests r
  JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
 WHERE s.is_user_process = 1 AND r.blocking_session_id <> 0
 ORDER BY r.session_id;" | grep -E '^[0-9]+\|' \
 | while IFS='|' read -r sid bid wt tm; do
     printf "    세션 %s 이(가) 세션 %s 에게 막힘  (%s, %sms)\n" "$sid" "$bid" "$wt" "$tm"
   done
echo
echo "  여기 나오는 세션을 죽이면 될 것 같지만, 그중 하나는 자기도 막혀 있습니다."
echo "  그것을 죽여도 뿌리가 그대로라 다시 같은 일이 납니다."
echo

echo "## 2-2. 재귀로 뿌리까지"
echo
docker exec -i "$CT" sh -c 'cat > /tmp/chain.sql' <<'SQL'
SET NOCOUNT ON;
WITH blocked AS (
    SELECT r.session_id, r.blocking_session_id, r.wait_type, r.wait_time
      FROM sys.dm_exec_requests r
      JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
     WHERE s.is_user_process = 1 AND r.blocking_session_id <> 0
),
chain AS (
    -- 잎: 아무도 막고 있지 않은, 막히기만 한 세션
    SELECT b.session_id, b.blocking_session_id, 1 AS depth,
           CAST(b.session_id AS varchar(200)) AS path
      FROM blocked b
     WHERE NOT EXISTS (SELECT 1 FROM blocked x WHERE x.blocking_session_id = b.session_id)
    UNION ALL
    -- 위로 올라간다.
    -- 재귀부에는 외부 조인을 못 쓴다(Msg 462). 스칼라 서브쿼리로 대신한다.
    SELECT c.session_id,
           ISNULL((SELECT b2.blocking_session_id FROM blocked b2
                    WHERE b2.session_id = c.blocking_session_id), 0),
           c.depth + 1,
           -- 재귀부의 타입이 앵커와 정확히 같아야 한다(Msg 240). 명시적으로 맞춘다.
           CAST(c.path + ' <- ' + CAST(c.blocking_session_id AS varchar(8)) AS varchar(200))
      FROM chain c
     WHERE c.blocking_session_id <> 0
)
SELECT TOP 1 path AS r FROM chain ORDER BY depth DESC;
SQL
CHAIN=$(docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" -i /tmp/chain.sql 2>&1 | grep -E '^[0-9]+' | head -1)
printf "    사슬: %s\n" "${CHAIN:-확인 못 함}"

ROOT_ID=$(num "$(QD "SET NOCOUNT ON;
SELECT TOP 1 CAST(r.blocking_session_id AS varchar(8))
  FROM sys.dm_exec_requests r
  JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
 WHERE s.is_user_process = 1 AND r.blocking_session_id <> 0
   AND NOT EXISTS (SELECT 1 FROM sys.dm_exec_requests r2
                    WHERE r2.session_id = r.blocking_session_id AND r2.blocking_session_id <> 0);")")
echo
echo "  뿌리 세션: ${ROOT_ID}"
echo

echo "## 2-3. 뿌리는 무엇을 하고 있었나"
echo
ROOTINFO=$(numsp "$(QD "SET NOCOUNT ON;
SELECT s.status + '|' + CONVERT(varchar(23), s.last_request_end_time, 121)
     + '|' + CAST((SELECT COUNT(*) FROM sys.dm_tran_session_transactions t
                    WHERE t.session_id = s.session_id) AS varchar(4))
  FROM sys.dm_exec_sessions s WHERE s.session_id = ${ROOT_ID};")")
IFS='|' read -r r_status r_last r_tran <<<"$ROOTINFO"
printf "    상태 %s / 마지막 요청 %s / 열린 트랜잭션 %s개\n" "$r_status" "$r_last" "$r_tran"
IN_REQ=$(num "$(QD "SELECT CAST(COUNT(*) AS varchar(4)) FROM sys.dm_exec_requests WHERE session_id = ${ROOT_ID}")")
echo
echo "  dm_exec_requests 에 이 세션이 있는가: $([ "${IN_REQ:-0}" -gt 0 ] && echo '있음' || echo '**없음**')"
{ echo "metric,value"
  echo "root_session,$ROOT_ID"
  echo "root_in_exec_requests,$IN_REQ"; } > "$OUT/blocking-chain.csv"

wait "$PA" 2>/dev/null; wait "$PB" 2>/dev/null; wait "$PC" 2>/dev/null
echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
echo
echo "  **순진한 조회는 중간 세션을 가리킵니다.** blocking_session_id 를 그대로 읽으면"
echo "  \"B 가 막고 있다\"고 나오는데 B 도 막혀 있습니다. B 를 죽여도 A 가 그대로라"
echo "  다시 같은 일이 납니다."
echo
echo "  재귀로 사슬을 따라가면 뿌리가 나옵니다. 그리고 **뿌리는 아무것도 안 하고"
echo "  있습니다.** 상태가 sleeping 이고 실행 중인 요청이 없어 dm_exec_requests 에"
echo "  안 나옵니다. 실행 중인 것만 보는 도구로는 못 찾습니다."
echo
echo "  처음에는 뿌리를 WAITFOR DELAY 로 버티게 짰다가 이 결론을 못 낼 뻔했습니다."
echo "  그것은 실행 중인 요청이라 dm_exec_requests 에 그대로 나옵니다. 실제 사고의"
echo "  뿌리는 클라이언트가 트랜잭션을 열어 둔 채 노는 세션이고, 그것을 재현하려면"
echo "  서버가 아니라 **연결이** 놀아야 합니다."
echo
echo "  그래서 뿌리를 찾을 때는 dm_exec_sessions 와 dm_tran_session_transactions 를"
echo "  함께 봅니다. \"요청은 없는데 트랜잭션은 열려 있는 세션\"이 그것입니다."
echo
echo "  게임 운영으로 옮기면 흔한 모양이 하나 있습니다. 운영툴에서 조회를 던지고"
echo "  트랜잭션을 안 닫은 채 자리를 뜬 세션입니다. 그 하나가 보정 배치를 막고,"
echo "  보정 배치가 서비스 조회를 막습니다. 신고는 서비스에서 들어오는데 원인은"
echo "  두 단계 위에 있습니다."
} 2>&1 | tee "$OUT/exp2-blocking-chain.txt"
