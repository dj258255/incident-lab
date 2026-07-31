#!/usr/bin/env bash
# README 의 "못 한 것" 세 개를 잡는다.
#
#   1) 전환 중 쓰기 부하를 넣지 않았습니다
#      utf8mb4 전환이 4.6초 걸리는 동안 쓰기가 몇 건 통과하는지 안 쟀다.
#      ALGORITHM=COPY 는 원본 테이블에 공유 락을 잡는다. 그러면 읽기는 되고 쓰기는
#      막히는 것이 문서의 서술인데, 실제로 몇 건이 막히고 얼마를 기다리는지 잰다.
#
#   2) 두 버전의 tzdata 를 같은 서버에 두고 비교하지는 못했습니다
#      규칙 변경 전후 시각의 오프셋이 갈린다는 것까지만 보였다.
#      → 이름이 다른 두 타임존을 한 서버에 적재해 같은 질의에 나란히 넣는다.
#        서버 하나에서 옛 규칙과 새 규칙이 동시에 보이면, 이것이 "서버마다 tzdata 가
#        다르면 같은 시각이 다르게 해석된다"의 최소 재현이 된다.
#
#   3) DST 구간의 애플리케이션 동작은 재현하지 않았습니다
#      CONVERT_TZ 수준까지만 봤고 JDBC 드라이버나 JVM ZoneId 가 같은 시각을 어떻게
#      다루는지는 안 쟀다. → 자바에서 결손·중복 시각을 넣고 읽어 본다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
CN=r14-mysql
ROWS=${ROWS:-1000000}

M(){ docker exec "$CN" mysql -uroot -plab spoon -N -B -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }
MT(){ docker exec "$CN" mysql -uroot -plab spoon -t -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }

for _ in $(seq 1 90); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(M 'SELECT 1')" = "1" ] || { echo "중단: $CN 이 쿼리를 받지 못합니다" >&2; exit 2; }

{
echo "# 전환 중 쓰기, 두 tzdata 를 한 서버에, JDBC 의 DST 처리"
echo "# MySQL $(M 'SELECT VERSION()')"
echo "# 각 조건 1회 실행입니다."
echo

# ── 1) 전환 중 쓰기 ─────────────────────────────────────────────────────
echo "=================================================================="
echo "## 1) utf8mb4 전환이 도는 동안 쓰기가 어떻게 되는가"
echo "=================================================================="
M "DROP TABLE IF EXISTS conv_w" >/dev/null
M "CREATE TABLE conv_w (
     id BIGINT AUTO_INCREMENT PRIMARY KEY,
     name VARCHAR(191), memo VARCHAR(191),
     KEY idx_name (name)
   ) CHARACTER SET utf8mb3 COLLATE utf8mb3_general_ci" >/dev/null
echo "  ${ROWS}행 적재 중..."
M "INSERT INTO conv_w (name, memo)
   WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < $ROWS)
   SELECT CONCAT('name', n), CONCAT('memo', n) FROM s" >/dev/null 2>&1 \
  || M "INSERT INTO conv_w (name, memo) SELECT CONCAT('name',a.n), CONCAT('memo',a.n) FROM
        (SELECT @r := @r + 1 AS n FROM information_schema.COLUMNS c1,
          information_schema.COLUMNS c2, (SELECT @r := 0) r LIMIT $ROWS) a" >/dev/null 2>&1
echo "  적재 완료: $(M 'SELECT COUNT(*) FROM conv_w')행"

