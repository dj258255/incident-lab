package lab;

import java.util.Arrays;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * 지연 표본을 고정 크기 배열에 담아 두고 나중에 백분위를 계산한다.
 * 부하 중에는 인덱스만 증가시키고 정렬은 /stats를 부를 때 한 번만 한다.
 * 한 계층의 대기 시간이 전체 응답 시간 가운데 얼마인지 가르려고 넣은 계측이다.
 */
public class Recorder {

    private static final int CAP = 400_000;

    private final String name;
    private final long[] nanos = new long[CAP];
    private final AtomicInteger idx = new AtomicInteger();

    public Recorder(String name) {
        this.name = name;
    }

    public void record(long durationNanos) {
        int i = idx.getAndIncrement();
        if (i < CAP) {
            nanos[i] = durationNanos;
        }
    }

    public int count() {
        return idx.get();
    }

    /** name count=N min/p50/p90/p95/p99/max/mean 을 ms 로 적는다. 표본이 없으면 count=0만 적는다. */
    public String report() {
        int n = Math.min(idx.get(), CAP);
        if (n == 0) {
            return String.format("%-24s count=%-7d (표본 없음)", name, idx.get());
        }
        long[] s = Arrays.copyOf(nanos, n);
        Arrays.sort(s);
        long sum = 0;
        for (long v : s) {
            sum += v;
        }
        return String.format(
                "%-24s count=%-7d min=%-9s p50=%-9s p90=%-9s p95=%-9s p99=%-9s max=%-9s mean=%s",
                name, idx.get(),
                ms(s[0]), ms(pct(s, 50)), ms(pct(s, 90)), ms(pct(s, 95)), ms(pct(s, 99)),
                ms(s[n - 1]), ms(sum / n));
    }

    private static long pct(long[] sorted, int p) {
        int rank = (int) Math.ceil(sorted.length * p / 100.0) - 1;
        return sorted[Math.max(0, Math.min(sorted.length - 1, rank))];
    }

    private static String ms(long n) {
        return String.format("%.2fms", n / 1_000_000.0);
    }
}
