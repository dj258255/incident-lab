#!/usr/bin/env bash
# 문서에 실을 증거를 결과 파일로 남긴다.
#
# 측정 자체는 run-all.sh가 하지만, 그 과정에서 터미널로만 흘려보낸 관측이 둘 있었다.
# 시퀀스 채번 간격과 HikariCP 타임아웃 로그다. 둘 다 문서의 핵심 근거인데
# 파일이 없으면 이미지도 만들 수 없고 검증도 안 된다. 그래서 따로 남긴다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"
MQ(){ docker exec b01-mysql mysql -uroot -plab spoon -N -e "$1" 2>/dev/null; }
# mysqladmin ping은 인증 실패에도 성공을 반환한다. 실제 쿼리가 통하는지로 판단한다.
for _ in $(seq 1 90); do MQ "SELECT 1" | grep -q '^1$' && break; sleep 2; done

# 1) Hibernate 6이 몇 건마다 채번하는지. next_val이 뛰는 폭이 allocationSize다.
docker rm -f b01-app >/dev/null 2>&1
docker exec b01-mysql mysql -uroot -plab spoon \
  -e "TRUNCATE sponsor_jpa; DELETE FROM sponsor_jpa_seq; INSERT INTO sponsor_jpa_seq(next_val) VALUES(1);" 2>&1 | grep -v Warning
docker run -d --name b01-app --network b01-lab -p 8080:8080 \
  -e DB_HOST=b01-mysql -e DB_PORT=3306 -e POOL=10 \
  -v "$ROOT/app/build/libs:/app:ro" eclipse-temurin:21-jre java -jar /app/pool.jar >/dev/null
for _ in $(seq 1 60); do curl -sf localhost:8080/pool >/dev/null 2>&1 && break; sleep 1; done

{
  echo "\$ SHOW TABLES LIKE '%seq%';"
  echo "$(MQ "SHOW TABLES LIKE '%seq%'")"
  echo
  echo "기동 직후  next_val=$(MQ 'SELECT next_val FROM sponsor_jpa_seq')"
  for i in $(seq 1 6); do
    R=$(curl -s "localhost:8080/sponsor?mode=jpa")
    printf 'INSERT #%d → next_val=%-4s max(id)=%-3s %s\n' "$i" \
      "$(MQ 'SELECT next_val FROM sponsor_jpa_seq')" \
      "$(MQ 'SELECT IFNULL(MAX(id),0) FROM sponsor_jpa')" "$R"
  done
} > "$OUT/evidence-sequence.txt"
docker rm -f b01-app >/dev/null 2>&1
echo "→ results/evidence-sequence.txt"

# 2) HikariCP 타임아웃 로그. *.log는 커밋하지 않으므로 발췌를 따로 남긴다.
if [ -f "$OUT/jpa-10-app.log" ]; then
  grep -oE "HikariPool-1 - Connection is not available.*" "$OUT/jpa-10-app.log" \
    | sort -u > "$OUT/evidence-hikari-timeout.txt"
  echo "→ results/evidence-hikari-timeout.txt ($(wc -l < "$OUT/evidence-hikari-timeout.txt")줄)"
fi
