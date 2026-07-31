#!/usr/bin/env bash
# README 의 "못 한 것" 하나를 잡는다.
#
#   JDBC 드라이버를 거치지 않았습니다
#   "3절은 JVM 의 ZoneId 동작만 봤습니다. 드라이버가 그 값을 서버로 보낼 때와 읽어 올
#    때 무엇을 하는지는 안 쟀습니다."
#
# 3절은 자바 안에서 끝났다. 실무의 사고는 자바와 서버 사이에서 난다. 드라이버가
# connectionTimeZone 설정에 따라 값을 변환하기 때문이다. 같은 LocalDateTime 을
# 설정만 바꿔 넣고 읽어, 무엇이 보존되고 무엇이 바뀌는지 본다.
#
# 커넥터 jar 은 로컬 Maven 캐시의 것을 마운트한다. 없으면 멈춘다. 이 실험 하나 때문에
# 내려받지 않는다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
CN=r14-mysql

JAR=$(ls "$HOME"/.m2/repository/com/mysql/mysql-connector-j/*/mysql-connector-j-*.jar 2>/dev/null \
      | grep -v sources | sort -V | tail -1)
[ -n "$JAR" ] || { echo "중단: mysql-connector-j jar 을 로컬 Maven 캐시에서 못 찾았습니다" >&2; exit 2; }

M(){ docker exec "$CN" mysql -uroot -plab -N -B -e "$1" 2>&1 | grep -v "^mysql: \[Warning\]"; }
for _ in $(seq 1 90); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
[ "$(M 'SELECT 1')" = "1" ] || { echo "중단: $CN 이 쿼리를 받지 못합니다" >&2; exit 2; }

NET=$(docker inspect "$CN" -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' | grep -v '^$' | head -1)
[ -n "$NET" ] || { echo "중단: $CN 의 네트워크를 못 읽었습니다" >&2; exit 2; }

M "CREATE DATABASE IF NOT EXISTS spoon" >/dev/null
M "DROP TABLE IF EXISTS spoon.tz_probe" >/dev/null
M "CREATE TABLE spoon.tz_probe (
     id INT AUTO_INCREMENT PRIMARY KEY,
     label VARCHAR(40) NOT NULL,
     as_datetime DATETIME(3) NULL,
     as_timestamp TIMESTAMP(3) NULL
   ) ENGINE=InnoDB" >/dev/null

cat > "$OUT/JdbcTz.java" <<'JAVA'
import java.sql.*;
import java.time.*;
import java.util.*;

public class JdbcTz {
    // 서버가 KST 이고 앱이 뉴욕 시간을 다룬다는 설정이다. 이 조합이 실무에서 흔하다.
    static final LocalDateTime GAP = LocalDateTime.of(2026, 3, 8, 2, 30);   // 뉴욕에 없는 시각
    static final LocalDateTime DUP = LocalDateTime.of(2026, 11, 1, 1, 30);  // 뉴욕에 두 번 오는 시각
    static final LocalDateTime PLAIN = LocalDateTime.of(2026, 6, 15, 12, 0);

    record Row(String label, String dt, String ts) {}

    static String url(String extra) {
        return "jdbc:mysql://mysql:3306/spoon?user=root&password=lab"
                + "&allowPublicKeyRetrieval=true&useSSL=false" + extra;
    }

    static List<Row> roundTrip(String label, String extra) throws Exception {
        List<Row> out = new ArrayList<>();
        try (Connection c = DriverManager.getConnection(url(extra))) {
            try (PreparedStatement del = c.prepareStatement(
                    "DELETE FROM tz_probe WHERE label LIKE ?")) {
                del.setString(1, label + "%");
                del.executeUpdate();
            }
            String[] names = {"plain", "gap", "dup"};
            LocalDateTime[] vals = {PLAIN, GAP, DUP};
            for (int i = 0; i < names.length; i++) {
                try (PreparedStatement ps = c.prepareStatement(
                        "INSERT INTO tz_probe (label, as_datetime, as_timestamp) VALUES (?,?,?)")) {
                    ps.setString(1, label + ":" + names[i]);
                    ps.setObject(2, vals[i]);
                    ps.setObject(3, vals[i]);
                    ps.executeUpdate();
                }
            }
            // 읽을 때는 문자열로도 받아 본다. 드라이버가 변환하는지 서버 값 그대로인지 갈린다.
            try (PreparedStatement q = c.prepareStatement(
                    "SELECT label, as_datetime, as_timestamp FROM tz_probe "
                    + "WHERE label LIKE ? ORDER BY id");
                 ResultSet rs = openWith(q, label)) {
                while (rs.next()) {
                    Object dt = rs.getObject("as_datetime", LocalDateTime.class);
                    Object ts = rs.getObject("as_timestamp", LocalDateTime.class);
                    out.add(new Row(rs.getString("label"), String.valueOf(dt), String.valueOf(ts)));
                }
            }
        }
        return out;
    }

    static ResultSet openWith(PreparedStatement q, String label) throws SQLException {
        q.setString(1, label + "%");
        return q.executeQuery();
    }

    public static void main(String[] a) throws Exception {
        System.out.println("  JVM 기본 시간대 = " + TimeZone.getDefault().getID());
        try (Connection c = DriverManager.getConnection(url(""))) {
            try (Statement s = c.createStatement();
                 ResultSet rs = s.executeQuery("SELECT @@global.time_zone, @@session.time_zone")) {
                rs.next();
                System.out.println("  서버 time_zone = " + rs.getString(1)
                        + " / 세션 = " + rs.getString(2));
            }
        }
        System.out.println();

        String[][] cases = {
            {"기본값", ""},
            {"connectionTimeZone=LOCAL", "&connectionTimeZone=LOCAL"},
            {"connectionTimeZone=SERVER", "&connectionTimeZone=SERVER"},
            {"뉴욕 고정", "&connectionTimeZone=America%2FNew_York&forceConnectionTimeZoneToSession=true"},
        };

        System.out.printf("  %-28s %-8s %-26s %-26s%n", "조건", "값", "DATETIME 로 왕복", "TIMESTAMP 로 왕복");
        for (String[] cs : cases) {
            List<Row> rows;
            try {
                rows = roundTrip(cs[0], cs[1]);
            } catch (Exception e) {
                System.out.printf("  %-28s 실패: %s%n", cs[0], e.getMessage());
                continue;
            }
            for (Row r : rows) {
                String name = r.label().substring(r.label().indexOf(':') + 1);
                System.out.printf("  %-28s %-8s %-26s %-26s%n",
                        r.label().startsWith(cs[0] + ":plain") ? cs[0] : "", name, r.dt(), r.ts());
            }
        }
        System.out.println();
        System.out.println("  넣은 값은 셋 다 그대로입니다.");
        System.out.println("    plain 2026-06-15T12:00, gap 2026-03-08T02:30, dup 2026-11-01T01:30");
        System.out.println("  돌아온 값이 이와 다르면 그 구간에서 드라이버나 서버가 변환한 것입니다.");
    }
}
JAVA

{
echo "# JDBC 를 거친 왕복"
echo "# MySQL $(M 'SELECT VERSION()')"
echo "# 커넥터: $(basename "$JAR")"
echo
echo "  LocalDateTime 을 넣고 같은 커넥션으로 읽습니다. DATETIME 과 TIMESTAMP 를 나란히"
echo "  두는 이유는, 앞 절에서 본 대로 DATETIME 은 벽시계를 그대로 담고 TIMESTAMP 는"
echo "  UTC 로 바꿔 담기 때문입니다. 변환이 어디서 일어나는지가 이 표의 질문입니다."
echo
docker run --rm --network "$NET" \
  -v "$OUT":/w -v "$JAR":/jar/mysql.jar:ro -w /w \
  eclipse-temurin:21-jdk \
  sh -c "javac -cp /jar/mysql.jar JdbcTz.java && java -cp .:/jar/mysql.jar JdbcTz" 2>&1 | sed 's/^/  /'
echo
echo "  서버에 실제로 무엇이 들어갔는지도 확인합니다(드라이버를 안 거친 값)."
docker exec "$CN" mysql -uroot -plab -t -e \
  "SELECT label, as_datetime, as_timestamp FROM spoon.tz_probe ORDER BY id" 2>&1 \
  | grep -v "^mysql: \[Warning\]" | sed 's/^/  /'
echo
echo "  각 조건 1회 실행입니다."
} 2>&1 | tee "$OUT/exp-jdbc-roundtrip.txt"
