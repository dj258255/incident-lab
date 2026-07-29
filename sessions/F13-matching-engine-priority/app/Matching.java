// F13 매칭엔진 재현: 같은 가격 매수 주문을 병렬로 매칭하면 시간우선이 깨진다.
//
// 규칙(한국거래소 매매체결원칙): 가격이 같으면 먼저 접수된 호가가 우선한다.
// 이 프로그램은 같은 종목, 같은 가격의 매수 주문 n건이 대기열에 쌓이고 반대편 물량이
// 차례로 채워 가는 상황을 축소한 것이다. 접수 시퀀스(AtomicLong)가 접수 순서의 진실이고,
// 체결 로그가 체결 순서의 진실이다. 두 순서가 어긋난 체결을 시간우선 위반으로 센다.
//
// 초판은 해소판이 큐 구현·원자 구간·소비 방식 셋을 한꺼번에 바꾸는 바람에 처리량 차이를
// 어느 변수에도 귀속할 수 없었다. 이번 판은 변수를 하나씩만 바꾼 조건을 나란히 돌린다.
//
//   C1 기준        ConcurrentLinkedQueue / 스핀 poll   / 원자 구간 없음
//   C2 원자만      ConcurrentLinkedQueue / 스핀 poll   / synchronized      <- C1 대비 원자 구간만
//   C3 큐만        ArrayBlockingQueue    / 스핀 poll   / 원자 구간 없음     <- C1 대비 큐만
//   C4 소비만      ArrayBlockingQueue    / 블로킹 take / 원자 구간 없음     <- C3 대비 소비 방식만
//   C5 큐+원자     ArrayBlockingQueue    / 스핀 poll   / synchronized
//   C6 셋다(해소)  ArrayBlockingQueue    / 블로킹 take / synchronized
//   P1 매칭2(총5)  ConcurrentLinkedQueue / 스핀 poll   / 원자 구간 없음 · 접수 3 + 매칭 2
//   P2 매칭2(총6)  ConcurrentLinkedQueue / 스핀 poll   / 원자 구간 없음 · 접수 4 + 매칭 2
//
// take()는 BlockingQueue에만 있으므로 소비 방식 변수는 ArrayBlockingQueue 위에서만 갈린다.
// 그래서 소비 방식의 몫은 C1이 아니라 C3을 기준으로 잰다.
// C1~C6은 실행 가능 스레드가 5개(접수 4 + 매칭 1)로 같다. P1도 5개(접수 3 + 매칭 2)다.
// P2만 6개라 처리량 비교에서 빼고 참고값으로 둔다.
//
// 측정 한계 하나를 코드에 적어 둔다. 여덟 조건을 한 JVM 안에서 섞어 돌리므로 level.offer와
// level.poll 호출 지점이 두 큐 구현을 모두 보는 다형 호출이 된다. 절대값은 한 구현만 돌린
// 빌드보다 낮게 나올 수 있다. 다만 그 불이익은 모든 조건에 똑같이 걸리므로 조건 간 비교에는
// 영향이 없다. 대신 조건을 회차마다 섞어 돌려 배경 부하가 특정 조건에만 몰리지 않게 했다.

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.Queue;
import java.util.Random;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.LongAdder;

public class Matching {

    static final int PRICE = 50_000; // 같은 가격 하나. 가격우선이 개입할 여지를 없애고 시간우선만 본다
    static final int QTY = 1;
    static final long SHUFFLE_SEED = 20260729L; // 조건 실행 순서를 회차마다 섞는 시드(고정)

    enum QueueKind {
        CLQ("ConcurrentLinkedQueue"), ABQ("ArrayBlockingQueue");
        final String text;
        QueueKind(String t) { this.text = t; }
    }

    enum Consume {
        SPIN("스핀 poll"), TAKE("블로킹 take");
        final String text;
        Consume(String t) { this.text = t; }
    }

    static final class Order {
        long seq;        // 접수 시퀀스: 접수 순서의 진실
        final int price;
        final int qty;
        Order(int price, int qty) { this.price = price; this.qty = qty; }
    }

