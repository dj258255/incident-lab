#!/usr/bin/env bash
# 실험 1. INT PK가 상한에 닿는 순간.
#
# 21억 행을 실제로 넣을 수는 없으므로 AUTO_INCREMENT 카운터만 상한 직전으로 민다.
# 데이터 양이 아니라 카운터 값이 문제라는 점 자체가 이 사고의 핵심이다.
# 테이블에 행이 몇 개 없어도, 삭제를 반복해 카운터만 올라가도 똑같이 터진다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"
mkdir -p "$OUT"
M()  { docker exec a01-mysql mysql -uroot -plab spoon "$@" 2>&1 | grep -v "Warning.*password"; }
MQ() { docker exec a01-mysql mysql -uroot -plab spoon -N -B -e "$1" 2>/dev/null; }
say() { echo "$*" | tee -a "$OUT/exp1.txt"; }
: > "$OUT/exp1.txt"

say "=============================================================="
say "실험 1. INT PK가 상한에 닿는 순간"
say "=============================================================="

M -e "DROP TABLE IF EXISTS sponsor_int;
      CREATE TABLE sponsor_int (
        id INT AUTO_INCREMENT PRIMARY KEY,
        user_id BIGINT NOT NULL,
        amount INT NOT NULL,
        created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
      ) ENGINE=InnoDB;"

say ""
say '$ SELECT ~0 >> 33 AS int_max;      # signed INT 상한'
MQ "SELECT ~0 >> 33 AS int_max" | sed 's/^/  /' | tee -a "$OUT/exp1.txt"

say ""
say "행을 21억 개 넣지 않는다. 카운터만 상한 직전으로 민다."
say "데이터 양이 아니라 AUTO_INCREMENT 값이 문제라는 것이 이 사고의 핵심이다."
say "삭제를 반복해 행은 적은데 카운터만 올라간 테이블도 똑같이 터진다."
say ""
say '$ ALTER TABLE sponsor_int AUTO_INCREMENT = 2147483646;'
M -e "ALTER TABLE sponsor_int AUTO_INCREMENT = 2147483646;"
MQ "SELECT AUTO_INCREMENT FROM information_schema.TABLES
    WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='sponsor_int'" | sed 's/^/  현재 카운터 /' | tee -a "$OUT/exp1.txt"

say ""
say "후원 세 건을 넣어 본다."
for i in 1 2 3; do
  say ""
  say "  [${i}번째] INSERT"
  RES=$(M -e "INSERT INTO sponsor_int (user_id, amount) VALUES (100, 1000);" 2>&1)
  if [ -n "$RES" ]; then
    echo "$RES" | sed 's/^/    /' | tee -a "$OUT/exp1.txt"
  else
    ID=$(MQ "SELECT MAX(id) FROM sponsor_int")
    say "    성공. id = $ID"
  fi
done

say ""
say "상한에 닿으면 INSERT가 에러로 거부된다. 서비스로 치면 쓰기 전면 중단이다."
say "Basecamp가 2018년에 이 상태로 5시간 동안 쓰기를 받지 못했다."
say ""
say '$ SELECT COUNT(*) FROM sponsor_int;   # 행은 두 개뿐인데'
MQ "SELECT COUNT(*) FROM sponsor_int" | sed 's/^/  /' | tee -a "$OUT/exp1.txt"
say "  행 수와 무관하게 카운터가 상한이라 더 넣을 수 없다."

say ""
say "=============================================================="
say "왜 ALTER 한 줄로 못 고치는가"
say "=============================================================="
say ""
say "가장 단순한 해법은 컬럼 타입을 바꾸는 것이다. 그런데 이건 테이블 재구축이다."
say "행이 많으면 그동안 쓰기가 막힌다. 뒤에서 크기별로 실제로 잰다."
say ""
say '$ ALTER TABLE sponsor_int MODIFY id BIGINT AUTO_INCREMENT;'
T0=$(date +%s.%N)
M -e "ALTER TABLE sponsor_int MODIFY id BIGINT AUTO_INCREMENT;"
T1=$(date +%s.%N)
say "  소요 $(echo "$T1 - $T0" | bc)초 (행 2개짜리 테이블)"
say ""
say '$ INSERT INTO sponsor_int (user_id, amount) VALUES (100, 1000);'
RES=$(M -e "INSERT INTO sponsor_int (user_id, amount) VALUES (100, 1000);" 2>&1)
if [ -n "$RES" ]; then echo "$RES" | sed 's/^/    /' | tee -a "$OUT/exp1.txt"; else
  say "  성공. id = $(MQ "SELECT MAX(id) FROM sponsor_int")"
fi
say ""
say "행이 두 개면 즉시 끝난다. 문제는 21억 행짜리 테이블에서 같은 문장을 던질 때다."
