package lab.r13;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Table;
import jakarta.persistence.Version;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.dao.OptimisticLockingFailureException;
import org.springframework.data.jpa.repository.*;
import org.springframework.data.redis.core.RedisCallback;
import org.springframework.data.redis.core.StringRedisTemplate;

import java.nio.charset.StandardCharsets;
import org.springframework.data.repository.query.Param;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;

import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicLong;

/**
 * 라이브 방송 후원 API의 최소 재현.
 *
 * 후원 한 건은 "원장 기록 + 누적 카운터 갱신"이 한 트랜잭션에서 일어난다.
 * 일곱 변형 모두 원장 INSERT는 동일하게 수행하고 카운터 갱신 방식만 바꾼다.
 * 그래야 측정된 차이가 카운터 전략에서 왔다고 말할 수 있다.
 *
 *   jpa-naive       엔티티를 읽어 값을 더하고 저장한다. JPA로 카운터를 짤 때 가장 먼저 나오는 코드다
 *   jpa-optimistic  @Version으로 충돌을 감지하고 재시도한다
 *   jpa-pessimistic 행에 X락을 먼저 걸고 읽는다
 *   atomic          읽지 않고 UPDATE 한 문장으로 증가시킨다
 *   slot            방송당 슬롯 N행으로 쓰기를 분산한다
 *   redis           카운터는 Redis에서 올리고 주기적으로 DB에 반영한다
 *   redis-pipe      위와 같되 두 명령을 파이프라인으로 묶어 왕복을 한 번으로 줄인다
 */
@SpringBootApplication
@EnableScheduling
public class R13Application {
    public static void main(String[] args) {
        SpringApplication.run(R13Application.class, args);
    }
}

/* ── 엔티티 ─────────────────────────────────────────────── */

@Entity @Table(name = "sponsor_log")
class SponsorLog {
    @Id @GeneratedValue(strategy = GenerationType.IDENTITY) Long id;
    @Column(name = "live_id") Long liveId;
    @Column(name = "user_id") Long userId;
    Integer amount;

    protected SponsorLog() {}
    SponsorLog(Long liveId, Long userId, Integer amount) {
        this.liveId = liveId; this.userId = userId; this.amount = amount;
    }
}

@Entity @Table(name = "live_counter")
class LiveCounter {
    @Id @Column(name = "live_id") Long liveId;
    @Column(name = "total_amount") Long totalAmount = 0L;
    @Column(name = "sponsor_count") Integer sponsorCount = 0;

    void add(int amount) { this.totalAmount += amount; this.sponsorCount += 1; }
}

@Entity @Table(name = "live_counter_v")
class LiveCounterV {
    @Id @Column(name = "live_id") Long liveId;
    @Column(name = "total_amount") Long totalAmount = 0L;
    @Column(name = "sponsor_count") Integer sponsorCount = 0;
    @Version Long version;

    void add(int amount) { this.totalAmount += amount; this.sponsorCount += 1; }
}

/* ── 리포지토리 ─────────────────────────────────────────── */

interface SponsorLogRepo extends JpaRepository<SponsorLog, Long> {}

interface LiveCounterRepo extends JpaRepository<LiveCounter, Long> {

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("select c from LiveCounter c where c.liveId = :id")
    Optional<LiveCounter> findByIdForUpdate(@Param("id") Long id);

    /** 읽지 않고 한 문장으로 증가시킨다. 읽기와 쓰기 사이에 틈이 없어 값이 겹쳐 쓰이지 않는다. */
    @Modifying
    @Query(value = "UPDATE live_counter SET total_amount = total_amount + :amt, "
                 + "sponsor_count = sponsor_count + 1 WHERE live_id = :id", nativeQuery = true)
    int increment(@Param("id") Long id, @Param("amt") int amt);
}

interface LiveCounterVRepo extends JpaRepository<LiveCounterV, Long> {}

/* ── 서비스 ─────────────────────────────────────────────── */

@Service
class CounterService {
    private final SponsorLogRepo logRepo;
    private final LiveCounterRepo counterRepo;
    private final LiveCounterVRepo counterVRepo;
    private final JdbcTemplate jdbc;
    private final StringRedisTemplate redis;

