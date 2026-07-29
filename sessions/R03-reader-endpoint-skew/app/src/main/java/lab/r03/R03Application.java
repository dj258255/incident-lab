package lab.r03;

import com.zaxxer.hikari.HikariDataSource;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import javax.sql.DataSource;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.TreeMap;

/**
 * Aurora 리더 엔드포인트의 분산은 커넥션 단위다. 쿼리 단위가 아니다.
 *
 * 커넥션을 맺을 때 DNS가 리플리카 하나를 골라 주고, 그 커넥션은 끝까지 그 인스턴스에 붙는다.
 * 풀이 커넥션 N개를 한꺼번에 만들면 그 순간의 DNS 응답 순서대로 N개가 갈린다.
 * 문제는 풀 전체가 동시에 재생성될 때다. maxLifetime이 모든 커넥션에서 같으면
 * 기동 시점이 비슷한 커넥션들이 비슷한 시각에 만료되고, 한꺼번에 다시 맺으면서
 * 그 순간의 DNS 응답에 몰린다.
 *
 * 이 앱은 풀 안의 커넥션이 각각 어느 인스턴스에 붙어 있는지를 세어 보여준다.
 */
@SpringBootApplication
public class R03Application {
    public static void main(String[] args) {
        SpringApplication.run(R03Application.class, args);
    }
}

@RestController
class SkewController {
    private final JdbcTemplate jdbc;
    private final DataSource ds;

    SkewController(JdbcTemplate jdbc, DataSource ds) { this.jdbc = jdbc; this.ds = ds; }

    /**
     * 풀 안의 커넥션을 전부 꺼내 각각 어느 server_id에 붙어 있는지 센다.
     * 동시에 잡아야 풀 전체의 분포가 보인다. 하나씩 꺼내 반납하면 같은 커넥션만 계속 나온다.
     */
    @GetMapping("/distribution")
    Map<String, Object> distribution() throws Exception {
        HikariDataSource h = (HikariDataSource) ds;
        int size = h.getHikariConfigMXBean().getMaximumPoolSize();
        java.sql.Connection[] held = new java.sql.Connection[size];
        Map<String, Integer> counts = new TreeMap<>();
        try {
            for (int i = 0; i < size; i++) {
                held[i] = ds.getConnection();
                try (var st = held[i].createStatement();
                     var rs = st.executeQuery("SELECT @@server_id")) {
                    rs.next();
                    String sid = rs.getString(1);
                    counts.merge(sid, 1, Integer::sum);
                }
            }
        } finally {
            for (java.sql.Connection c : held) {
                if (c != null) c.close();
            }
        }
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("pool_size", size);
        out.put("by_server", counts);
        // 가장 많이 몰린 인스턴스의 비중. 균등하면 1/N에 가깝다.
        int max = counts.values().stream().mapToInt(Integer::intValue).max().orElse(0);
        out.put("max_share_pct", Math.round(max * 1000.0 / size) / 10.0);
        return out;
    }

    /** 커넥션 하나가 붙은 인스턴스. 쿼리마다 바뀌지 않는다는 것을 보이는 용도다. */
    @GetMapping("/one")
    Map<String, Object> one() {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("server_id", jdbc.queryForObject("SELECT @@server_id", String.class));
        return out;
    }
}
