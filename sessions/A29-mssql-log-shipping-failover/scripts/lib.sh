#!/usr/bin/env bash
# A29 공용 헬퍼. 주(a25)와 보조(a26) 두 인스턴스를 쓴다 — 컨테이너는 기존 것 재사용.
# 랩 DB(lostark_log, lostark_ops)는 건드리지 않는다. 이 세션의 DB 는 shipping_lab 뿐이다.
PW='Lab_Passw0rd!'
DB=shipping_lab
P=a25-mssql   # 주 (primary)
S=a26-mssql   # 보조 (secondary)
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
TMP=/tmp/a29-ship; mkdir -p "$TMP"

QP(){  docker exec "$P" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -Q "$1" 2>&1; }
QS(){  docker exec "$S" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -Q "$1" 2>&1; }
QPD(){ docker exec "$P" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" -Q "$1" 2>&1; }
QSD(){ docker exec "$S" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" -Q "$1" 2>&1; }
num(){ echo "$1" | head -1 | tr -d ' \r'; }

# 로그 전달의 "복사" 단계. 공유 스토리지가 없어 호스트를 경유한다.
ship(){
  docker cp "$P:/var/opt/mssql/backup/$1" "$TMP/$1" >/dev/null
  docker cp "$TMP/$1" "$S:/var/opt/mssql/backup/$1" >/dev/null
  # docker cp 는 원본 소유(mssql)를 root 로 바꿔 놓아 보조의 mssql 이 못 읽는다(OS error 5)
  docker exec -u root "$S" chown mssql:mssql "/var/opt/mssql/backup/$1"
}

wait_both(){
  for c in "$P" "$S"; do
    ok=""
    for i in $(seq 1 30); do
      docker exec "$c" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -l 5 -Q "SELECT 1" 2>/dev/null | grep -q 1 && { ok=1; break; }
      sleep 2
    done
    [ -n "$ok" ] || { echo "중단: $c 응답 없음" >&2; return 2; }
  done
}