    @Value("${lab.mode}") String mode;
    @Value("${lab.slots}") int slots;
    @Value("${lab.optimistic-retry}") int optimisticRetry;

    /**
     * 낙관적 락이 몇 번이나 되감았는지 센다. 처리량만 보면 재시도 비용이 보이지 않는다.
     * 이 빈은 @Transactional 때문에 프록시로 감싸지므로, 외부에서 필드로 직접 읽으면
     * 대상 객체가 아니라 프록시의 미초기화 필드를 보게 된다. 반드시 메서드로 접근한다.
     */
    private final AtomicLong optimisticRetries = new AtomicLong();
    private final AtomicLong optimisticGiveUps = new AtomicLong();

    long retries()  { return optimisticRetries.get(); }
    long giveUps()  { return optimisticGiveUps.get(); }
    void resetCounters() { optimisticRetries.set(0); optimisticGiveUps.set(0); }

    CounterService(SponsorLogRepo l, LiveCounterRepo c, LiveCounterVRepo cv,
                   JdbcTemplate j, StringRedisTemplate r) {
        this.logRepo = l; this.counterRepo = c; this.counterVRepo = cv;
        this.jdbc = j; this.redis = r;
    }

    /**
     * 변형 1. 엔티티를 읽어서 더하고 저장한다.
     * 읽은 시점과 쓰는 시점 사이에 다른 트랜잭션이 끼어들면 그 후원이 덮여 사라진다.
     */
    @Transactional
    void naive(long liveId, long userId, int amount) {
        logRepo.save(new SponsorLog(liveId, userId, amount));
        LiveCounter c = counterRepo.findById(liveId).orElseThrow();
        c.add(amount);   // 더티 체킹으로 커밋 시점에 UPDATE가 나간다
    }

    void countRetry()  { optimisticRetries.incrementAndGet(); }
    void countGiveUp() { optimisticGiveUps.incrementAndGet(); }

    /** 변형 2의 한 번 시도. 재시도 루프는 트랜잭션 밖에 있어야 하므로 호출자가 따로 돈다. */
    @Transactional
    void optimisticOnce(long liveId, long userId, int amount) {
        logRepo.save(new SponsorLog(liveId, userId, amount));
        LiveCounterV c = counterVRepo.findById(liveId).orElseThrow();
        c.add(amount);
        counterVRepo.flush();   // 커밋 밖이 아니라 여기서 충돌을 드러낸다
    }

    /** 변형 3. 읽기 전에 X락을 잡는다. 정확하지만 락을 잡은 채 커밋까지 간다. */
    @Transactional
    void pessimistic(long liveId, long userId, int amount) {
        logRepo.save(new SponsorLog(liveId, userId, amount));
        LiveCounter c = counterRepo.findByIdForUpdate(liveId).orElseThrow();
        c.add(amount);
    }

    /** 변형 4. 읽지 않고 UPDATE 한 문장으로 증가시킨다. */
    @Transactional
    void atomic(long liveId, long userId, int amount) {
        logRepo.save(new SponsorLog(liveId, userId, amount));
        counterRepo.increment(liveId, amount);
    }

    /** 변형 5. 방송당 슬롯 N개 중 하나를 갱신해 쓰기를 흩는다. */
    @Transactional
    void slot(long liveId, long userId, int amount) {
        logRepo.save(new SponsorLog(liveId, userId, amount));
        int s = ThreadLocalRandom.current().nextInt(slots);
        jdbc.update("""
            INSERT INTO live_counter_slot (live_id, slot, total_amount, sponsor_count)
            VALUES (?,?,?,1)
            ON DUPLICATE KEY UPDATE total_amount = total_amount + VALUES(total_amount),
                                    sponsor_count = sponsor_count + 1
            """, liveId, s, amount);
    }

    /** 변형 6. 원장은 DB에 남기고 카운터만 Redis에서 올린다. 명령 두 개가 각각 왕복한다. */
    @Transactional
    void redis(long liveId, long userId, int amount) {
        logRepo.save(new SponsorLog(liveId, userId, amount));
        String k = String.valueOf(liveId);
        redis.opsForHash().increment("live:amount", k, amount);
        redis.opsForHash().increment("live:count", k, 1);
    }

