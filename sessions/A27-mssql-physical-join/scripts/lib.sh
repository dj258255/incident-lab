#!/usr/bin/env bash
# A27 공용 헬퍼. A26 규약을 그대로 따른다.
PW='Lab_Passw0rd!'
DB=lostark_join
CT=a27-mssql
SQLCMD=/opt/mssql-tools18/bin/sqlcmd

Q(){  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -Q "$1" 2>&1; }
QD(){ docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" -Q "$1" 2>&1; }
QF(){
  docker exec -i "$CT" sh -c "cat > /tmp/a27q.sql" <<<"$1"
  local n; n=$(docker exec "$CT" sh -c 'wc -l < /tmp/a27q.sql' | tr -d ' \r')
  [ "${n:-0}" -gt 0 ] || { echo "중단: SQL 파일이 비었습니다" >&2; return 2; }
  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" -i /tmp/a27q.sql 2>&1
}
num(){ echo "$1" | head -1 | tr -d ' \r'; }
numsp(){ echo "$1" | head -1 | sed 's/[[:space:]]*$//; s/\r//g'; }
QDX(){
  local out; out=$(QD "$1")
  if echo "$out" | grep -qE '^(Msg|메시지) [0-9]+'; then
    echo "중단: SQL 오류" >&2; echo "$out" | grep -E '^(Msg|메시지)' | head -3 >&2; return 2
  fi
  return 0
}
wait_ready(){
  local i
  for i in $(seq 1 150); do
    [ "$(num "$(Q "SELECT 'RE'+'ADY'")")" = "READY" ] && return 0
    sleep 2
  done
  echo "중단: $CT 가 쿼리를 못 받습니다" >&2; return 2
}

# 실행 계획에서 물리 조인 연산자 이름만 뽑는다.
# SHOWPLAN_ALL 은 결과를 안 내고 계획만 텍스트로 준다.
plan_op(){ # $1 = 쿼리
  QD "SET SHOWPLAN_ALL ON;
GO
$1
GO
SET SHOWPLAN_ALL OFF;" 2>/dev/null | grep -oE 'Nested Loops|Hash Match|Merge Join' | head -1
}
