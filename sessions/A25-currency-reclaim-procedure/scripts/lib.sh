#!/usr/bin/env bash
# A25 공용 헬퍼.
PW='Lab_Passw0rd!'
DB=lostark_ops
CT=a25-mssql
SQLCMD=/opt/mssql-tools18/bin/sqlcmd

ACCOUNTS=${ACCOUNTS:-1000000}   # 전체 계정
TARGETS=${TARGETS:-60000}       # 회수 대상 계정
SHORT_RATIO=${SHORT_RATIO:-3}   # 대상 중 잔액이 부족한 계정의 비율(1/N)
CHUNK=${CHUNK:-4000}            # 보정 배치 크기. A04 의 결론을 따른다

Q(){  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -Q "$1" 2>&1; }
QD(){ docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" -Q "$1" 2>&1; }

# 파일로 심어 실행한다. 프로시저 정의처럼 GO 가 필요한 것에 쓴다.
QF(){
  docker exec -i "$CT" sh -c "cat > /tmp/a25q.sql" <<<"$1"
  local n; n=$(docker exec "$CT" sh -c 'wc -l < /tmp/a25q.sql' | tr -d ' \r')
  [ "${n:-0}" -gt 0 ] || { echo "중단: SQL 파일이 비었습니다" >&2; return 2; }
  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" -i /tmp/a25q.sql 2>&1
}

num(){ echo "$1" | head -1 | tr -d ' \r'; }

# 내부 공백을 살려야 하는 값에 쓴다. num() 은 공백을 전부 지우므로
# '2026-08-07 05:21:04.980' 이 '2026-08-0705:21:04.980' 이 되어 STOPAT 이 Msg 3217
# 로 죽는다. 그것을 "시각으로는 못 되돌린다"로 읽을 뻔했다. 엔진이 아니라 내 버그였다.
numsp(){ echo "$1" | head -1 | tr -d '\r' | sed -e 's/^ *//' -e 's/ *$//'; }

# 오류가 있으면 멈춘다. A24 에서 >/dev/null 이 Msg 를 삼켜 빈 데이터셋으로 끝까지
# 돌았던 일을 되풀이하지 않는다.
QDX(){
  local out; out=$(QD "$1")
  if echo "$out" | grep -qE '^(Msg|메시지) [0-9]+'; then
    echo "중단: SQL 오류" >&2
    echo "$out" | grep -E '^(Msg|메시지)' | head -3 >&2
    return 2
  fi
  return 0
}
QFX(){
  local out; out=$(QF "$1")
  if echo "$out" | grep -qE '^(Msg|메시지) [0-9]+'; then
    echo "중단: SQL 오류" >&2
    echo "$out" | grep -E '^(Msg|메시지)' | head -3 >&2
    return 2
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
