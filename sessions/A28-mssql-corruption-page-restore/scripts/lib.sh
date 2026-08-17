#!/usr/bin/env bash
# A28 공용 헬퍼. 컨테이너는 A26 것을 재사용한다(새로 띄우면 메모리가 모자라다).
# 랩 DB(lostark_log, lostark_ops)는 건드리지 않는다. 이 세션의 DB 는 corruption_lab 뿐이다.
PW='Lab_Passw0rd!'
DB=corruption_lab
CT=a26-mssql
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
ROWS=${ROWS:-30000}   # 인스턴스 목표 메모리 255MB(cgroup) — 큰 값은 Msg 802

Q(){  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -Q "$1" 2>&1; }
QD(){ docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" -Q "$1" 2>&1; }
num(){ echo "$1" | head -1 | tr -d ' \r'; }

QDX(){
  local out; out=$(QD "$1")
  if echo "$out" | grep -qE '^(Msg|메시지) [0-9]+'; then
    echo "중단: SQL 오류" >&2; echo "$out" | grep -E '^(Msg|메시지)' | head -3 >&2; return 2
  fi
  return 0
}

wait_ready(){
  for i in $(seq 1 30); do
    Q "SELECT 1" | grep -q 1 && return 0; sleep 2
  done
  echo "중단: SQL Server 응답 없음" >&2; return 2
}
