#!/usr/bin/env bash
# A26 공용 헬퍼.
PW='Lab_Passw0rd!'
DB=lostark_ops
CT=a26-mssql
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
ROWS=${ROWS:-300000}

Q(){  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -Q "$1" 2>&1; }
QD(){ docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" -Q "$1" 2>&1; }
QF(){
  docker exec -i "$CT" sh -c "cat > /tmp/a26q.sql" <<<"$1"
  local n; n=$(docker exec "$CT" sh -c 'wc -l < /tmp/a26q.sql' | tr -d ' \r')
  [ "${n:-0}" -gt 0 ] || { echo "중단: SQL 파일이 비었습니다" >&2; return 2; }
  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" -i /tmp/a26q.sql 2>&1
}
num(){ echo "$1" | head -1 | tr -d ' \r'; }

# 값 안의 공백을 살려야 하는 자리에 쓴다. num 은 내부 공백까지 지우므로
# '2026-08-09 08:10:00.787' 이 '2026-08-0908:10:00.787' 이 된다.
# A25 에서 이것 때문에 STOPAT 이 Msg 3217 로 죽었고 "시각 복원이 안 된다"고
# 결론 낼 뻔했다. 여기서는 화면에만 나오지만 같은 함수를 쓰면 같은 자국이 남는다.
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
setup_db(){
  Q "IF DB_ID('$DB') IS NULL CREATE DATABASE [$DB]" >/dev/null
  QDX "SET NOCOUNT ON;
  DROP TABLE IF EXISTS account_currency;
  CREATE TABLE account_currency (
      account_id INT NOT NULL PRIMARY KEY,
      balance    BIGINT NOT NULL
  );
  WITH n AS (SELECT TOP ($ROWS) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
               FROM sys.all_objects a CROSS JOIN sys.all_objects b)
  INSERT INTO account_currency WITH (TABLOCK) (account_id, balance)
  SELECT i, 100000 FROM n;
  UPDATE STATISTICS account_currency WITH FULLSCAN;" || return 2
  local got; got=$(num "$(QD "SELECT COUNT(*) FROM account_currency")")
  [ "$got" = "$ROWS" ] || { echo "중단: 적재가 ${got}행입니다(기대 ${ROWS})" >&2; return 2; }
}
