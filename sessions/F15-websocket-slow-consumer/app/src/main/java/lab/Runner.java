package lab;

import java.io.IOException;
import java.io.PrintWriter;
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryMXBean;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;
import java.util.concurrent.locks.LockSupport;

import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.TextMessage;

/** 틱 발행기와 초 단위 계측기. 구독자가 다 붙으면 발행을 시작한다. */
@Component
public class Runner {

    private final Conf conf;
    private final StreamHandler handler;
    private final MemoryMXBean memory = ManagementFactory.getMemoryMXBean();

    private volatile boolean running = true;
    private volatile long startedAtMillis;
    private Thread publisher;
    private Thread sampler;
    private PrintWriter csv;

    public Runner(Conf conf, StreamHandler handler) {
        this.conf = conf;
        this.handler = handler;
    }

    @PostConstruct
    public void start() throws IOException {
        Path p = Path.of(conf.sampleFile);
        if (p.getParent() != null) {
            Files.createDirectories(p.getParent());
        }
        csv = new PrintWriter(Files.newBufferedWriter(p, StandardCharsets.UTF_8));
        csv.println("# mode=" + conf.mode + " label=" + conf.label + " tickRate=" + conf.tickRate
                + " symbols=" + conf.symbols + " payloadBytes=" + conf.payloadBytes
                + " queueCapacity=" + conf.queueCapacity + " bufferLimitBytes=" + conf.bufferLimitBytes
                + " sendTimeLimitMs=" + conf.sendTimeLimitMs
                + " blockingSendTimeoutMs=" + conf.blockingSendTimeoutMs
                + " heapMaxMB=" + (Runtime.getRuntime().maxMemory() >> 20));
        csv.println("t_s,heap_used_mb,heap_max_mb,published,published_per_s,delivered_per_s,"
                + "slow_queue_msgs,slow_queue_mb,normal_queue_msgs_max,normal_queue_mb_max,"
                + "dropped_total,closed_sessions,gc_count,gc_ms,broadcast_blocked_ms,oom");
        csv.flush();

        publisher = new Thread(this::publishLoop, "publisher");
        publisher.setDaemon(true);
        publisher.start();

        sampler = new Thread(this::sampleLoop, "sampler");
        sampler.setDaemon(true);
        sampler.start();
    }

    @PreDestroy
    public void stop() {
        running = false;
        if (csv != null) {
            csv.flush();
            csv.close();
        }
    }

    private void publishLoop() {
        // 구독자가 다 붙을 때까지 기다린다. 모든 회차의 t=0을 같게 만들기 위한 것이다.
        while (running && handler.subscribers().size() < conf.expectClients) {
            LockSupport.parkNanos(20_000_000L);
        }
        startedAtMillis = System.currentTimeMillis();
        System.out.println("[publish] 시작. 구독자 " + handler.subscribers().size() + "명, "
                + conf.tickRate + " ticks/s, 종목 " + conf.symbols + "개, 틱 " + conf.payloadBytes + "B");

        String[] symbols = new String[conf.symbols];
        for (int i = 0; i < conf.symbols; i++) {
            symbols[i] = String.format("%06d", 5930 + i * 7);
        }
        long[] price = new long[conf.symbols];
        for (int i = 0; i < conf.symbols; i++) {
            price[i] = 50_000 + i * 137L;
        }

        // 2ms마다 batch개씩 낸다. parkNanos 해상도가 수십 마이크로초라 틱마다 재우면 정확도가 떨어진다.
        final long slotNanos = 2_000_000L;
        final int batch = Math.max(1, (int) Math.round(conf.tickRate * 2.0 / 1000.0));
        long seq = 0;
        long deadline = System.nanoTime();
        int si = 0;
        java.util.Random rnd = new java.util.Random(42);

        while (running) {
            deadline += slotNanos;
            for (int i = 0; i < batch && running; i++) {
                si = (si + 1) % conf.symbols;
                price[si] += rnd.nextInt(21) - 10;
                seq++;
                long now = System.currentTimeMillis();
                String payload = payload(seq, symbols[si], now, price[si], conf.payloadBytes);
                Tick tick = new Tick(seq, symbols[si], now, new TextMessage(payload), payload.length());
                long t0 = System.nanoTime();
                try {
                    handler.broadcast(tick);
                } catch (OutOfMemoryError oom) {
                    Metrics.recordOom("publisher", oom);
                } catch (Throwable t) {
                    System.out.println("[publish] broadcast 예외: " + t);
                }
                long blockedMs = (System.nanoTime() - t0) / 1_000_000L;
                if (blockedMs > 0) {
                    Metrics.broadcastBlockedMillis.addAndGet(blockedMs);
                }
                Metrics.published.incrementAndGet();
            }
            long wait = deadline - System.nanoTime();
            if (wait > 0) {
                LockSupport.parkNanos(wait);
            } else {
                // 발행이 밀렸다. 따라잡으려 몰아치지 않고 기준선을 현재로 옮긴다.
                deadline = System.nanoTime();
            }
        }
    }

