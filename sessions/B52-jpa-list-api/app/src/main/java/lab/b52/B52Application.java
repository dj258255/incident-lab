package lab.b52;

import jakarta.persistence.CascadeType;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EntityManager;
import jakarta.persistence.FetchType;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.OneToMany;
import jakarta.persistence.PersistenceContext;
import jakarta.persistence.Table;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.data.jpa.repository.EntityGraph;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;

/**
 * JPA로 목록 API를 만들 때 반복되는 세 가지 함정을 재현한다.
 *
 *   1. N+1        방송 20건을 가져오면서 각 방송의 후원을 지연 로딩해 쿼리가 21개가 된다
 *   2. 벌크 INSERT saveAll()이 이름과 달리 행마다 INSERT를 보낸다
 *   3. 페이지네이션 OFFSET이 깊어질수록 앞의 행을 전부 세고 버린다
 *
 * 측정은 응답 시간만이 아니라 "쿼리를 몇 개 보냈는가"를 함께 센다.
 * N+1은 개별 쿼리가 빨라서 슬로우 쿼리 로그에 안 걸리고, 쿼리 수로만 드러나기 때문이다.
 */
@SpringBootApplication
public class B52Application {
    public static void main(String[] args) {
        SpringApplication.run(B52Application.class, args);
    }
}

/* ── 엔티티 ─────────────────────────────────────────────── */

@Entity @Table(name = "live")
class Live {
    @Id @GeneratedValue(strategy = GenerationType.IDENTITY) Long id;
    String title;
    @Column(name = "streamer_id") Long streamerId;
    @Column(name = "created_at") LocalDateTime createdAt;

    /** 기본이 지연 로딩이다. 목록에서 이 컬렉션을 건드리는 순간 방송마다 쿼리가 한 번씩 나간다. */
    @OneToMany(mappedBy = "live", cascade = CascadeType.ALL, fetch = FetchType.LAZY)
    List<Sponsor> sponsors = new ArrayList<>();

    protected Live() {}
    Live(String title, Long streamerId, LocalDateTime createdAt) {
        this.title = title; this.streamerId = streamerId; this.createdAt = createdAt;
    }
}

@Entity @Table(name = "sponsor")
class Sponsor {
    @Id @GeneratedValue(strategy = GenerationType.IDENTITY) Long id;
    @jakarta.persistence.ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "live_id") Live live;
    @Column(name = "user_id") Long userId;
    Integer amount;
    @Column(name = "created_at") LocalDateTime createdAt;

    protected Sponsor() {}
    Sponsor(Live live, Long userId, Integer amount, LocalDateTime createdAt) {
        this.live = live; this.userId = userId; this.amount = amount; this.createdAt = createdAt;
    }
}

/* ── 리포지토리 ─────────────────────────────────────────── */

interface LiveRepo extends JpaRepository<Live, Long> {

    /** 변형 1. 지연 로딩 그대로. 컬렉션을 읽는 순간 N번이 더 나간다.
     *  세 변형이 같은 방송 20건을 보도록 구간을 받는다. 앞 20건으로 고정하면
     *  쏠림 때문에 후원이 몰려 있어 변형 간 비교가 데이터 편중에 흔들린다. */
    @Query("select l from Live l where l.id between :from and :to order by l.id")
    List<Live> findRange(@Param("from") long from, @Param("to") long to);

    /** 변형 2. fetch join. 한 방에 가져오지만 페이지네이션과 함께 쓰면 경고가 뜬다. */
    @Query("select distinct l from Live l left join fetch l.sponsors order by l.id")
    List<Live> findAllWithSponsors();

    /** 변형 3. EntityGraph. fetch join과 같은 효과를 선언으로 낸다. */
    @EntityGraph(attributePaths = "sponsors")
    @Query("select l from Live l where l.id between :from and :to order by l.id")
    List<Live> findRangeWithGraph(@Param("from") long from, @Param("to") long to);
}

interface SponsorRepo extends JpaRepository<Sponsor, Long> {}

/**
 * ID를 애플리케이션이 정해서 넣는 변형. @GeneratedValue가 없다.
 * IDENTITY 전략이 배치를 막는지 확인하기 위한 대조군이다.
 * IDENTITY는 INSERT마다 생성된 키를 돌려받아야 해서 하이버네이트가 배치를 포기한다.
 */
@Entity @Table(name = "sponsor_assigned")
class SponsorAssigned {
    @Id Long id;
    @Column(name = "live_id") Long liveId;
    @Column(name = "user_id") Long userId;
    Integer amount;
    @Column(name = "created_at") LocalDateTime createdAt;