    /**
     * 변형 7. 같은 일을 파이프라인으로 묶어 왕복을 한 번으로 줄인다.
     * 변형 6이 슬롯보다 느리게 나와 원인을 좁히려고 추가한 변형이다.
     */
    @Transactional
    void redisPipelined(long liveId, long userId, int amount) {
        logRepo.save(new SponsorLog(liveId, userId, amount));
        byte[] k = String.valueOf(liveId).getBytes(StandardCharsets.UTF_8);
        redis.executePipelined((RedisCallback<Object>) conn -> {
            conn.hashCommands().hIncrBy("live:amount".getBytes(StandardCharsets.UTF_8), k, amount);
            conn.hashCommands().hIncrBy("live:count".getBytes(StandardCharsets.UTF_8), k, 1);
            return null;
        });
    }

    /** Redis 값을 DB로 옮긴다. 델타가 아니라 절대값을 덮어써 두 번 돌아도 결과가 같다. */
    @Scheduled(fixedDelayString = "${lab.flush-sec}000")
    void flush() {
        if (!mode.startsWith("redis")) return;
        flushNow();
    }

    void flushNow() {
        Map<Object, Object> amounts = redis.opsForHash().entries("live:amount");
        if (amounts.isEmpty()) return;
        Map<Object, Object> counts = redis.opsForHash().entries("live:count");
        List<Object[]> batch = new ArrayList<>();
        amounts.forEach((k, v) -> batch.add(new Object[]{
                Long.parseLong(k.toString()),
                Long.parseLong(v.toString()),
                Long.parseLong(String.valueOf(counts.getOrDefault(k, "0")))
        }));
        jdbc.batchUpdate("""
            INSERT INTO live_counter (live_id, total_amount, sponsor_count) VALUES (?,?,?)
            ON DUPLICATE KEY UPDATE total_amount = VALUES(total_amount),
                                    sponsor_count = VALUES(sponsor_count)
            """, batch);
    }
}

/**
 * 모드 분기와 재시도만 담당한다.
 * 트랜잭션 경계를 여는 메서드는 CounterService에 있고, 여기서 호출하면 프록시를 지나므로
 * @Transactional이 정상 적용된다. 같은 빈 안에서 this로 부르면 프록시를 건너뛰어 적용되지 않는다.
 */
@Service
class SponsorService {
    private final CounterService counter;
    @Value("${lab.mode}") String mode;
    @Value("${lab.optimistic-retry}") int optimisticRetry;

    SponsorService(CounterService counter) { this.counter = counter; }

    /**
     * 방송별 자물쇠. 같은 JVM 안에서만 유효하다.
     * 인스턴스를 두 대로 늘리면 각 JVM이 자기 자물쇠만 보므로 갱신 유실이 다시 생긴다.
     * 이 변형은 그 사실을 실측으로 보이려고 둔다.
     */
    private final ConcurrentHashMap<Long, Object> jvmLocks = new ConcurrentHashMap<>();

    void sponsor(long liveId, long userId, int amount) {
        switch (mode) {
            case "jpa-naive"       -> counter.naive(liveId, userId, amount);
            case "jvm-lock"        -> jvmLocked(liveId, userId, amount);
            case "jpa-optimistic"  -> optimistic(liveId, userId, amount);
            case "jpa-pessimistic" -> counter.pessimistic(liveId, userId, amount);
            case "atomic"          -> counter.atomic(liveId, userId, amount);
            case "slot"            -> counter.slot(liveId, userId, amount);
            case "redis"           -> counter.redis(liveId, userId, amount);
            case "redis-pipe"      -> counter.redisPipelined(liveId, userId, amount);
            default -> throw new IllegalStateException("알 수 없는 mode: " + mode);
        }
    }

    /** 자물쇠를 잡은 채로 트랜잭션을 열고 닫는다. 순서가 뒤바뀌면 자물쇠가 커밋을 보호하지 못한다. */
    private void jvmLocked(long liveId, long userId, int amount) {
        synchronized (jvmLocks.computeIfAbsent(liveId, k -> new Object())) {
            counter.naive(liveId, userId, amount);
        }
    }