    static final class Result {
        int n;
        long violations;   // 시간우선 위반 체결 건수
        long maxGap;       // 위반이 가장 심했던 체결의 시퀀스 간격
        long elapsedNanos;
        long notional;     // 체결대금 합계(검산용)
        double millis() { return elapsedNanos / 1_000_000.0; }
        double perSec() { return n * 1_000_000_000.0 / elapsedNanos; }
        double violPerFill() { return violations / (double) n; }
        // 최대 역전 간격을 시간으로 환산한다. 간격(건)을 전체 건수로 나눠 그 실행의 소요 시간에 곱한다.
        double gapMillis() { return maxGap / (double) n * millis(); }
    }

    static final class Cond {
        final String id, name;
        final QueueKind queue;
        final boolean atomic;
        final Consume consume;
        final int acceptThreads, matchThreads;
        final List<Result> runs = new ArrayList<>();

        Cond(String id, String name, QueueKind q, boolean atomic, Consume c, int accept, int match) {
            this.id = id; this.name = name; this.queue = q; this.atomic = atomic;
            this.consume = c; this.acceptThreads = accept; this.matchThreads = match;
        }

        String tag() { return id + " " + name; }
        int runnable() { return acceptThreads + matchThreads; }
        String atomicText() { return atomic ? "synchronized" : "원자 구간 없음"; }
        double[] ms() { return runs.stream().mapToDouble(Result::millis).toArray(); }
        double[] viol() { return runs.stream().mapToDouble(r -> r.violations).toArray(); }
        double[] gapMs() { return runs.stream().mapToDouble(Result::gapMillis).toArray(); }
        double[] gap() { return runs.stream().mapToDouble(r -> r.maxGap).toArray(); }
        double medMillis() { return pct(ms(), 0.5); }
        double medPerSec() { return pct(runs.stream().mapToDouble(Result::perSec).toArray(), 0.5); }
        long cleanRuns() { return runs.stream().filter(r -> r.violations == 0).count(); }
    }