    protected SponsorAssigned() {}
    SponsorAssigned(Long id, Long liveId, Long userId, Integer amount, LocalDateTime createdAt) {
        this.id = id; this.liveId = liveId; this.userId = userId;
        this.amount = amount; this.createdAt = createdAt;
    }
}

interface SponsorAssignedRepo extends JpaRepository<SponsorAssigned, Long> {}

/* ── 서비스 ─────────────────────────────────────────────── */

@Service
class ListService {
    private final LiveRepo liveRepo;
    private final SponsorRepo sponsorRepo;
    private final JdbcTemplate jdbc;
    @PersistenceContext EntityManager em;
    @Value("${lab.batch-size:0}") int batchSize;

    private final SponsorAssignedRepo assignedRepo;

    ListService(LiveRepo l, SponsorRepo s, SponsorAssignedRepo a, JdbcTemplate j) {
        this.liveRepo = l; this.sponsorRepo = s; this.assignedRepo = a; this.jdbc = j;
    }

    /** 목록 20건 + 방송별 후원 합계. 컬렉션을 실제로 순회해야 N+1이 발생한다. */
    @Transactional(readOnly = true)
    long listNaive(long from, long to) {
        long total = 0;
        for (Live l : liveRepo.findRange(from, to)) {
            for (Sponsor s : l.sponsors) total += s.amount;   // 여기서 방송마다 SELECT가 나간다
        }
        return total;
    }

    @Transactional(readOnly = true)
    long listGraph(long from, long to) {
        long total = 0;
        for (Live l : liveRepo.findRangeWithGraph(from, to)) {
            for (Sponsor s : l.sponsors) total += s.amount;
        }
        return total;
    }

    /** 변형 4. 목록 화면이 필요한 건 엔티티가 아니라 합계다. 집계로 한 방에 가져온다. */
    @Transactional(readOnly = true)
    long listProjection(long from, long to) {
        Long v = jdbc.queryForObject(
                "SELECT COALESCE(SUM(s.amount),0) FROM live l "
                + "LEFT JOIN sponsor s ON s.live_id = l.id WHERE l.id BETWEEN ? AND ?",
                Long.class, from, to);
        return v == null ? 0 : v;
    }

    /* ── 페이지네이션 ── */

    @Transactional(readOnly = true)
    List<Long> pageOffset(long offset, int size) {
        return jdbc.queryForList(
                "SELECT id FROM live ORDER BY created_at, id LIMIT ? OFFSET ?",
                Long.class, size, offset);
    }

    /**
     * 커서 방식 A. 행값 비교. 커서 페이지네이션의 표준 문법으로 소개되지만
     * MySQL 8.4에서 range 최적화를 받지 못해 전체 인덱스 스캔이 된다(EXPLAIN type=index).
     */
    @Transactional(readOnly = true)
    List<Long> pageCursorRowValue(String lastCreatedAt, long lastId, int size) {
        return jdbc.queryForList(
                "SELECT id FROM live WHERE (created_at, id) > (?, ?) "
                + "ORDER BY created_at, id LIMIT ?",
                Long.class, lastCreatedAt, lastId, size);
    }

    /** 커서 방식 B. 같은 조건을 풀어쓴다. 이쪽만 type=range로 인덱스 구간을 탄다. */
    @Transactional(readOnly = true)
    List<Long> pageCursorExpanded(String lastCreatedAt, long lastId, int size) {
        return jdbc.queryForList(
                "SELECT id FROM live WHERE created_at > ? "
                + "OR (created_at = ? AND id > ?) ORDER BY created_at, id LIMIT ?",
                Long.class, lastCreatedAt, lastCreatedAt, lastId, size);
    }

    /* ── 대량 삽입 ── */