    /** 버전이 어긋나면 예외가 나므로 트랜잭션 밖에서 잡아 다시 시도한다. */
    private void optimistic(long liveId, long userId, int amount) {
        for (int i = 0; i < optimisticRetry; i++) {
            try {
                counter.optimisticOnce(liveId, userId, amount);
                return;
            } catch (OptimisticLockingFailureException e) {
                counter.countRetry();
            }
        }
        counter.countGiveUp();
        throw new IllegalStateException("낙관적 락 재시도 소진");
    }

    long retries() { return counter.retries(); }
    long giveUps() { return counter.giveUps(); }
    void resetCounters() { counter.resetCounters(); }
    void flushNow() { counter.flushNow(); }
}

/* ── 컨트롤러 ───────────────────────────────────────────── */

record SponsorReq(long liveId, long userId, int amount) {}

@RestController
class SponsorController {
    private final SponsorService svc;
    private final JdbcTemplate jdbc;
    private final StringRedisTemplate redis;
    @Value("${lab.mode}") String mode;
    @Value("${lab.slots}") int slots;
    @Value("${lab.lives}") int lives;

    SponsorController(SponsorService s, JdbcTemplate j, StringRedisTemplate r) {
        this.svc = s; this.jdbc = j; this.redis = r;
    }

    @PostMapping("/sponsor")
    void sponsor(@RequestBody SponsorReq req) {
        svc.sponsor(req.liveId(), req.userId(), req.amount());
    }

    @PostMapping("/reset")
    void reset() {
        jdbc.execute("TRUNCATE sponsor_log");
        jdbc.execute("TRUNCATE live_counter");
        jdbc.execute("TRUNCATE live_counter_slot");
        jdbc.execute("TRUNCATE live_counter_v");
        List<Object[]> rows = new ArrayList<>();
        for (long i = 1; i <= lives; i++) rows.add(new Object[]{i});
        jdbc.batchUpdate("INSERT INTO live_counter (live_id, total_amount, sponsor_count) VALUES (?,0,0)", rows);
        jdbc.batchUpdate("INSERT INTO live_counter_v (live_id, total_amount, sponsor_count, version) VALUES (?,0,0,0)", rows);
        redis.delete(List.of("live:amount", "live:count"));
        svc.resetCounters();
    }

    /**
     * 방송 하나의 현재 총액을 읽는다. 슬롯 카운터가 치르는 대가가 여기서 드러난다.
     * 단일 행은 PK 한 건 조회지만 슬롯은 방송당 N행을 훑어 합쳐야 한다.
     */
    @GetMapping("/total/{liveId}")
    Map<String, Object> total(@PathVariable long liveId) {
        if (mode.startsWith("redis")) {
            Object amt = redis.opsForHash().get("live:amount", String.valueOf(liveId));
            Object cnt = redis.opsForHash().get("live:count", String.valueOf(liveId));
            return Map.of("live_id", liveId,
                    "total_amount", amt == null ? 0L : Long.parseLong(amt.toString()),
                    "sponsor_count", cnt == null ? 0L : Long.parseLong(cnt.toString()));
        }
        String sql = switch (mode) {
            case "slot" -> "SELECT COALESCE(SUM(total_amount),0) amt, COALESCE(SUM(sponsor_count),0) cnt "
                         + "FROM live_counter_slot WHERE live_id = ?";
            case "jpa-optimistic" -> "SELECT total_amount amt, sponsor_count cnt FROM live_counter_v WHERE live_id = ?";
            default -> "SELECT total_amount amt, sponsor_count cnt FROM live_counter WHERE live_id = ?";
        };
        Map<String, Object> row = jdbc.queryForMap(sql, liveId);
        return Map.of("live_id", liveId,
                "total_amount", ((Number) row.get("amt")).longValue(),
                "sponsor_count", ((Number) row.get("cnt")).longValue());
    }

