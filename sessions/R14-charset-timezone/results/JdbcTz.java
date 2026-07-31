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
                // DATETIME 과 TIMESTAMP 를 따로 넣는다. 한 문장으로 넣으면 TIMESTAMP 가
                // 거부될 때 그 행 전체가 안 들어가고, 어느 컬럼이 문제인지도 안 보인다.
                try (PreparedStatement ps = c.prepareStatement(
                        "INSERT INTO tz_probe (label, as_datetime) VALUES (?,?)")) {
                    ps.setString(1, label + ":" + names[i]);
                    ps.setObject(2, vals[i]);
                    ps.executeUpdate();
                }
                try (PreparedStatement ps = c.prepareStatement(
                        "UPDATE tz_probe SET as_timestamp = ? WHERE label = ?")) {
                    ps.setObject(1, vals[i]);
                    ps.setString(2, label + ":" + names[i]);
                    ps.executeUpdate();
                } catch (SQLException e) {
                    System.out.printf("  %-28s %-8s TIMESTAMP 거부: %s%n",
                            label, names[i], e.getMessage());
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

        // 라벨은 서버 표의 label 컬럼에도 들어간다. 한글로 두면 mysql CLI 출력이
        // 물음표로 깨져 어느 조건의 행인지 못 읽는다. ASCII 로 둔다.
        String[][] cases = {
            {"default", ""},
            {"connectionTimeZone=LOCAL", "&connectionTimeZone=LOCAL"},
            {"connectionTimeZone=SERVER", "&connectionTimeZone=SERVER"},
            {"NY-forced", "&connectionTimeZone=America%2FNew_York&forceConnectionTimeZoneToSession=true"},
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
