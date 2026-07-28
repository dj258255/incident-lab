#!/bin/sh
# B31 실제 스택 재현 드라이버. Spring Boot WAR를 Tomcat 10.1에 올리고 순서대로 몰아준다.
#   1) remove() 누락이 워커 스레드에 컨텍스트를 남겨 다음 요청에 흘러드는가
#   2) 웹앱을 내릴 때 Tomcat이 무엇을 찍는가 (webappClassLoader.checkThreadLocalsForLeaks)
# 워커 스레드는 maxThreads=1로 고정해 두 요청이 반드시 같은 스레드에서 처리되게 했다.
#
# 실행: sh drive.sh
set -eu
cd "$(dirname "$0")"
BASE=http://localhost:18031/lab

echo "== 1. 기동 (Spring Boot 3.3.5 WAR -> Tomcat 10.1) =="
docker compose up -d --build >/dev/null 2>&1
printf "  배포 대기"
i=0
while [ "$i" -lt 60 ]; do
  if curl -sf "$BASE/api/safe/whoami" >/dev/null 2>&1; then break; fi
  printf "."
  sleep 2
  i=$((i + 1))
done
echo " 완료"
docker compose exec -T tomcat sh -c 'bin/version.sh 2>/dev/null | grep -E "Server version|JVM Version"' | sed 's/^/  /'

echo
echo "== 2. remove() 누락 경로 =="
echo "\$ curl -H 'X-User: alice' $BASE/api/leaky/whoami"
curl -s -H 'X-User: alice' "$BASE/api/leaky/whoami" | sed 's/^/  /'
echo "\$ curl $BASE/api/leaky/whoami          # 헤더 없이, 인증 안 한 요청"
curl -s "$BASE/api/leaky/whoami" | sed 's/^/  /'

echo
echo "== 3. try/finally remove() 경로 =="
echo "\$ curl -H 'X-User: bob' $BASE/api/safe/whoami"
curl -s -H 'X-User: bob' "$BASE/api/safe/whoami" | sed 's/^/  /'
echo "\$ curl $BASE/api/safe/whoami           # 헤더 없이, 인증 안 한 요청"
curl -s "$BASE/api/safe/whoami" | sed 's/^/  /'

echo
echo "== 4. 언디플로이(재배포의 앞단계) 후 Tomcat이 찍는 것 =="
curl -s -H 'X-User: carol' "$BASE/api/leaky/whoami" | sed 's/^/  /'
echo "\$ docker compose exec tomcat rm webapps/lab.war"
docker compose exec -T tomcat rm /usr/local/tomcat/webapps/lab.war
printf "  언디플로이 대기(HostConfig 백그라운드 주기 10초)"
i=0
while [ "$i" -lt 30 ]; do
  if docker compose logs tomcat 2>&1 | grep -q "Undeploying context"; then break; fi
  printf "."
  sleep 2
  i=$((i + 1))
done
echo " 완료"
docker compose logs tomcat 2>&1 | grep -iE "Undeploying context|ThreadLocal" | sed 's/^/  /'

echo
echo "== 5. 대조군: --add-opens 없이 띄우면 =="
docker compose down >/dev/null 2>&1
docker compose --profile noopen up -d tomcat-noopen >/dev/null 2>&1
printf "  배포 대기"
i=0
while [ "$i" -lt 60 ]; do
  if curl -sf http://localhost:18032/lab/api/safe/whoami >/dev/null 2>&1; then break; fi
  printf "."
  sleep 2
  i=$((i + 1))
done
echo " 완료"
curl -s -H 'X-User: dave' http://localhost:18032/lab/api/leaky/whoami | sed 's/^/  /'
docker compose --profile noopen exec -T tomcat-noopen rm /usr/local/tomcat/webapps/lab.war
printf "  언디플로이 대기"
i=0
while [ "$i" -lt 30 ]; do
  if docker compose --profile noopen logs tomcat-noopen 2>&1 | grep -q "Undeploying context"; then break; fi
  printf "."
  sleep 2
  i=$((i + 1))
done
echo " 완료"
docker compose --profile noopen logs tomcat-noopen 2>&1 \
  | grep -iE "Undeploying context|ThreadLocal" | sed 's/^/  /'

echo
echo "== 6. 정리 =="
docker compose --profile noopen down 2>&1 | sed 's/^/  /'
