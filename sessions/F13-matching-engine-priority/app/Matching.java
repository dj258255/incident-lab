// F13 매칭엔진 재현: 같은 가격 매수 주문을 병렬로 매칭하면 시간우선이 깨진다.
//
// 규칙(한국거래소 매매체결원칙): 가격이 같으면 먼저 접수된 호가가 우선한다.
// 이 프로그램은 같은 종목, 같은 가격의 매수 주문 n건이 대기열에 쌓이고 반대편 물량이
// 차례로 채워 가는 상황을 축소한 것이다. 접수 시퀀스(AtomicLong)가 접수 순서의 진실이고,
// 체결 로그가 체결 순서의 진실이다. 두 순서가 어긋난 체결을 시간우선 위반으로 센다.
//
// [버그 1] 접수 4스레드 -> ConcurrentLinkedQueue -> 매칭 2스레드 병렬 체결
// [버그 2] 매칭만 1스레드로 줄임. 시퀀스 발급과 큐 삽입이 분리된 접수 쪽 레이스는 그대로
// [해소]   시퀀스 발급과 큐 삽입을 한 원자 구간으로 묶고(단일 시퀀서) 매칭도 1스레드

import java.util.Locale;
import java.util.Queue;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.LongAdder;

public class Matching {

    static final int ACCEPT_THREADS = 4;
    static final int PRICE = 50_000; // 같은 가격 하나. 가격우선이 개입할 여지를 없애고 시간우선만 본다
    static final int QTY = 1;

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
    }

    public static void main(String[] args) throws Exception {
        int n = Integer.getInteger("orders", 200_000);
        System.out.printf(Locale.US,
                "== F13 매칭엔진 재현: 같은 종목·같은 가격(%,d원) 매수 %,d건 (JDK %s, 가용 프로세서 %d개) ==%n",
                PRICE, n, System.getProperty("java.specification.version"),
                Runtime.getRuntime().availableProcessors());
        System.out.println("접수 시퀀스는 AtomicLong으로 부여한다. 이것이 접수 순서의 진실이다.");
        System.out.println("위반 판정: 같은 가격 레벨에서 자기보다 먼저 접수된 주문이 대기 중인데 먼저 체결되면 위반 1건.");
        System.out.println();

        // JIT 워밍업. 세 모드를 작은 규모로 한 번씩 돌리고 결과는 버린다.
        runBuggy(20_000, 2);
        runBuggy(20_000, 1);
        runSequencer(20_000);
        System.out.println("(워밍업: 세 모드를 각 20,000건으로 한 번씩 실행, 측정 제외)");
        System.out.println();

        Result a = runBuggy(n, 2);
        report("[버그 1] naive 병렬 매칭: 접수 4스레드 -> ConcurrentLinkedQueue -> 매칭 2스레드", a);
        Result b = runBuggy(n, 1);
        report("[버그 2] 매칭 1스레드: 접수 4스레드 -> ConcurrentLinkedQueue -> 매칭 1스레드 (발급과 삽입은 여전히 분리)", b);
        Result c = runSequencer(n);
        report("[해소] 단일 시퀀서: 시퀀스 발급+큐 삽입 원자화 -> ArrayBlockingQueue -> 매칭 1스레드", c);

        long expected = (long) n * PRICE * QTY;
        boolean ok = a.notional == expected && b.notional == expected && c.notional == expected;
        System.out.printf(Locale.US, "검산: 세 모드 체결대금 합계 %s (기대값 %,d원, 주문 유실 없음 확인)%n",
                ok ? "모두 일치" : "불일치!", expected);
        if (!ok) System.exit(1);
    }

    static void report(String title, Result r) {
        System.out.println(title);
        long ms = r.elapsedNanos / 1_000_000;
        long perSec = r.n * 1_000_000_000L / r.elapsedNanos;
        System.out.printf(Locale.US, "  체결 %,d건, 소요 %,dms (%,d건/초), 체결대금 합계 %,d원%n",
                r.n, ms, perSec, r.notional);
        if (r.violations == 0) {
            System.out.println("  시간우선 위반 0건");
        } else {
            System.out.printf(Locale.US, "  시간우선 위반 %,d건 (체결의 %.1f%%), 최대 역전 간격 %,d%n",
                    r.violations, r.violations * 100.0 / r.n, r.maxGap);
        }
        System.out.println();
    }

    // 버그 재현: 시퀀스 발급(1)과 큐 삽입(2)이 분리돼 있고, 꺼내기(3)와 체결 순번 확정(4)도
    // 분리돼 있다. 각 단계 사이에 다른 스레드가 끼어들 수 있어 접수 순서와 체결 순서가 어긋난다.
    static Result runBuggy(int n, int matchThreads) throws InterruptedException {
        AtomicLong seqGen = new AtomicLong();
        Queue<Order> level = new ConcurrentLinkedQueue<>(); // 가격 50,000원 레벨의 대기열
        long[] execLog = new long[n]; // 체결 로그: 체결 순서대로 접수 시퀀스를 적는다
        AtomicInteger execIdx = new AtomicInteger();
        LongAdder notional = new LongAdder();
        AtomicBoolean acceptDone = new AtomicBoolean(false);
        CountDownLatch go = new CountDownLatch(1);

        Thread[] acceptors = new Thread[ACCEPT_THREADS];
        for (int t = 0; t < ACCEPT_THREADS; t++) {
            final int count = share(n, t);
            acceptors[t] = new Thread(() -> {
                awaitQuietly(go);
                for (int i = 0; i < count; i++) {
                    Order o = new Order(PRICE, QTY);
                    o.seq = seqGen.incrementAndGet(); // (1) 접수 순서 확정
                    level.offer(o);                   // (2) 오더북 반영. (1)과 (2) 사이에 끼어든다
                }
            }, "accept-" + t);
        }
        Thread[] matchers = new Thread[matchThreads];
        for (int t = 0; t < matchThreads; t++) {
            matchers[t] = new Thread(() -> {
                awaitQuietly(go);
                while (true) {
                    Order o = level.poll();           // (3) 레벨 맨 앞 주문을 집는다
                    if (o == null) {
                        if (acceptDone.get() && level.peek() == null) break;
                        Thread.onSpinWait();
                        continue;
                    }
                    notional.add((long) o.price * o.qty);
                    int idx = execIdx.getAndIncrement(); // (4) 체결 순번 확정. (3)과 (4) 사이에도 끼어든다
                    execLog[idx] = o.seq;
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

    // 해소: 접수(주문 생성·검증)는 병렬 그대로 두되, 시퀀스 발급과 큐 삽입을 하나의
    // 원자 구간으로 묶는다. 이 직렬화 지점이 시퀀서다. 매칭은 단일 스레드가 큐 순서대로 비운다.
    // LMAX 디스럽터의 단일 라이터 아이디어를 표준 라이브러리 BlockingQueue 수준으로 축소했다.
    static Result runSequencer(int n) throws InterruptedException {
        AtomicLong seqGen = new AtomicLong();
        BlockingQueue<Order> level = new ArrayBlockingQueue<>(n); // 용량 = 전체 주문 수라 add는 즉시 성공
        Object sequencer = new Object();
        long[] execLog = new long[n];
        LongAdder notional = new LongAdder();
        CountDownLatch go = new CountDownLatch(1);

        Thread[] acceptors = new Thread[ACCEPT_THREADS];
        for (int t = 0; t < ACCEPT_THREADS; t++) {
            final int count = share(n, t);
            acceptors[t] = new Thread(() -> {
                awaitQuietly(go);
                for (int i = 0; i < count; i++) {
                    Order o = new Order(PRICE, QTY);  // 주문 생성까지는 병렬
                    synchronized (sequencer) {        // 발급과 삽입 사이에 아무도 끼어들 수 없다
                        o.seq = seqGen.incrementAndGet();
                        level.add(o);
                    }
                }
            }, "accept-" + t);
        }
        Thread matcher = new Thread(() -> {
            awaitQuietly(go);
            try {
                for (int i = 0; i < n; i++) {
                    Order o = level.take();           // 단일 스레드가 큐 순서 그대로 체결
                    notional.add((long) o.price * o.qty);
                    execLog[i] = o.seq;
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }, "match-sequenced");

        for (Thread th : acceptors) th.start();
        matcher.start();
        long t0 = System.nanoTime();
        go.countDown();
        for (Thread th : acceptors) th.join();
        matcher.join();
        long t1 = System.nanoTime();

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

    static int share(int n, int t) {
        int base = n / ACCEPT_THREADS, rem = n % ACCEPT_THREADS;
        return base + (t < rem ? 1 : 0);
    }

    static void awaitQuietly(CountDownLatch l) {
        try {
            l.await();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