    public static void main(String[] args) throws Exception {
        int n = Integer.getInteger("orders", 200_000);
        int reps = Integer.getInteger("reps", 51);

        List<Cond> conds = List.of(
                new Cond("C1", "기준",       QueueKind.CLQ, false, Consume.SPIN, 4, 1),
                new Cond("C2", "원자만",     QueueKind.CLQ, true,  Consume.SPIN, 4, 1),
                new Cond("C3", "큐만",       QueueKind.ABQ, false, Consume.SPIN, 4, 1),
                new Cond("C4", "소비만",     QueueKind.ABQ, false, Consume.TAKE, 4, 1),
                new Cond("C5", "큐+원자",    QueueKind.ABQ, true,  Consume.SPIN, 4, 1),
                new Cond("C6", "셋다(해소)", QueueKind.ABQ, true,  Consume.TAKE, 4, 1),
                new Cond("P1", "매칭2(총5)", QueueKind.CLQ, false, Consume.SPIN, 3, 2),
                new Cond("P2", "매칭2(총6)", QueueKind.CLQ, false, Consume.SPIN, 4, 2));

        System.out.printf(Locale.US,
                "== F13 매칭엔진 변수 분리 재현: 같은 종목·같은 가격(%,d원) 매수 %,d건 ==%n", PRICE, n);
        System.out.printf(Locale.US, "JDK %s, 가용 프로세서 %d개, 최대 힙 %,dMiB, 조건 %d개 × %d회 측정%n",
                System.getProperty("java.specification.version"),
                Runtime.getRuntime().availableProcessors(),
                Runtime.getRuntime().maxMemory() / (1024 * 1024), conds.size(), reps);
        System.out.println("접수 시퀀스는 AtomicLong으로 부여한다. 이것이 접수 순서의 진실이다.");
        System.out.println("위반 판정: 같은 가격 레벨에서 자기보다 먼저 접수된 주문이 대기 중인데 먼저 체결되면 위반 1건.");
        System.out.println();

        System.out.println("조건 정의 (변수는 큐 구현 · 소비 방식 · 원자 구간 셋)");
        for (Cond c : conds) {
            System.out.printf(Locale.US, "  %s %s / %s / %s · 접수 %d + 매칭 %d = 실행 가능 %d스레드%n",
                    pad(c.tag(), 16), pad(c.queue.text, 21), pad(c.consume.text, 11),
                    pad(c.atomicText(), 15), c.acceptThreads, c.matchThreads, c.runnable());
        }
        System.out.println();

        // JIT 워밍업. 모든 조건을 작은 규모로 두 번씩 돌리고 결과는 버린다.
        for (int w = 0; w < 2; w++) for (Cond c : conds) run(c, 20_000);
        System.out.printf(Locale.US, "(워밍업: %d개 조건을 각 20,000건으로 2회씩 실행, 측정 제외)%n", conds.size());
        System.out.printf(Locale.US,
                "(측정: 회차마다 조건 실행 순서를 시드 %d로 섞고, 실행 사이에 System.gc()와 60ms 대기를 둔다)%n",
                SHUFFLE_SEED);
        System.out.println();

        long expected = (long) n * PRICE * QTY;
        boolean ok = true;
        for (int rep = 1; rep <= reps; rep++) {
            List<Cond> order = new ArrayList<>(conds);
            Collections.shuffle(order, new Random(SHUFFLE_SEED + rep));
            for (Cond c : order) {
                System.gc();
                Thread.sleep(60);
                Result r = run(c, n);
                c.runs.add(r);
                ok &= r.notional == expected;
            }
        }

        System.out.printf(Locale.US, "원시 측정값 (%d회, 회차 순)%n", reps);
        for (Cond c : conds) {
            printSeries(c.tag() + " 소요ms", c.ms(), 1);
            printSeries(c.tag() + " 위반건수", c.viol(), 0);
        }
        System.out.println();

        System.out.printf(Locale.US, "처리량 요약 (%d회의 중앙값·사분위·범위)%n", reps);
        System.out.println(row2("조건", "소요ms 중앙값", "사분위 25~75%", "범위 최소~최대", "처리량 중앙값"));
        for (Cond c : conds) {
            double[] ms = c.ms();
            System.out.println(row2(c.tag(),
                    String.format(Locale.US, "%.1f", pct(ms, 0.5)),
                    String.format(Locale.US, "%.1f~%.1f", pct(ms, 0.25), pct(ms, 0.75)),
                    String.format(Locale.US, "%.1f~%.1f", min(ms), max(ms)),
                    String.format(Locale.US, "%,.0f건/초", c.medPerSec())));
        }
        System.out.println();

        System.out.printf(Locale.US, "시간우선 위반 요약 (%d회)%n", reps);
        System.out.println(row3("조건", "위반 중앙값", "범위 최소~최대", "체결당 위반 중앙값",
                "위반 0건 회차", "최대 역전 간격 중앙값(환산)"));
        for (Cond c : conds) {
            double[] vi = c.viol();
            System.out.println(row3(c.tag(),
                    String.format(Locale.US, "%,.0f건", pct(vi, 0.5)),
                    String.format(Locale.US, "%,.0f~%,.0f", min(vi), max(vi)),
                    String.format(Locale.US, "%.3f (%.1f%%)", pct(vi, 0.5) / n, pct(vi, 0.5) / n * 100),
                    String.format(Locale.US, "%d/%d", c.cleanRuns(), reps),
                    String.format(Locale.US, "%,.0f건 (%.1fms)", pct(c.gap(), 0.5), pct(c.gapMs(), 0.5))));
        }
        System.out.println();

        Cond c1 = conds.get(0), c2 = conds.get(1), c3 = conds.get(2),
             c4 = conds.get(3), c5 = conds.get(4), c6 = conds.get(5);
        System.out.println("변수별 몫 (소요 시간 중앙값 기준, 배수가 1보다 크면 그 변수를 켠 쪽이 느림)");
        System.out.println(delta("원자 구간만 추가 (CLQ + 스핀 위에서)", c1, c2));
        System.out.println(delta("원자 구간만 추가 (ABQ + 스핀 위에서)", c3, c5));
        System.out.println(delta("원자 구간만 추가 (ABQ + take 위에서)", c4, c6));
        System.out.println(delta("큐 구현만 교체 (CLQ -> ABQ, 둘 다 스핀·무보호)", c1, c3));
        System.out.println(delta("소비 방식만 교체 (스핀 poll -> 블로킹 take, 둘 다 ABQ·무보호)", c3, c4));
        System.out.println(delta("셋 다 바꾼 해소판 전체 (초판이 한꺼번에 바꾼 것)", c1, c6));
        System.out.println();

        System.out.println("최대 역전 간격의 시간 환산 (간격 ÷ 전체 건수 × 그 실행의 소요 시간)");
        for (Cond c : conds) {
            if (pct(c.gap(), 0.5) == 0) continue;
            double[] g = c.gapMs();
            System.out.printf(Locale.US, "  %s 중앙값 %.1fms, 범위 %.1f~%.1fms%n",
                    pad(c.tag(), 16), pct(g, 0.5), min(g), max(g));
        }
        System.out.println();

        System.out.printf(Locale.US, "검산: 전 조건 전 회차 체결대금 합계 %s (기대값 %,d원, 주문 유실 없음 확인)%n",
                ok ? "모두 일치" : "불일치!", expected);
        if (!ok) System.exit(1);
    }