    /** 변형 A. saveAll. 이름과 달리 행마다 INSERT가 나간다(배치 설정이 없으면). */
    @Transactional
    void insertSaveAll(long liveId, int n) {
        Live live = em.getReference(Live.class, liveId);
        List<Sponsor> rows = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            rows.add(new Sponsor(live, ThreadLocalRandom.current().nextLong(1, 500_000),
                    1000, LocalDateTime.now()));
        }
        sponsorRepo.saveAll(rows);
    }

    /** 변형 A-2. 같은 saveAll인데 ID를 직접 부여한다. 배치가 켜져 있으면 이번엔 묶인다. */
    @Transactional
    void insertSaveAllAssigned(long liveId, int n) {
        long base = System.nanoTime();
        List<SponsorAssigned> rows = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            rows.add(new SponsorAssigned(base + i, liveId,
                    ThreadLocalRandom.current().nextLong(1, 500_000), 1000, LocalDateTime.now()));
        }
        assignedRepo.saveAll(rows);
    }

    /** 변형 B. JDBC batchUpdate. 한 왕복에 여러 행을 보낸다. */
    @Transactional
    void insertJdbcBatch(long liveId, int n) {
        List<Object[]> rows = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            rows.add(new Object[]{liveId, ThreadLocalRandom.current().nextLong(1, 500_000),
                    1000, LocalDateTime.now()});
        }
        jdbc.batchUpdate("INSERT INTO sponsor (live_id, user_id, amount, created_at) VALUES (?,?,?,?)",
                rows);
    }
}

/* ── 컨트롤러 ───────────────────────────────────────────── */

@RestController
class ListController {
    private final ListService svc;
    private final JdbcTemplate jdbc;

    ListController(ListService s, JdbcTemplate j) { this.svc = s; this.jdbc = j; }

    /**
     * 서버가 받은 SELECT 수를 읽는다. 응답 시간만 보면 N+1은 보이지 않는다.
     * performance_schema.global_status에는 Com_* 카운터가 없어서 SHOW GLOBAL STATUS를 쓴다.
     * 이 값은 JPA와 JdbcTemplate을 가리지 않고 세므로 세 변형을 같은 자로 잰다.
     */
    private long queryCount() {
        Map<String, Object> row = jdbc.queryForMap("SHOW GLOBAL STATUS LIKE 'Com_select'");
        return Long.parseLong(String.valueOf(row.get("Value")));
    }

    private Map<String, Object> measure(String name, Runnable body) {
        long q0 = queryCount();
        long t0 = System.nanoTime();
        body.run();
        long ms = (System.nanoTime() - t0) / 1_000_000;
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("mode", name);
        out.put("elapsed_ms", ms);
        out.put("select_count", queryCount() - q0);   // SHOW는 Com_select를 올리지 않는다
        return out;
    }

    @GetMapping("/list")
    Map<String, Object> list(@RequestParam String mode,
                             @RequestParam(defaultValue = "20") int size,
                             @RequestParam(defaultValue = "1") long from) {
        long to = from + size - 1;
        return switch (mode) {
            case "naive" -> measure("naive", () -> svc.listNaive(from, to));
            case "graph" -> measure("graph", () -> svc.listGraph(from, to));
            case "projection" -> measure("projection", () -> svc.listProjection(from, to));
            default -> throw new IllegalArgumentException("알 수 없는 mode: " + mode);
        };
    }

    @GetMapping("/page")
    Map<String, Object> page(@RequestParam String mode,
                             @RequestParam(defaultValue = "0") long offset,
                             @RequestParam(defaultValue = "20") int size,
                             @RequestParam(required = false) String lastCreatedAt,
                             @RequestParam(defaultValue = "0") long lastId) {
        return switch (mode) {
            case "offset" -> measure("offset", () -> svc.pageOffset(offset, size));
            case "cursor-rowvalue" -> measure("cursor-rowvalue",
                    () -> svc.pageCursorRowValue(lastCreatedAt, lastId, size));
            default -> measure("cursor-expanded",
                    () -> svc.pageCursorExpanded(lastCreatedAt, lastId, size));
        };
    }

    @PostMapping("/insert")
    Map<String, Object> insert(@RequestParam String mode,
                               @RequestParam(defaultValue = "1") long liveId,
                               @RequestParam(defaultValue = "10000") int n) {
        long t0 = System.nanoTime();
        switch (mode) {
            case "saveAll" -> svc.insertSaveAll(liveId, n);
            case "saveAllAssigned" -> svc.insertSaveAllAssigned(liveId, n);
            default -> svc.insertJdbcBatch(liveId, n);
        }
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("mode", mode);
        out.put("rows", n);
        out.put("elapsed_ms", (System.nanoTime() - t0) / 1_000_000);
        return out;
    }

    /** 커서 페이지네이션의 시작점을 얻기 위해 offset 위치의 행을 하나 읽는다. */
    @GetMapping("/anchor")
    Map<String, Object> anchor(@RequestParam long offset) {
        Map<String, Object> row = jdbc.queryForMap(
                "SELECT id, DATE_FORMAT(created_at, '%Y-%m-%d %H:%i:%s.%f') created_at "
                + "FROM live ORDER BY created_at, id LIMIT 1 OFFSET ?", offset);
        return row;
    }
}
