package lab;

import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/** 서버가 어떻게 죽는지 남기는 자리. OOM은 어디서 처음 터졌는지가 중요해서 따로 잡는다. */
public final class Metrics {

    public static final AtomicLong published = new AtomicLong();
    public static final AtomicLong oomCount = new AtomicLong();
    public static final AtomicReference<String> firstOom = new AtomicReference<>("");
    /** 브로드캐스터가 sendMessage 안에서 붙잡혀 있던 누적 시간(ms). direct 모드에서만 쌓인다. */
    public static final AtomicLong broadcastBlockedMillis = new AtomicLong();

    private Metrics() {
    }

    public static void recordOom(String where, OutOfMemoryError e) {
        oomCount.incrementAndGet();
        firstOom.compareAndSet("", where + ": " + e.getClass().getName() + ": " + e.getMessage());
        System.out.println("[OOM] " + where + " " + e);
    }
}