    // 조건 하나를 한 번 실행한다. 큐 구현·원자 구간·소비 방식·스레드 배분만 다르고
    // 나머지(주문 생성, 체결 로그 적재, 체결대금 합산, 측정 구간)는 전부 같다.
    static Result run(Cond c, int n) throws InterruptedException {
        AtomicLong seqGen = new AtomicLong();
        final Queue<Order> level;
        final BlockingQueue<Order> blocking;
        if (c.queue == QueueKind.ABQ) {
            ArrayBlockingQueue<Order> q = new ArrayBlockingQueue<>(n); // 용량 = 전체 주문 수라 offer는 즉시 성공
            level = q;
            blocking = q;
        } else {
            ConcurrentLinkedQueue<Order> q = new ConcurrentLinkedQueue<>();
            level = q;
            blocking = null;
        }
        Object sequencer = new Object();
        long[] execLog = new long[n];        // 체결 로그: 체결 순서대로 접수 시퀀스를 적는다
        AtomicInteger execIdx = new AtomicInteger();
        LongAdder notional = new LongAdder();
        AtomicBoolean acceptDone = new AtomicBoolean(false);
        CountDownLatch go = new CountDownLatch(1);

        Thread[] acceptors = new Thread[c.acceptThreads];
        for (int t = 0; t < c.acceptThreads; t++) {
            final int count = share(n, c.acceptThreads, t);
            acceptors[t] = new Thread(() -> {
                awaitQuietly(go);
                for (int i = 0; i < count; i++) {
                    Order o = new Order(PRICE, QTY);   // 주문 생성까지는 어느 조건에서나 병렬
                    if (c.atomic) {
                        synchronized (sequencer) {     // 발급과 삽입 사이에 아무도 끼어들 수 없다
                            o.seq = seqGen.incrementAndGet();
                            level.offer(o);
                        }
                    } else {
                        o.seq = seqGen.incrementAndGet(); // (1) 접수 순서 확정
                        level.offer(o);                   // (2) 오더북 반영. (1)과 (2) 사이에 끼어든다
                    }
                }
            }, "accept-" + t);
        }

        Thread[] matchers = new Thread[c.matchThreads];
        for (int t = 0; t < c.matchThreads; t++) {
            final int quota = share(n, c.matchThreads, t);
            matchers[t] = new Thread(() -> {
                awaitQuietly(go);
                if (c.consume == Consume.TAKE) {
                    try {
                        for (int i = 0; i < quota; i++) {
                            Order o = blocking.take();          // 큐가 빌 때까지 블로킹 대기
                            notional.add((long) o.price * o.qty);
                            execLog[execIdx.getAndIncrement()] = o.seq;
                        }
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                    }
                } else {
                    while (true) {
                        Order o = level.poll();                 // (3) 레벨 맨 앞 주문을 집는다
                        if (o == null) {
                            if (acceptDone.get() && level.peek() == null) break;
                            Thread.onSpinWait();                // 스핀 대기
                            continue;
                        }
                        notional.add((long) o.price * o.qty);
                        execLog[execIdx.getAndIncrement()] = o.seq; // (4) 체결 순번 확정
                    }
                }
            }, "match-" + t);
        }

        for (Thread th : acceptors) th.start();
        for (Thread th : matchers) th.start();
        long t0 = System.nanoTime();
        go.countDown();
        for (Thread th : acceptors) th.join();
        acceptDone.set(true);
        for (Thread th : matchers) th.join();
        long t1 = System.nanoTime();

        if (execIdx.get() != n) throw new IllegalStateException("체결 건수 불일치: " + execIdx.get());
        Result r = score(execLog, n);
        r.elapsedNanos = t1 - t0;
        r.notional = notional.sum();
        return r;
    }