    /**
     * 카운터를 원장에서 다시 만든다.
     * 카운터는 파생 데이터라서 언제든 버리고 다시 계산할 수 있다는 것이 원장을 남기는 이유다.
     * Redis가 통째로 날아간 상황을 복구할 때 쓴다.
     */
    @PostMapping("/rebuild")
    Map<String, Object> rebuild() {
        long t0 = System.nanoTime();
        String target = switch (mode) {
            case "slot" -> "live_counter_slot";
            case "jpa-optimistic" -> "live_counter_v";
            default -> "live_counter";
        };
        jdbc.execute("TRUNCATE " + target);
        if (target.equals("live_counter_slot")) {
            // 복구본은 슬롯 0에 모아 둔다. 이후 쓰기가 다시 슬롯에 흩어진다.
            jdbc.update("""
                INSERT INTO live_counter_slot (live_id, slot, total_amount, sponsor_count)
                SELECT live_id, 0, SUM(amount), COUNT(*) FROM sponsor_log GROUP BY live_id
                """);
        } else if (target.equals("live_counter_v")) {
            jdbc.update("""
                INSERT INTO live_counter_v (live_id, total_amount, sponsor_count, version)
                SELECT live_id, SUM(amount), COUNT(*), 0 FROM sponsor_log GROUP BY live_id
                """);
        } else {
            jdbc.update("""
                INSERT INTO live_counter (live_id, total_amount, sponsor_count)
                SELECT live_id, SUM(amount), COUNT(*) FROM sponsor_log GROUP BY live_id
                """);
        }

        if (mode.startsWith("redis")) {
            // Redis도 원장 기준으로 다시 채운다. 비워 두면 다음 반영이 빈 값을 DB에 덮어쓴다.
            redis.delete(List.of("live:amount", "live:count"));
            Map<String, Object> amounts = new HashMap<>();
            Map<String, Object> counts = new HashMap<>();
            jdbc.query("SELECT live_id, SUM(amount) amt, COUNT(*) cnt FROM sponsor_log GROUP BY live_id",
                    rs -> {
                        String k = String.valueOf(rs.getLong("live_id"));
                        amounts.put(k, String.valueOf(rs.getLong("amt")));
                        counts.put(k, String.valueOf(rs.getLong("cnt")));
                    });
            if (!amounts.isEmpty()) {
                redis.opsForHash().putAll("live:amount", amounts);
                redis.opsForHash().putAll("live:count", counts);
            }
        }

        Map<String, Object> out = new LinkedHashMap<>();
        out.put("mode", mode);
        out.put("rebuilt_table", target);
        out.put("elapsed_ms", (System.nanoTime() - t0) / 1_000_000);
        return out;
    }

    /**
     * 원장 합계와 카운터 합계를 대조한다.
     * 처리량만 비교하고 정합성을 안 보면 "빠른데 틀린" 구현을 좋은 것으로 착각하게 된다.
     */
    @GetMapping("/verify")
    Map<String, Object> verify() {
        if (mode.startsWith("redis")) svc.flushNow();

        Long ledgerAmt = jdbc.queryForObject("SELECT COALESCE(SUM(amount),0) FROM sponsor_log", Long.class);
        Long ledgerCnt = jdbc.queryForObject("SELECT COUNT(*) FROM sponsor_log", Long.class);

        String table = switch (mode) {
            case "slot" -> "live_counter_slot";
            case "jpa-optimistic" -> "live_counter_v";
            default -> "live_counter";
        };
        Map<String, Object> agg = jdbc.queryForMap(
                "SELECT COALESCE(SUM(total_amount),0) amt, COALESCE(SUM(sponsor_count),0) cnt FROM " + table);
        long counterAmt = ((Number) agg.get("amt")).longValue();
        long counterCnt = ((Number) agg.get("cnt")).longValue();

        Map<String, Object> out = new LinkedHashMap<>();
        out.put("mode", mode);
        out.put("slots", slots);
        out.put("ledger_amount", ledgerAmt);
        out.put("ledger_count", ledgerCnt);
        out.put("counter_amount", counterAmt);
        out.put("counter_count", counterCnt);
        out.put("lost_amount", ledgerAmt - counterAmt);
        out.put("lost_count", ledgerCnt - counterCnt);
        out.put("match", ledgerAmt == counterAmt && ledgerCnt == counterCnt);
        out.put("optimistic_retries", svc.retries());
        out.put("optimistic_giveups", svc.giveUps());
        return out;
    }
}