# 쓰기 루프. 건별 소요를 밀리초로 남긴다. 밀리초로 재는 이유는 A01 에서 초 단위로
# 재다가 창 밖의 쓰기가 섞여 틀린 값이 나왔기 때문이다.
: > "$OUT/convert-writes.csv"
echo "ts_ns,elapsed_ms,ok,err" >> "$OUT/convert-writes.csv"
docker exec -d "$CN" bash -c "
  for i in \$(seq 1 20000); do
    S=\$(date +%s%N)
    OUT=\$(mysql -uroot -plab spoon -N -B -e \"INSERT INTO conv_w (name, memo) VALUES ('w','w')\" 2>&1)
    E=\$(date +%s%N)
    # 경고를 실패로 세면 안 된다. mysql 은 비밀번호를 명령줄에 주면
    # \"Using a password on the command line interface can be insecure\" 를 stderr 로
    # 내보내는데, 그것을 실패로 잡아 104건 전부가 실패로 기록됐다.
    ERRLINE=\$(echo \"\$OUT\" | grep -v \"Warning\" | grep -iE \"ERROR|error\" | head -1 | tr ',' ' ')
    if [ -n \"\$ERRLINE\" ]; then ERR=\$ERRLINE; OK=0; else ERR=; OK=1; fi
    echo \"\$S,\$(( (E-S)/1000000 )),\$OK,\$ERR\" >> /tmp/convert-writes.csv
    sleep 0.02
  done"
sleep 2

T0=$(date +%s%N)
M "ALTER TABLE conv_w CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci, ALGORITHM=COPY" >/dev/null 2>&1
T1=$(date +%s%N)
ALTER_MS=$(( (T1 - T0) / 1000000 ))
sleep 1
docker exec "$CN" pkill -f "seq 1 20000" >/dev/null 2>&1 || true
docker exec "$CN" bash -c "cat /tmp/convert-writes.csv" >> "$OUT/convert-writes.csv" 2>/dev/null || true
docker exec "$CN" bash -c "rm -f /tmp/convert-writes.csv" >/dev/null 2>&1 || true

echo "  ALTER 소요 = ${ALTER_MS}ms"
python3 - "$OUT/convert-writes.csv" "$T0" "$T1" <<'PY'
import csv, sys
path, t0, t1 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
inside, before, fails, waits = [], [], [], []
for r in csv.DictReader(open(path)):
    try:
        ts = int(r['ts_ns']); ms = int(r['elapsed_ms']); ok = r['ok'] == '1'
    except (ValueError, KeyError):
        continue
    if t0 <= ts <= t1:
        inside.append(ms)
        if not ok: fails.append(r.get('err', ''))
        waits.append(ms)
    elif ts < t0:
        before.append(ms)
dur = (t1 - t0) / 1e9
print(f"  전환 창 안의 쓰기 시도 = {len(inside)}건 ({dur:.1f}초 동안, 초당 {len(inside)/dur if dur else 0:.1f}건)")
print(f"  그중 실패 = {len(fails)}건")
if before:
    before.sort()
    print(f"  전환 전 기준선: 중앙 {before[len(before)//2]}ms, 최대 {before[-1]}ms ({len(before)}건)")
if waits:
    waits.sort()
    print(f"  전환 중:       중앙 {waits[len(waits)//2]}ms, 최대 {waits[-1]}ms")
print()
print("  ALGORITHM=COPY 는 원본에 공유 락을 잡습니다. 읽기는 통과하고 쓰기는 기다립니다.")
print("  전환 중 최대 대기가 ALTER 소요에 가까우면 쓰기가 통째로 밀린 것이고,")
print("  실패가 0건이면 막힌 것이 아니라 기다린 것입니다. 둘은 다릅니다.")
print("  락 대기 타임아웃보다 ALTER 가 길면 그때부터 1205 로 실패합니다.")
PY
echo

# ── 2) 두 tzdata 를 한 서버에 ───────────────────────────────────────────
echo "=================================================================="
echo "## 2) 옛 규칙과 새 규칙을 한 서버에 나란히"
echo "=================================================================="
echo "  멕시코는 2022년 10월 하계 시간제를 폐지했습니다. tzdata 2022b 이전 데이터에는"
echo "  그 폐지가 없어 2023년 여름 오프셋이 -5시간으로, 최신 데이터에서는 -6시간으로 나옵니다."
echo "  같은 서버에 두 규칙을 이름만 다르게 적재해 나란히 놓습니다."
echo
# mysql.time_zone 계열에 규칙을 직접 넣는다. 이름이 다르면 한 서버에 공존할 수 있다.
M "SET @@session.sql_mode=''" >/dev/null
docker exec -i "$CN" mysql -uroot -plab mysql >/dev/null 2>&1 <<'SQL'
-- 옛 규칙(하계 시간제가 살아 있는 상태)과 새 규칙(폐지된 상태)을 이름만 달리 넣는다.
-- 값은 IANA 규칙을 그대로 옮긴 것이 아니라, 이 실험이 보이려는 차이만 담은 최소 규칙이다.
DELETE FROM time_zone_transition WHERE Time_zone_id IN (9001, 9002);
DELETE FROM time_zone_transition_type WHERE Time_zone_id IN (9001, 9002);
DELETE FROM time_zone_name WHERE Time_zone_id IN (9001, 9002);
DELETE FROM time_zone WHERE Time_zone_id IN (9001, 9002);

INSERT INTO time_zone (Time_zone_id, Use_leap_seconds) VALUES (9001, 'N'), (9002, 'N');
INSERT INTO time_zone_name (Name, Time_zone_id)
  VALUES ('LAB/Mexico_old', 9001), ('LAB/Mexico_new', 9002);

-- 옛 규칙: 겨울 -6, 여름 -5 (하계 시간제 있음)
INSERT INTO time_zone_transition_type
  (Time_zone_id, Transition_type_id, Offset, Is_DST, Abbreviation) VALUES
  (9001, 0, -21600, 0, 'CST'),
  (9001, 1, -18000, 1, 'CDT');
INSERT INTO time_zone_transition (Time_zone_id, Transition_time, Transition_type_id) VALUES
  (9001, 1678608000, 1),   -- 2023-03-12 08:00:00 UTC 여름 시작
  (9001, 1698163200, 0);   -- 2023-10-24 16:00:00 UTC 여름 끝

-- 새 규칙: 사철 -6 (하계 시간제 폐지)
INSERT INTO time_zone_transition_type
  (Time_zone_id, Transition_type_id, Offset, Is_DST, Abbreviation) VALUES
  (9002, 0, -21600, 0, 'CST');
INSERT INTO time_zone_transition (Time_zone_id, Transition_time, Transition_type_id) VALUES
  (9002, 1678608000, 0),
  (9002, 1698163200, 0);
SQL
M "FLUSH TABLES" >/dev/null 2>&1 || true
MT "SELECT '2023-07-15 12:00:00' AS \`UTC 시각\`,
           CONVERT_TZ('2023-07-15 12:00:00','UTC','LAB/Mexico_old') AS \`옛 규칙\`,
           CONVERT_TZ('2023-07-15 12:00:00','UTC','LAB/Mexico_new') AS \`새 규칙\`,
           TIMESTAMPDIFF(HOUR,
             CONVERT_TZ('2023-07-15 12:00:00','UTC','LAB/Mexico_new'),
             CONVERT_TZ('2023-07-15 12:00:00','UTC','LAB/Mexico_old')) AS \`차이(시간)\`" | sed 's/^/  /'
echo
echo "  같은 UTC 시각인데 규칙에 따라 한 시간이 갈립니다. 서버 두 대의 tzdata 가"
echo "  다르면 이 두 열이 서로 다른 서버의 답이 됩니다. 로그의 시각과 DB 의 시각이"
echo "  한 시간 어긋나는 사고가 여기서 나옵니다."
echo

# ── 3) 자바의 DST 처리 ─────────────────────────────────────────────────
echo "=================================================================="
echo "## 3) 같은 결손·중복 시각을 자바가 어떻게 다루는가"
echo "=================================================================="
echo "  MySQL 은 결손 시각에 에러도 NULL 도 아닌 값을 돌려줬습니다. 자바는 어떤지 봅니다."
echo
cat > "$OUT/DstJava.java" <<'JAVA'
import java.time.*;
import java.time.format.DateTimeFormatter;

public class DstJava {
    public static void main(String[] a) {
        ZoneId ny = ZoneId.of("America/New_York");
        DateTimeFormatter F = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss zzz XXX");

        // 결손: 2026-03-08 02:30 은 존재하지 않는다(02:00 에서 03:00 으로 건너뜀).
        LocalDateTime gap = LocalDateTime.of(2026, 3, 8, 2, 30);
        ZonedDateTime g = gap.atZone(ny);
        System.out.println("결손 02:30");
        System.out.println("  atZone 결과      = " + g.format(F));
        System.out.println("  에러 없이 " + (g.toLocalTime().equals(LocalTime.of(2,30)) ? "그대로" : "이동됨")
                + " 처리됩니다. 예외를 던지지 않습니다.");

        // 중복: 2026-11-01 01:30 은 두 번 온다(EDT 와 EST).
        LocalDateTime dup = LocalDateTime.of(2026, 11, 1, 1, 30);
        ZonedDateTime early = dup.atZone(ny).withEarlierOffsetAtOverlap();
        ZonedDateTime later = dup.atZone(ny).withLaterOffsetAtOverlap();
        System.out.println();
        System.out.println("중복 01:30");
        System.out.println("  기본(atZone)     = " + dup.atZone(ny).format(F));
        System.out.println("  withEarlier      = " + early.format(F));
        System.out.println("  withLater        = " + later.format(F));
        System.out.println("  두 순간의 차이   = "
                + Duration.between(early.toInstant(), later.toInstant()).toSeconds() + "초");
        System.out.println("  atZone 의 기본값은 앞의 것(EDT)입니다. 뒤의 것을 고르려면");
        System.out.println("  withLaterOffsetAtOverlap 을 명시해야 합니다. 안 쓰면 매년 이 한 시간에");
        System.out.println("  들어온 요청이 한 시간 앞으로 기록됩니다.");

        // 저장 뒤에는 구별되지 않는다는 것을 보인다.
        System.out.println();
        System.out.println("LocalDateTime 으로만 저장하면");
        System.out.println("  early -> LocalDateTime = " + early.toLocalDateTime());
        System.out.println("  later -> LocalDateTime = " + later.toLocalDateTime());
        System.out.println("  같습니다. 오프셋을 버리면 두 순간이 한 값으로 뭉갭니다.");
        System.out.println("  MySQL 의 DATETIME 이 정확히 이 상태이고, TIMESTAMP 는 UTC 로 저장해 구별합니다.");
    }
}
JAVA
docker run --rm -v "$OUT":/w -w /w eclipse-temurin:21-jdk \
  sh -c "javac DstJava.java && java DstJava" 2>&1 | sed 's/^/  /'
echo
} 2>&1 | tee "$OUT/exp-write-and-jdbc.txt"