    /** 호가 10단계 스냅샷을 흉내 낸 텍스트. 목표 바이트까지 pad로 채운다. */
    private static String payload(long seq, String sym, long millis, long last, int target) {
        StringBuilder sb = new StringBuilder(target + 32);
        sb.append("{\"seq\":").append(seq)
                .append(",\"sym\":\"").append(sym).append('"')
                .append(",\"t\":").append(millis)
                .append(",\"last\":").append(last)
                .append(",\"bids\":[");
        for (int i = 0; i < 10; i++) {
            if (i > 0) {
                sb.append(',');
            }
            sb.append('[').append(last - (i + 1) * 10).append(',').append(100 + i * 37).append(']');
        }
        sb.append("],\"asks\":[");
        for (int i = 0; i < 10; i++) {
            if (i > 0) {
                sb.append(',');
            }
            sb.append('[').append(last + (i + 1) * 10).append(',').append(120 + i * 41).append(']');
        }
        sb.append("],\"pad\":\"");
        while (sb.length() < target - 3) {
            sb.append('x');
        }
        sb.append("\"}");
        return sb.toString();
    }

    private void sampleLoop() {
        long prevPublished = 0;
        long prevDelivered = 0;
        while (running) {
            LockSupport.parkNanos(1_000_000_000L);
            try {
                handler.enforceLimits();
            } catch (OutOfMemoryError oom) {
                Metrics.recordOom("sampler.enforceLimits", oom);
            }
            if (startedAtMillis == 0) {
                continue;
            }
            try {
            long t = (System.currentTimeMillis() - startedAtMillis) / 1000;
            long heapUsed = memory.getHeapMemoryUsage().getUsed();
            long heapMax = memory.getHeapMemoryUsage().getMax();
            long published = Metrics.published.get();

            long slowQ = 0;
            long slowBytes = 0;
            long normalQ = 0;
            long normalBytes = 0;
            long dropped = 0;
            long closed = 0;
            long delivered = 0;
            for (Subscribers.Subscriber s : handler.subscribers().values()) {
                delivered += s.delivered.get();
                dropped += s.dropped.get();
                if (s.closed) {
                    closed++;
                }
                if (s.id.startsWith("slow")) {
                    slowQ = Math.max(slowQ, s.queuedMessages());
                    slowBytes = Math.max(slowBytes, s.queuedBytes());
                } else {
                    normalQ = Math.max(normalQ, s.queuedMessages());
                    normalBytes = Math.max(normalBytes, s.queuedBytes());
                }
            }

            long gcCount = 0;
            long gcMs = 0;
            for (GarbageCollectorMXBean b : ManagementFactory.getGarbageCollectorMXBeans()) {
                gcCount += Math.max(0, b.getCollectionCount());
                gcMs += Math.max(0, b.getCollectionTime());
            }

            String row = String.format(Locale.ROOT,
                    "%d,%.1f,%.1f,%d,%d,%d,%d,%.2f,%d,%.2f,%d,%d,%d,%d,%d,%d",
                    t, heapUsed / 1048576.0, heapMax / 1048576.0, published,
                    published - prevPublished, delivered - prevDelivered,
                    slowQ, slowBytes / 1048576.0, normalQ, normalBytes / 1048576.0,
                    dropped, closed, gcCount, gcMs,
                    Metrics.broadcastBlockedMillis.get(), Metrics.oomCount.get());
            csv.println(row);
            csv.flush();
            System.out.printf(Locale.ROOT,
                    "[t=%3ds] heap=%6.1f/%.0fMB  발행=%6d/s  전달=%7d/s  느린클라 큐=%7d건 %6.2fMB  "
                            + "정상클라 큐 최대=%4d건  드롭=%d  종료=%d  GC=%dms  브로드캐스트차단=%dms%n",
                    t, heapUsed / 1048576.0, heapMax / 1048576.0,
                    published - prevPublished, delivered - prevDelivered,
                    slowQ, slowBytes / 1048576.0, normalQ, dropped, closed, gcMs,
                    Metrics.broadcastBlockedMillis.get());
            prevPublished = published;
            prevDelivered = delivered;
            } catch (OutOfMemoryError oom) {
                Metrics.recordOom("sampler", oom);
            } catch (Throwable t) {
                System.out.println("[sampler] " + t);
            }
        }
    }
}
