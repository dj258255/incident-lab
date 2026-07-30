#!/usr/bin/env bash
# "애플리케이션에 SAVEPOINT라는 단어가 없어도 생긴다"는 표를 실행으로 확인한다.
#
# 그 표는 공식 문서와 소스만으로 서술돼 있었다. PostgreSQL의 log_statement='all'을 켜고
# 서버 로그에 SAVEPOINT가 실제로 찍히는지 본다. 문서를 읽은 것과 돌려 본 것은 다르다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
P(){ docker exec a19-primary psql -U postgres -d spoon -qAt -c "$1" 2>/dev/null; }

for _ in $(seq 1 90); do [ "$(P 'SELECT 1')" = "1" ] && break; sleep 2; done
P "SELECT 1" | grep -q 1 || { echo "중단: 프라이머리가 쿼리를 받지 못합니다" >&2; exit 2; }
docker exec a19-primary psql -U postgres -c "ALTER SYSTEM SET log_statement = 'all'; SELECT pg_reload_conf()" >/dev/null 2>&1
sleep 2
echo "log_statement = $(P "SHOW log_statement")"

run_case() {  # $1=txManager  $2=mode
  local tm="$1" mode="$2"
  docker rm -f a19-app >/dev/null 2>&1
  docker run -d --name a19-app --network a19-subtransaction-slru_default -p 8095:8080 \
    -e DB_HOST=a19-primary -e DB_PORT=5432 -e TX_MANAGER="$tm" \
    -v "$ROOT/app/build/libs:/app:ro" eclipse-temurin:21-jre java -jar /app/savepoint.jar >/dev/null 2>&1
  local up=0
  for _ in $(seq 1 60); do curl -sf localhost:8095/ping >/dev/null 2>&1 && { up=1; break; }; sleep 1; done
  if [ "$up" != "1" ]; then echo "  [$tm/$mode] 앱 기동 실패"; docker logs a19-app 2>&1|tail -4|sed 's/^/    /'; return; fi

  # 로그 표식을 남겨 이 케이스의 구간을 나중에 잘라낼 수 있게 한다.
  P "SELECT 'CASE_MARK_${tm}_${mode}'" >/dev/null
  local resp; resp=$(curl -s "localhost:8095/probe?mode=$mode&n=3")
  echo "  [$tm / $mode] $resp"
  docker rm -f a19-app >/dev/null 2>&1
}

{
  echo "# 애플리케이션 계층 검증. PostgreSQL log_statement='all'로 서버가 받은 문장을 전부 남긴다."
  echo "# 각 케이스 앞에 CASE_MARK_<매니저>_<전파> 를 찍어 구간을 나눈다."
  echo
  for tm in jdbc jpa; do
    for mode in nested required requiresNew; do run_case "$tm" "$mode"; done
  done
} | tee "$OUT/evidence-app-layer.txt"

echo
echo "## 서버 로그에서 케이스별 SAVEPOINT 발생 수" | tee -a "$OUT/evidence-app-layer.txt"
docker logs a19-primary 2>&1 | awk '
  /CASE_MARK_/ { if (m != "") printf "  %-24s SAVEPOINT %d건  RELEASE %d건  ROLLBACK TO %d건\n", m, sp, rl, rb
                 match($0, /CASE_MARK_[a-zA-Z_]+/); m=substr($0, RSTART+10, RLENGTH-10); sp=0; rl=0; rb=0; next }
  /SAVEPOINT/ && !/RELEASE|ROLLBACK/ { sp++ }
  /RELEASE SAVEPOINT/ { rl++ }
  /ROLLBACK TO SAVEPOINT/ { rb++ }
  END { if (m != "") printf "  %-24s SAVEPOINT %d건  RELEASE %d건  ROLLBACK TO %d건\n", m, sp, rl, rb }
' | tee -a "$OUT/evidence-app-layer.txt"

echo | tee -a "$OUT/evidence-app-layer.txt"
echo "## SAVEPOINT 문장 원문 (앞 6줄)" | tee -a "$OUT/evidence-app-layer.txt"
docker logs a19-primary 2>&1 | grep -oE "statement: (SAVEPOINT|RELEASE SAVEPOINT|ROLLBACK TO SAVEPOINT) .*" | head -6 | sed 's/^/  /' | tee -a "$OUT/evidence-app-layer.txt"
