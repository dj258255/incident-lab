package lab.b01;

import com.zaxxer.hikari.HikariDataSource;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.transaction.annotation.Transactional;

import javax.sql.DataSource;
import java.sql.Connection;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicLong;

/**
 * 커넥션 풀 데드락을 재현한다.
 *
 * 한 요청이 커넥션을 두 개 동시에 잡는 코드가 원인이다. 실무에서 이런 모양이 나오는 경로는 여럿이다.
 *   - 원장은 마스터, 통계는 슬레이브로 데이터소스가 갈려 있는데 한 트랜잭션에서 둘 다 건드린다
 *   - @Transactional 안에서 다른 데이터소스를 쓰는 메서드를 부른다
 *   - 레거시 DB와 신규 DB를 한 요청에서 함께 쓴다
 *
 * 풀이 N개일 때 동시 요청이 N개를 넘으면, 모든 요청이 첫 커넥션만 잡은 채로
 * 두 번째 커넥션을 기다린다. 아무도 내놓지 않으므로 전원이 멈춘다.
 * DB는 한가한데 애플리케이션만 죽는다.
 */
@SpringBootApplication
public class B01Application {
    public static void main(String[] args) {
        SpringApplication.run(B01Application.class, args);
    }
}

/**
 * 우아한형제들 사례의 엔티티. GenerationType.AUTO가 핵심이다.
 * MySQL에는 시퀀스가 없어 Hibernate가 시퀀스 테이블을 대신 쓴다. 채번할 때 그 테이블을
 * 별도 커넥션의 서브 트랜잭션에서 FOR UPDATE로 잠그므로, save() 한 번이 커넥션 두 개를
 * 동시에 요구한다. 개발자가 커넥션을 두 개 잡는 코드를 쓴 적이 없는데도 그렇게 된다.
 *
 * 다만 Hibernate 6에서 두 가지가 달라졌고, 이 랩에서 확인했다.
 *   - 테이블 이름이 전역 hibernate_sequence가 아니라 엔티티별 sponsor_jpa_seq다
 *   - pooled 옵티마이저가 기본이라 allocationSize=50만큼 미리 받아 둔다
 *     (next_val이 1 → 51 → 101로 뛰고 그사이 50건은 채번하지 않는다)
 * 그래서 두 번째 커넥션은 50건에 한 번만 필요하다. 재현 강도가 원 사례보다 약하다.
 */
@Entity @Table(name = "sponsor_jpa")
class SponsorJpa {
    @Id @GeneratedValue(strategy = GenerationType.AUTO) Long id;
    @Column(name = "live_id") Long liveId;
    Integer amount;

    protected SponsorJpa() {}
    SponsorJpa(Long liveId, Integer amount) { this.liveId = liveId; this.amount = amount; }
}

interface SponsorJpaRepo extends JpaRepository<SponsorJpa, Long> {}

@Service
class SponsorService {
    private final DataSource ds;
    private final JdbcTemplate jdbc;
    @Value("${lab.hold-ms:50}") long holdMs;

    // @Transactional이 붙은 빈은 프록시로 감싸인다. 밖에서 필드를 직접 읽으면
    // 대상 객체가 아니라 프록시의 미초기화 필드를 보게 되므로 접근자를 둔다(R13에서 겪은 함정).
    private final AtomicLong ok = new AtomicLong();
    private final AtomicLong fail = new AtomicLong();

    long okCount()   { return ok.get(); }
    long failCount() { return fail.get(); }
    void addOk()     { ok.incrementAndGet(); }
    void addFail()   { fail.incrementAndGet(); }

    private final SponsorJpaRepo jpaRepo;

    SponsorService(DataSource ds, JdbcTemplate jdbc, SponsorJpaRepo jpaRepo) {
        this.ds = ds; this.jdbc = jdbc; this.jpaRepo = jpaRepo;
    }

    /**
     * 우아한형제들 사례 그대로. save() 한 번만 부른다.
     * 커넥션을 두 개 잡는 코드가 어디에도 없는데 실제로는 두 개가 필요하다.
     */
    @Transactional
    void sponsorJpaSave(long liveId, int amount) {
        jpaRepo.save(new SponsorJpa(liveId, amount));
    }