    // 위반 집계. 체결 로그를 체결 순서대로 훑으며 next(아직 체결되지 않은 가장 오래된 접수
    // 시퀀스)를 유지한다. 지금 체결된 시퀀스가 next와 다르면 next보다 늦게 접수된 주문이
    // 대기 중인 선행 주문을 제치고 체결된 것이므로 위반 1건으로 센다. 주문이 같은 가격
    // 레벨 하나에만 쌓이므로 모든 비교가 같은 가격 안의 시간우선 비교다.
    static Result score(long[] execLog, int n) {
        boolean[] done = new boolean[n + 2];
        long next = 1, violations = 0, maxGap = 0;
        for (int i = 0; i < n; i++) {
            long s = execLog[i];
            if (s != next) {
                violations++;
                if (s - next > maxGap) maxGap = s - next;
            }
            done[(int) s] = true;
            while (next <= n && done[(int) next]) next++;
        }
        Result r = new Result();
        r.n = n;
        r.violations = violations;
        r.maxGap = maxGap;
        return r;
    }

    static int share(int n, int threads, int t) {
        int base = n / threads, rem = n % threads;
        return base + (t < rem ? 1 : 0);
    }

    // 백분위. 정렬 후 선형 보간한다. p=0.5면 중앙값.
    static double pct(double[] xs, double p) {
        double[] a = xs.clone();
        Arrays.sort(a);
        if (a.length == 0) return 0;
        double idx = p * (a.length - 1);
        int lo = (int) Math.floor(idx), hi = (int) Math.ceil(idx);
        return lo == hi ? a[lo] : a[lo] + (a[hi] - a[lo]) * (idx - lo);
    }

    static double min(double[] xs) { return Arrays.stream(xs).min().orElse(0); }

    static double max(double[] xs) { return Arrays.stream(xs).max().orElse(0); }

    // 원시 측정값을 회차 순서 그대로 한 줄에 이어 적는다. 줄이 길어지면 접어 쓴다.
    static void printSeries(String label, double[] xs, int decimals) {
        StringBuilder line = new StringBuilder("  " + pad(label, 24));
        String indent = " ".repeat(26);
        for (double x : xs) {
            String s = String.format(Locale.US, "%." + decimals + "f", x);
            if (line.length() + s.length() + 1 > 118) {
                System.out.println(line);
                line = new StringBuilder(indent);
            }
            line.append(s).append(' ');
        }
        System.out.println(line.toString().stripTrailing());
    }

    static final int[] COLS2 = {16, 15, 16, 17, 16};
    static final int[] COLS3 = {16, 14, 18, 20, 15, 28};

    static String row2(String... cells) { return rowOf(COLS2, cells); }

    static String row3(String... cells) { return rowOf(COLS3, cells); }

    static String rowOf(int[] widths, String[] cells) {
        StringBuilder sb = new StringBuilder("  ");
        for (int i = 0; i < cells.length; i++) sb.append(pad(cells[i], widths[i]));
        return sb.toString().stripTrailing();
    }

    // 변수 하나만 다른 두 조건을 짝지어 그 변수의 몫을 적는다. 라벨은 조건 정의에서 읽어 쓴다.
    static String delta(String what, Cond from, Cond to) {
        return String.format(Locale.US, "  %s%s -> %s   %.1fms -> %.1fms   %.2f배",
                pad(what, 64), from.id, to.id, from.medMillis(), to.medMillis(),
                to.medMillis() / from.medMillis());
    }

    // 한글은 고정폭 폰트에서 두 칸을 차지한다. 표를 렌더링했을 때 열이 어긋나지 않도록
    // 문자 수가 아니라 표시 폭으로 채운다.
    static String pad(String s, int width) {
        int w = 0;
        for (int i = 0; i < s.length(); i++) w += wide(s.charAt(i)) ? 2 : 1;
        StringBuilder sb = new StringBuilder(s);
        for (int i = w; i < width; i++) sb.append(' ');
        return sb.toString();
    }

    static boolean wide(char ch) {
        return (ch >= 0x1100 && ch <= 0x115F) || (ch >= 0x2E80 && ch <= 0xA4CF)
                || (ch >= 0xAC00 && ch <= 0xD7A3) || (ch >= 0xF900 && ch <= 0xFAFF)
                || (ch >= 0xFE30 && ch <= 0xFE6F) || (ch >= 0xFF00 && ch <= 0xFF60)
                || (ch >= 0xFFE0 && ch <= 0xFFE6);
    }

    static void awaitQuietly(CountDownLatch l) {
        try {
            l.await();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
