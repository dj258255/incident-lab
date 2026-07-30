package lab.a19;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import jakarta.persistence.EntityManagerFactory;
import javax.sql.DataSource;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * A19의 "애플리케이션에 SAVEPOINT라는 단어가 없어도 생깁니다" 표를 실행으로 확인한다.
 *
 * 그 표는 공식 문서와 소스만으로 서술돼 있었다. 문서가 맞는지, 그리고 버전에 따라
 * 달라지지 않는지는 돌려 봐야 안다. PostgreSQL의 log_statement='all'을 켜고
 * 서버 로그에 SAVEPOINT가 실제로 찍히는지 본다.
 *
 * 확인할 네 경로다.
 *   1) NESTED + DataSourceTransactionManager  → SAVEPOINT가 나가야 한다
 *   2) NESTED + JpaTransactionManager         → 예외로 막혀야 한다
 *   3) REQUIRED 중첩 호출                      → 기존 트랜잭션에 합류하므로 없어야 한다
 *   4) REQUIRES_NEW                            → 별도 트랜잭션이므로 SAVEPOINT가 아니다
 */
@SpringBootApplication
public class SavepointProbe {
    public static void main(String[] args) {
        SpringApplication.run(SavepointProbe.class, args);
    }

    /**
     * 트랜잭션 매니저를 환경변수로 고른다.
     * Spring Boot는 JPA가 클래스패스에 있으면 JpaTransactionManager를 자동 구성하므로,
     * DataSourceTransactionManager를 쓰려면 이렇게 명시해야 한다.
     */
    @Bean @Primary
    PlatformTransactionManager txManager(@Value("${lab.tx-manager}") String kind,
                                         DataSource ds, EntityManagerFactory emf) {
        if ("jpa".equals(kind)) {
            var m = new JpaTransactionManager(emf);
            // JpaTransactionManager는 nestedTransactionAllowed가 기본 false다.
            // javadoc이 "JPA itself does not support nested transactions"라고 적어 두었다.
            return m;
        }
        return new DataSourceTransactionManager(ds);
    }
}

@Service
class Inner {
    private final JdbcTemplate jdbc;

    Inner(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    /** 중첩 트랜잭션. JDBC 매니저에서는 SAVEPOINT로 매핑된다. */
    @Transactional(propagation = Propagation.NESTED)
    void nested(int i) {
        jdbc.update("UPDATE sponsor SET amount = amount + 1 WHERE id = ?", i);
    }

    /** 기본 전파. 기존 트랜잭션에 합류하므로 SAVEPOINT가 없어야 한다. */
    @Transactional(propagation = Propagation.REQUIRED)
    void required(int i) {
        jdbc.update("UPDATE sponsor SET amount = amount + 1 WHERE id = ?", i);
    }

    /**
     * 별도 트랜잭션. 물리 트랜잭션이 따로 열리므로 SAVEPOINT가 아니다.
     *
     * 바깥 트랜잭션이 건드린 행을 여기서 또 갱신하면 자기 자신의 락을 기다려 멈춘다.
     * 처음 프로브가 그렇게 만들어져 응답이 오지 않았다. 겹치지 않는 행을 쓴다.
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    void requiresNew(int i) {
        jdbc.update("UPDATE sponsor SET amount = amount + 1 WHERE id = ?", 100000 + i);
    }
}

@Service
class Outer {
    private final Inner inner;
    private final JdbcTemplate jdbc;

    Outer(Inner inner, JdbcTemplate jdbc) { this.inner = inner; this.jdbc = jdbc; }

    /** 밖에서 트랜잭션을 열고 안쪽을 부른다. 자기 호출이 아니라 프록시를 지나야 한다. */
    @Transactional
    void run(String mode, int n) {
        // 바깥 트랜잭션이 XID를 먼저 확보한다. 이 행은 안쪽이 건드리지 않는 자리로 둔다.
        jdbc.update("UPDATE sponsor SET amount = amount + 1 WHERE id = 400000");
        for (int i = 1; i <= n; i++) {
            switch (mode) {
                case "nested" -> inner.nested(i);
                case "required" -> inner.required(i);
                case "requiresNew" -> inner.requiresNew(i);
                default -> throw new IllegalArgumentException(mode);
            }
        }
    }
}

@RestController
class ProbeController {
    private final Outer outer;
    private final JdbcTemplate jdbc;
    private final PlatformTransactionManager tm;

    ProbeController(Outer outer, JdbcTemplate jdbc, PlatformTransactionManager tm) {
        this.outer = outer; this.jdbc = jdbc; this.tm = tm;
    }

    /** /probe?mode=nested|required|requiresNew&n=3 */
    @GetMapping("/probe")
    Map<String, Object> probe(@RequestParam String mode,
                              @RequestParam(defaultValue = "3") int n) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("mode", mode);
        out.put("txManager", tm.getClass().getSimpleName());
        out.put("n", n);
        try {
            outer.run(mode, n);
            out.put("result", "ok");
        } catch (Exception e) {
            out.put("result", "exception");
            out.put("exception", e.getClass().getName());
            out.put("message", String.valueOf(e.getMessage()));
        }
        return out;
    }

    @GetMapping("/ping")
    Map<String, Object> ping() {
        return Map.of("txManager", tm.getClass().getSimpleName(),
                      "rows", jdbc.queryForObject("SELECT count(*) FROM sponsor", Integer.class));
    }
}