    /**
     * 커넥션을 두 개 동시에 잡는 후원 처리.
     * 첫 번째로 원장에 쓰고, 그것을 들고 있는 채로 두 번째를 빌려 통계를 갱신한다.
     */
    void sponsorTwoConnections(long liveId, int amount) throws Exception {
        try (Connection ledger = ds.getConnection()) {                 // 커넥션 1
            try (var ps = ledger.prepareStatement(
                    "INSERT INTO sponsor (live_id, amount) VALUES (?,?)")) {
                ps.setLong(1, liveId);
                ps.setInt(2, amount);
                ps.executeUpdate();
            }
            // 여기서 첫 커넥션을 아직 반납하지 않았다. 그 상태로 두 번째를 요청한다.
            Thread.sleep(holdMs);
            try (Connection stat = ds.getConnection()) {               // 커넥션 2
                try (var ps = stat.prepareStatement(
                        "UPDATE live_stat SET total = total + ? WHERE live_id = ?")) {
                    ps.setInt(1, amount);
                    ps.setLong(2, liveId);
                    ps.executeUpdate();
                }
            }
        }
    }

    /** 고친 버전. 첫 커넥션을 반납한 뒤 두 번째를 빌린다. 동시에 잡는 최대 개수가 1이 된다. */
    void sponsorOneAtATime(long liveId, int amount) throws Exception {
        try (Connection ledger = ds.getConnection()) {
            try (var ps = ledger.prepareStatement(
                    "INSERT INTO sponsor (live_id, amount) VALUES (?,?)")) {
                ps.setLong(1, liveId);
                ps.setInt(2, amount);
                ps.executeUpdate();
            }
        }
        Thread.sleep(holdMs);
        try (Connection stat = ds.getConnection()) {
            try (var ps = stat.prepareStatement(
                    "UPDATE live_stat SET total = total + ? WHERE live_id = ?")) {
                ps.setInt(1, amount);
                ps.setLong(2, liveId);
                ps.executeUpdate();
            }
        }
    }
}

@RestController
class SponsorController {
    private final SponsorService svc;
    private final DataSource ds;
    private final JdbcTemplate jdbc;

    SponsorController(SponsorService svc, DataSource ds, JdbcTemplate jdbc) {
        this.svc = svc; this.ds = ds; this.jdbc = jdbc;
    }

    @GetMapping("/sponsor")
    Map<String, Object> sponsor(@RequestParam(defaultValue = "two") String mode) {
        long t0 = System.nanoTime();
        Map<String, Object> out = new LinkedHashMap<>();
        long liveId = ThreadLocalRandom.current().nextInt(1, 6);
        try {
            switch (mode) {
                case "two" -> svc.sponsorTwoConnections(liveId, 1000);
                case "jpa" -> svc.sponsorJpaSave(liveId, 1000);
                default -> svc.sponsorOneAtATime(liveId, 1000);
            }
            svc.addOk();
            out.put("status", "ok");
        } catch (Exception e) {
            svc.addFail();
            out.put("status", "err");
            out.put("error", e.getClass().getSimpleName());
            String m = String.valueOf(e.getMessage());
            out.put("msg", m.length() > 90 ? m.substring(0, 90) : m);
        }
        out.put("ms", (System.nanoTime() - t0) / 1_000_000);
        return out;
    }

    /** 풀 상태. 대기 중인 스레드 수가 이 세션의 핵심 지표다. */
    @GetMapping("/pool")
    Map<String, Object> pool() throws Exception {
        HikariDataSource h = (HikariDataSource) ds;
        // HikariCP는 첫 커넥션 요청 때 풀을 만든다. 그전에는 MXBean이 null이다.
        if (h.getHikariPoolMXBean() == null) {
            try (Connection c = ds.getConnection()) { c.isValid(1); }
        }
        var mx = h.getHikariPoolMXBean();
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("total", mx.getTotalConnections());
        out.put("active", mx.getActiveConnections());
        out.put("idle", mx.getIdleConnections());
        out.put("awaiting", mx.getThreadsAwaitingConnection());
        out.put("ok", svc.okCount());
        out.put("fail", svc.failCount());
        // DB 쪽에서 본 커넥션 수. 풀이 말라도 DB는 한가하다는 것을 보인다.
        try {
            out.put("db_threads_connected", jdbc.queryForObject(
                    "SELECT VARIABLE_VALUE FROM performance_schema.global_status "
                    + "WHERE VARIABLE_NAME='Threads_connected'", Integer.class));
        } catch (Exception e) {
            out.put("db_threads_connected", -1);
        }
        return out;
    }
}
