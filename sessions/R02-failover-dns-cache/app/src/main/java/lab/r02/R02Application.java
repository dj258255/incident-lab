package lab.r02;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.net.InetAddress;
import java.security.Security;
import java.time.LocalDateTime;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * RDS Multi-AZ 페일오버는 DNS 레코드를 새 인스턴스로 바꾸는 방식이다.
 * DB는 1분 안에 복구되는데 앱만 계속 죽어 있는 상황이 이 세션의 주제다.
 *
 * JVM은 호스트명 해석 결과를 캐시한다. 보안 관리자가 설치돼 있으면 기본값이 영구 캐시(-1)이고,
 * 없으면 30초다. 어느 쪽이든 커넥션 풀이 살아 있는 커넥션을 재사용하는 한
 * 이름 해석 자체가 다시 일어나지 않아 옛 인스턴스를 계속 붙잡는다.
 *
 * 측정 대상
 *   - 지금 JVM이 db.internal을 무엇으로 알고 있는가 (InetAddress)
 *   - 지금 커넥션이 실제로 어느 인스턴스에 붙어 있는가 (@@server_id로 확인)
 *   - 페일오버 후 몇 초 만에 새 인스턴스로 넘어가는가
 */
@SpringBootApplication
public class R02Application {
    public static void main(String[] args) {
        // 시작 시점의 캐시 정책을 로그로 남긴다. 이 값이 이 세션의 변인이다.
        System.out.println("networkaddress.cache.ttl = "
                + Security.getProperty("networkaddress.cache.ttl"));
        System.out.println("networkaddress.cache.negative.ttl = "
                + Security.getProperty("networkaddress.cache.negative.ttl"));
        SpringApplication.run(R02Application.class, args);
    }
}

@RestController
class ProbeController {
    private final JdbcTemplate jdbc;

    ProbeController(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    /**
     * 한 번의 요청으로 세 가지를 함께 본다.
     * 셋이 어긋나는 순간이 곧 "DB는 살아 있는데 앱만 죽어 있는" 상태다.
     */
    @GetMapping("/probe")
    Map<String, Object> probe() {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("ts", LocalDateTime.now().toString());

        // 1. JVM이 지금 이름을 무엇으로 해석하는가
        try {
            out.put("resolved", InetAddress.getByName("db.internal").getHostAddress());
        } catch (Exception e) {
            out.put("resolved", "ERR:" + e.getClass().getSimpleName());
        }

        // 2. 실제 커넥션이 붙은 인스턴스. server_id로 A와 B를 구분한다.
        try {
            Map<String, Object> row = jdbc.queryForMap(
                    "SELECT @@server_id AS sid, @@read_only AS ro");
            out.put("server_id", row.get("sid"));
            out.put("read_only", row.get("ro"));
            out.put("db", "OK");
        } catch (Exception e) {
            out.put("db", "ERR:" + e.getClass().getSimpleName());
            out.put("db_msg", String.valueOf(e.getMessage()).replaceAll("\\s+", " ").substring(0,
                    Math.min(120, String.valueOf(e.getMessage()).length())));
        }
        return out;
    }

    /** 쓰기까지 되는지 본다. 읽기만 되는 상태와 구분하기 위해서다. */
    @GetMapping("/write")
    Map<String, Object> write() {
        Map<String, Object> out = new LinkedHashMap<>();
        try {
            jdbc.execute("CREATE TABLE IF NOT EXISTS probe (id BIGINT AUTO_INCREMENT PRIMARY KEY, "
                    + "at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3))");
            jdbc.update("INSERT INTO probe () VALUES ()");
            out.put("write", "OK");
        } catch (Exception e) {
            out.put("write", "ERR:" + e.getClass().getSimpleName());
        }
        return out;
    }
}
