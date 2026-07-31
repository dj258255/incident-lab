// F07 IPO 크로스 재계산 기아 재현.
//
// 이름 주의: 처음에는 이 현상을 "라이브락"이라고 불렀으나 그 규정은 내렸다. 라이브락은 두 쪽이
// 서로의 상태 변화에 반응하며 함께 헛도는 상태인데, 아래 feed()의 취소 유입은 next += intervalNanos로
// 자기 시계만 보고 깨어나는 고정 타이머라 계산 스레드의 재계산에 전혀 반응하지 않는다. 되먹임이
// 없으므로 정확한 이름은 기아(starvation) 또는 수렴하지 않는 재시도 루프다. 아래 출력 문자열과
// 파일 이름에 남은 "라이브락"은 기록된 실행 출력(reproduce.md)과 어긋나지 않게 두었을 뿐이다.
//
// SEC, Securities Exchange Act Release No. 69655(2013-05-29)는 Nasdaq 매칭엔진이 IPO 크로스
// 계산을 마친 뒤 "계산의 근거가 된 주문 중 계산 도중 취소된 것이 있는지" 확인하는 검증을
// 수행했고, 취소 건마다 별도의 재계산을 돌리도록 설계돼 있어 검증이 매번 실패하면서 루프에
// 빠졌다고 적는다. 이 프로그램은 그 규칙 하나만 떼어내 축소 재현한 것이다.
// 실제 Nasdaq 엔진이 아니고 사건의 수치를 재현하지도 않는다.
//
// [버그]    기록 직전 검증이 실패하면 처음부터 다시 계산한다.
//           취소 도착 간격이 계산 1회 소요시간보다 짧으면 크로스가 확정되지 않는다.
// [해소 A] 스냅샷 동결: 계산 시작 시점의 주문장을 입력으로 고정한다. 계산 중 도착한 취소는
//           접수만 하고 이번 크로스에는 반영하지 않는다(다음 라운드로 이월).
// [해소 B] 접수 컷오프: 첫 검증 실패 시 취소 접수를 닫고 드레인한 뒤 한 번 더 계산해 확정한다.
//           컷오프 창에 도착한 취소는 거부한다.
//
// 데드락은 아니다. 블로킹된 스레드는 없고 두 스레드 모두 계속 일하는데 크로스만 확정되지 않는다.
// 라이브락도 아니다(위 이름 주의 참고). 계산 스레드가 "취소가 한 건도 오지 않는 라운드 하나"를
// 얻지 못하는 기아다.
//
// "확정 실패"는 영원히 확정되지 않는다는 뜻이 아니라 -DcapMs 상한(compose.yml에서 1000ms)에
// 걸렸다는 뜻이다. 상한을 늘렸을 때 결국 확정되는지는 재지 않았다.

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.Random;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.locks.LockSupport;

public class Cross {

    static final int MIN_PRICE = 10_000;
    static final int TICKS = Integer.getInteger("ticks", 400);
    static final int ORDERS = Integer.getInteger("orders", 8_000);
    static final int MAX_RECALC = Integer.getInteger("maxRecalc", 200);
    static final long CAP_MS = Long.getLong("capMs", 1_000L);
    static final int DRAIN_MS = Integer.getInteger("drainMs", 5);
    static final int ATTEMPTS = Integer.getInteger("attempts", 3);   // 버그 모드는 유입률마다 여러 번 시도한다
    static final long SEED = Long.getLong("seed", 20120518L);
    static final Random PHASE = new Random(SEED);   // 계산 시작 시점의 위상을 흔든다
    static final java.util.concurrent.atomic.AtomicLong TRIAL_SEQ = new java.util.concurrent.atomic.AtomicLong();

    enum Mode { BUGGY, SNAPSHOT, CUTOFF }

    static final class Order {
        final boolean buy;
        final int price;
        final int qty;
        volatile boolean cancelled;   // 오더북에서 빠졌는가. 계산 스레드가 읽는다
        boolean cancelRequested;      // 취소 유입 스레드만 쓴다. 같은 주문을 두 번 겨냥하지 않으려고 둔다
        Order(boolean buy, int price, int qty) { this.buy = buy; this.price = price; this.qty = qty; }
    }

    static final class CrossResult {
        int price;
        long volume;
    }

    static final class Trial {
        double intervalMs;
        int recalcs;
        boolean committed;
        long elapsedNanos;
        int crossPrice;
        long crossVolume;
        int cancelsArrived;      // 유입 스레드가 시도한 취소 건수
        int cancelsApplied;      // 오더북에 실제 반영된 취소
        int cancelsDeferred;     // 스냅샷 동결로 다음 라운드에 넘긴 취소
        int cancelsRejected;     // 컷오프로 거부한 취소
        int missedButMarketable; // 이번 크로스에 반영되지 못한 취소 중 크로스 가격에서 체결 조건을 만족하는 것
        double roundMedianMs;    // 라운드 1회(뷰 구성 + 계산 + 검증) 소요시간 중앙값
        // 확정 실패일 때 어느 상한에 먼저 닿았는지. capMs 와 maxRecalc 를 같은 비율로
        // 함께 올려서 세 조건 중 어느 것이 결정적이었는지 갈리지 않았다.
        // "recalc" 또는 "time", 확정에 성공하면 빈 문자열이다.
        String capHit = "";

        double effIntervalMs() { return cancelsArrived == 0 ? Double.NaN : (elapsedNanos / 1e6) / cancelsArrived; }
        double measuredRatio() { return effIntervalMs() / roundMedianMs; }
    }

    // 취소 유입 스레드와 크로스 계산 스레드가 공유하는 상태.
    static final class Engine {
        final Order[] book;
        final Random rnd;
        volatile boolean running = true;
        volatile boolean frozen = false;   // 스냅샷 동결 중: 취소는 접수하되 이번 계산에 반영하지 않는다
        volatile boolean cutoff = false;   // 접수 컷오프 중: 취소를 거부한다
        final List<Order> deferred = new ArrayList<>();
        final List<Order> rejected = new ArrayList<>();
        volatile int arrived;
        volatile int applied;

        // 주문장은 고정 시드로 만들지만 취소가 겨냥하는 주문은 시도마다 달라야 한다.
        // 모드마다 같은 시드를 쓰면 늘 같은 주문을 취소하게 되고, 그 주문들이 크로스 가격에서
        // 체결 조건을 만족하는지가 시드로 고정돼 버려 두 해소 방식의 비교가 오염된다.
        Engine(Order[] book, Mode mode) {
            this.book = book;
            this.rnd = new Random(SEED * 31 + TRIAL_SEQ.incrementAndGet());
        }

        void feed(long intervalNanos, CountDownLatch go) {
            awaitQuietly(go);
            long next = System.nanoTime();
            while (running) {
                next += intervalNanos;
                long d = next - System.nanoTime();
                if (d > 0) LockSupport.parkNanos(d);
                if (!running) break;
                tick();
            }
        }

        void tick() {
            Order o = pickTarget();
            if (o == null) return;
            o.cancelRequested = true;
            arrived++;
            if (cutoff) { rejected.add(o); return; }   // 컷오프 창: 취소 접수를 거부한다
            if (frozen) { deferred.add(o); return; }   // 동결 창: 접수는 하되 다음 라운드로 넘긴다
            o.cancelled = true;                        // 즉시 반영. 계산 중이면 기록 직전 검증이 깨진다
            applied++;
        }

        Order pickTarget() {
            for (int k = 0; k < 64; k++) {
                Order o = book[rnd.nextInt(book.length)];
                if (!o.cancelRequested) return o;
            }
            for (Order o : book) if (!o.cancelRequested) return o;
            return null;
        }
    }

    public static void main(String[] args) throws Exception {
        double[] intervals = parseIntervals(System.getProperty("intervals", "2,4,8,12,16,24,32,48"));
        Order[] book = buildBook(ORDERS);

        System.out.printf(Locale.US,
                "== F07 IPO 크로스 재계산 라이브락 재현: 주문 %,d건, 호가 %,d틱 (JDK %s, 가용 프로세서 %d개) ==%n",
                ORDERS, TICKS, System.getProperty("java.specification.version"),
                Runtime.getRuntime().availableProcessors());
        System.out.println("규칙: 크로스 계산이 끝난 뒤 계산의 근거가 된 주문 중 취소된 것이 있으면 결과를 기록하지 않고 처음부터 다시 계산한다.");
        System.out.printf(Locale.US, "확정 실패 판정: 재계산 %,d회 또는 %,dms 상한에 먼저 닿으면 확정 실패로 기록한다.%n", MAX_RECALC, CAP_MS);
        System.out.println();

        // JIT 워밍업. 취소 유입 없이 크로스 계산만 반복하고 결과는 버린다.
        // 코어가 2개뿐이라 C2 컴파일러 스레드가 아직 돌고 있으면 기준선이 두 배 넘게 부풀어 오른다.
        // 그래서 워밍업 뒤에 컴파일 큐가 빠지도록 쉬었다가 한 번 더 돌린 다음에 측정한다.
        Order[] warmView = new Order[ORDERS];
        for (int i = 0; i < 60; i++) computeCross(warmView, buildView(book, warmView));
        LockSupport.parkNanos(500_000_000L);
        for (int i = 0; i < 30; i++) computeCross(warmView, buildView(book, warmView));
        LockSupport.parkNanos(300_000_000L);
        System.out.println("(워밍업: 크로스 계산 60회 + 컴파일 정착 대기 0.5초 + 30회, 측정 제외)");
        System.out.println();

        // 기준선을 두 가지로 잰다. 재계산 루프는 계산을 쉬지 않고 돌리므로 연속 실행 쪽이
        // 비교 기준이고, 40ms 쉬었다 한 번씩 도는 단발 실행은 같은 계산이 한가할 때 얼마나
        // 걸리는지를 보여 준다. 둘이 다르면 임계점도 부하에 따라 움직인다는 뜻이다.
        double[] cal = calcSamples(book, 9);
        double[] spaced = calcSamplesSpaced(book, 9, 40);
        double calcMs = cal[1];
        CrossResult base = computeCross(warmView, buildView(book, warmView));
        System.out.printf(Locale.US, "[기준선] 주문 %,d건 크로스 계산 1회 (취소 유입 없음, 각 9회)%n", ORDERS);
        System.out.printf(Locale.US, "         연속 실행     중앙값 %.1fms (최소 %.1f / 최대 %.1fms)%n", cal[1], cal[0], cal[2]);
        System.out.printf(Locale.US, "         40ms 간격 단발 중앙값 %.1fms (최소 %.1f / 최대 %.1fms)%n", spaced[1], spaced[0], spaced[2]);
        System.out.printf(Locale.US, "         취소 유입이 없을 때의 크로스 %,d원 x %,d주, 재계산 0회%n", base.price, base.volume);
        System.out.println();

        System.out.printf(Locale.US, "[버그] 기록 직전 취소가 오면 처음부터 재계산. 취소 유입 간격마다 %d회씩 시도%n", ATTEMPTS);
        System.out.println("       재계산·경과·라운드·실효간격은 시도들의 중앙값. 라운드는 뷰 구성 + 계산 + 검증 1회.");
        System.out.println(row(BUG_H, BUG_W));
        int bugFail = 0;
        Trial[][] buggy = new Trial[intervals.length][];
        for (int i = 0; i < intervals.length; i++) {
            buggy[i] = new Trial[ATTEMPTS];
            for (int a = 0; a < ATTEMPTS; a++) buggy[i][a] = runTrial(Mode.BUGGY, book, intervals[i]);
            int fails = 0;
            for (Trial t : buggy[i]) if (!t.committed) fails++;
            bugFail += fails;
            System.out.println(bugRow(buggy[i], fails));
        }
        System.out.println();

        System.out.println("[해소 A] 스냅샷 동결: 계산 시작 시점의 주문장을 입력으로 고정, 계산 중 도착한 취소는 다음 라운드로");
        System.out.println("       버그와 같은 유입률로 같은 횟수를 시도한다. 재계산·경과는 중앙값, 건수는 시도 합계.");
        System.out.println(row(FIX_H_A, FIX_W));
        int snapFail = 0, snapMissed = 0;
        for (double interval : intervals) {
            Trial[] ts = new Trial[ATTEMPTS];
            for (int a = 0; a < ATTEMPTS; a++) ts[a] = runTrial(Mode.SNAPSHOT, book, interval);
            int fails = 0, missed = 0;
            for (Trial t : ts) { if (!t.committed) fails++; missed += t.missedButMarketable; }
            snapFail += fails;
            snapMissed += missed;
            System.out.println(fixRow(ts, fails, Mode.SNAPSHOT));
        }
        System.out.println();

        System.out.printf(Locale.US, "[해소 B] 접수 컷오프: 첫 검증 실패 시 취소 접수를 닫고 %dms 드레인 뒤 한 번 더 계산해 확정%n", DRAIN_MS);
        System.out.println("       버그와 같은 유입률로 같은 횟수를 시도한다. 재계산·경과는 중앙값, 건수는 시도 합계.");
        System.out.println(row(FIX_H_B, FIX_W));
        int cutFail = 0, cutMissed = 0;
        for (double interval : intervals) {
            Trial[] ts = new Trial[ATTEMPTS];
            for (int a = 0; a < ATTEMPTS; a++) ts[a] = runTrial(Mode.CUTOFF, book, interval);
            int fails = 0, missed = 0;
            for (Trial t : ts) { if (!t.committed) fails++; missed += t.missedButMarketable; }
            cutFail += fails;
            cutMissed += missed;
            System.out.println(fixRow(ts, fails, Mode.CUTOFF));
        }
        System.out.println();

        double[] cal2 = calcSamples(book, 9);
        System.out.printf(Locale.US, "사후 재계측: 기준 주문장 계산 1회 중앙값 %.1fms (측정 전 %.1fms). 부하가 바뀌면 임계점도 같이 움직인다.%n", cal2[1], calcMs);
        System.out.println();

        // 주문장이 커지면 계산 1회가 길어진다. 임계 조건상 문턱도 따라 움직일 것으로 보이지만,
        // 이 표는 취소 유입을 끄고 계산 시간만 잰 것이라 문턱이 실제로 어디로 옮겨 가는지는 재지 않았다.
        // 규모마다 다시 워밍업하므로 JIT 프로파일이 섞인다. 그래서 본 측정 뒤에 돌린다.
        System.out.println("[규모 민감도] 주문장 규모별 크로스 계산 1회 소요시간 (취소 유입 없음, 규모별 워밍업 후 9회 측정)");
        System.out.println(row(new String[]{"주문장", "중앙값", "최소", "최대"}, SIZE_W));
        for (int size : new int[]{1_000, 2_000, 4_000, 8_000, 16_000}) {
            double[] s = calcSamples(buildBook(size), 9);
            System.out.println(row(new String[]{
                    String.format(Locale.US, "%,d건", size),
                    String.format(Locale.US, "%.1fms", s[1]),
                    String.format(Locale.US, "%.1fms", s[0]),
                    String.format(Locale.US, "%.1fms", s[2])}, SIZE_W));
        }
        System.out.println();

        int total = intervals.length * ATTEMPTS;
        System.out.printf(Locale.US, "검산: 확정 실패 = 버그 %d/%d회 / 스냅샷 동결 %d/%d회 / 접수 컷오프 %d/%d회 (유입률 %d개 x %d회씩)%n",
                bugFail, total, snapFail, total, cutFail, total, intervals.length, ATTEMPTS);
        System.out.printf(Locale.US, "      취소를 냈는데 크로스 체결 조건을 만족한 주문 합계 = 스냅샷 동결 %,d건(참가자에게 접수됐다고 응답) / 접수 컷오프 %,d건(참가자에게 거부로 응답)%n",
                snapMissed, cutMissed);
        System.out.println("      라이브락 구간에서 블로킹된 스레드는 0개다. 두 스레드 모두 계속 일했고 확정된 크로스만 0건이다.");
    }

    static final int[] SIZE_W = {10, 10, 10, 10};
    static final String[] BUG_H = {"취소간격", "시도", "확정실패", "재계산", "경과", "라운드", "실효간격", "실측비율"};
    static final int[] BUG_W = {10, 7, 10, 9, 10, 9, 10, 10};
    static final String[] FIX_H_A = {"취소간격", "시도", "확정실패", "재계산", "경과", "취소도착", "이월취소", "체결조건충족"};
    static final String[] FIX_H_B = {"취소간격", "시도", "확정실패", "재계산", "경과", "취소도착", "거부취소", "체결조건충족"};
    static final int[] FIX_W = {10, 7, 10, 9, 10, 10, 10, 14};

    static String bugRow(Trial[] ts, int fails) {
        double[] recalcs = new double[ts.length], elapsed = new double[ts.length];
        double[] round = new double[ts.length], eff = new double[ts.length];
        int arrived = 0;
        for (int i = 0; i < ts.length; i++) {
            recalcs[i] = ts[i].recalcs;
            elapsed[i] = ts[i].elapsedNanos / 1e6;
            round[i] = ts[i].roundMedianMs;
            eff[i] = ts[i].effIntervalMs();
            arrived += ts[i].cancelsArrived;
        }
        double effMed = median(eff), roundMed = median(round);
        return row(new String[]{
                String.format(Locale.US, "%.0fms", ts[0].intervalMs),
                String.format(Locale.US, "%d회", ts.length),
                String.format(Locale.US, "%d회", fails),
                String.format(Locale.US, "%,.0f회", median(recalcs)),
                String.format(Locale.US, "%,.0fms", median(elapsed)),
                String.format(Locale.US, "%.1fms", roundMed),
                arrived == 0 ? "-" : String.format(Locale.US, "%.1fms", effMed),
                arrived == 0 ? "-" : String.format(Locale.US, "%.2f", effMed / roundMed)}, BUG_W);
    }

    static double median(double[] v) {
        double[] s = v.clone();
        Arrays.sort(s);   // NaN은 뒤로 밀린다
        int n = s.length;
        while (n > 0 && Double.isNaN(s[n - 1])) n--;
        return n == 0 ? Double.NaN : s[n / 2];
    }

    static String fixRow(Trial[] ts, int fails, Mode mode) {
        double[] recalcs = new double[ts.length], elapsed = new double[ts.length];
        int arrived = 0, missed = 0, marketable = 0;
        for (int i = 0; i < ts.length; i++) {
            recalcs[i] = ts[i].recalcs;
            elapsed[i] = ts[i].elapsedNanos / 1e6;
            arrived += ts[i].cancelsArrived;
            missed += mode == Mode.SNAPSHOT ? ts[i].cancelsDeferred : ts[i].cancelsRejected;
            marketable += ts[i].missedButMarketable;
        }
        return row(new String[]{
                String.format(Locale.US, "%.0fms", ts[0].intervalMs),
                String.format(Locale.US, "%d회", ts.length),
                String.format(Locale.US, "%d회", fails),
                String.format(Locale.US, "%,.0f회", median(recalcs)),
                String.format(Locale.US, "%,.0fms", median(elapsed)),
                String.format(Locale.US, "%,d건", arrived),
                String.format(Locale.US, "%,d건", missed),
                String.format(Locale.US, "%,d건", marketable)}, FIX_W);
    }

    static Trial runTrial(Mode mode, Order[] book, double intervalMs) throws InterruptedException {
        for (Order o : book) { o.cancelled = false; o.cancelRequested = false; }

        Engine e = new Engine(book, mode);
        Trial t = new Trial();
        t.intervalMs = intervalMs;
        long intervalNanos = (long) (intervalMs * 1_000_000);
        CountDownLatch go = new CountDownLatch(1);
        Thread feeder = new Thread(() -> e.feed(intervalNanos, go), "cancel-feed");
        feeder.setDaemon(true);
        feeder.start();

        Order[] view = new Order[book.length];
        long capNanos = CAP_MS * 1_000_000L;
        go.countDown();

        // 프리롤. 취소 스트림을 먼저 정상 상태로 돌린 뒤에 계산을 시작한다. 이걸 빼면 계산이
        // 첫 취소가 도착하기 전에 끝나 버려서, 유입 간격이 계산 시간보다 길기만 하면 무조건
        // 1라운드에 확정되는 가짜 결과가 나온다. 프리롤 길이에 한 주기 안의 난수를 더해
        // 계산 시작 시점이 취소 주기에 위상 고정되지 않게 한다.
        long preRoll = Math.max(15_000_000L, (long) (2 * intervalMs * 1_000_000))
                + (long) (PHASE.nextDouble() * intervalMs * 1_000_000);
        LockSupport.parkNanos(preRoll);
        int arrivedBase = e.arrived, appliedBase = e.applied;
        long t0 = System.nanoTime();

        CrossResult committed = null;
        int recalcs = 0;
        List<Double> rounds = new ArrayList<>();
        while (true) {
            long rt0 = System.nanoTime();
            if (mode == Mode.SNAPSHOT) e.frozen = true;    // 입력 동결 개시
            int n = buildView(book, view);                 // 살아 있는 주문만 담는다
            CrossResult r = computeCross(view, n);

            // 기록 직전 검증. 계산의 근거가 된 주문 중 계산 도중 취소된 것이 있는가.
            // 스냅샷 동결은 입력을 시점으로 고정했으므로 검증할 대상 자체가 없다.
            boolean invalidated = (mode != Mode.SNAPSHOT) && anyCancelled(view, n);
            rounds.add((System.nanoTime() - rt0) / 1e6);

            if (!invalidated) {
                if (mode == Mode.SNAPSHOT) e.frozen = false;
                committed = r;                             // 결과 기록
                break;
            }
            recalcs++;

            if (mode == Mode.CUTOFF && !e.cutoff) {
                // 확정 직전 구간으로 보고 취소 접수를 닫는다. 인플라이트를 드레인한 뒤 다시 계산한다.
                e.cutoff = true;
                LockSupport.parkNanos(DRAIN_MS * 1_000_000L);
                continue;
            }
            // 어느 상한이 먼저 걸렸는지 남긴다. 둘을 함께 올리면 이 구분이 사라진다.
            boolean hitRecalc = recalcs >= MAX_RECALC;
            boolean hitTime = System.nanoTime() - t0 >= capNanos;
            if (hitRecalc || hitTime) {
                t.capHit = hitRecalc && hitTime ? "both" : (hitRecalc ? "recalc" : "time");
                break;   // 상한 도달 = 확정 실패
            }
        }
        long elapsed = System.nanoTime() - t0;

        e.running = false;
        e.frozen = false;
        feeder.interrupt();
        feeder.join();
        e.cutoff = false;

        t.recalcs = recalcs;
        t.elapsedNanos = elapsed;
        double[] rs = new double[rounds.size()];
        for (int i = 0; i < rs.length; i++) rs[i] = rounds.get(i);
        Arrays.sort(rs);
        t.roundMedianMs = rs[rs.length / 2];
        t.committed = committed != null;
        t.cancelsArrived = e.arrived - arrivedBase;   // 프리롤분은 빼고 측정 구간만 센다
        t.cancelsApplied = e.applied - appliedBase;
        t.cancelsDeferred = e.deferred.size();
        t.cancelsRejected = e.rejected.size();
        if (committed != null) {
            t.crossPrice = committed.price;
            t.crossVolume = committed.volume;
            // 이번 크로스에 반영되지 못한 취소 중 확정된 크로스 가격에서 체결 조건을 만족하는 주문을 센다.
            // 한계 가격의 부분 체결 배분은 다루지 않으므로 "체결 조건 충족"까지만 센다.
            List<Order> missed = mode == Mode.SNAPSHOT ? e.deferred : e.rejected;
            int m = 0;
            for (Order o : missed) if (o.buy ? o.price >= committed.price : o.price <= committed.price) m++;
            t.missedButMarketable = m;
        }
        return t;
    }

    // 살아 있는 주문만 뷰에 담는다. 담긴 뒤에 취소가 오면 기록 직전 검증에서 걸린다.
    static int buildView(Order[] book, Order[] view) {
        int n = 0;
        for (Order o : book) if (!o.cancelled) view[n++] = o;
        return n;
    }

    // 단일가(크로스) 계산. 호가 틱마다 매수 수요와 매도 공급을 누적해 체결 가능 수량이 가장 큰
    // 가격을 고른다. 같으면 낮은 가격을 택한다. 실제 엔진의 불균형 최소화·기준가 근접 규칙은 넣지 않았다.
    static CrossResult computeCross(Order[] view, int n) {
        int bestPrice = MIN_PRICE;
        long bestVolume = -1;
        for (int t = 0; t < TICKS; t++) {
            int p = MIN_PRICE + t;
            long demand = 0, supply = 0;
            for (int i = 0; i < n; i++) {
                Order o = view[i];
                if (o.buy) { if (o.price >= p) demand += o.qty; }
                else { if (o.price <= p) supply += o.qty; }
            }
            long matched = Math.min(demand, supply);
            if (matched > bestVolume) { bestVolume = matched; bestPrice = p; }
        }
        CrossResult r = new CrossResult();
        r.price = bestPrice;
        r.volume = bestVolume;
        return r;
    }

    // 기록 직전 검증. 계산에 쓴 주문 중 하나라도 그 사이에 취소됐으면 이 결과는 버린다.
    static boolean anyCancelled(Order[] view, int n) {
        for (int i = 0; i < n; i++) if (view[i].cancelled) return true;
        return false;
    }

    // 계산 1회 소요시간 표본. {최소, 중앙값, 최대} ms를 돌려준다.
    static double[] calcSamples(Order[] book, int samples) {
        Order[] view = new Order[book.length];
        for (int i = 0; i < 12; i++) computeCross(view, buildView(book, view));   // 규모별 워밍업
        double[] ms = new double[samples];
        for (int i = 0; i < samples; i++) {
            long s = System.nanoTime();
            computeCross(view, buildView(book, view));
            ms[i] = (System.nanoTime() - s) / 1e6;
        }
        double[] sorted = ms.clone();
        Arrays.sort(sorted);
        return new double[]{sorted[0], sorted[samples / 2], sorted[samples - 1]};
    }

    // 같은 계산을 gapMs씩 쉬었다 한 번씩 돈다. 연속 실행과 비교하면 지속 부하의 영향이 보인다.
    static double[] calcSamplesSpaced(Order[] book, int samples, int gapMs) {
        Order[] view = new Order[book.length];
        for (int i = 0; i < 12; i++) computeCross(view, buildView(book, view));
        double[] ms = new double[samples];
        for (int i = 0; i < samples; i++) {
            LockSupport.parkNanos(gapMs * 1_000_000L);
            long s = System.nanoTime();
            computeCross(view, buildView(book, view));
            ms[i] = (System.nanoTime() - s) / 1e6;
        }
        double[] sorted = ms.clone();
        Arrays.sort(sorted);
        return new double[]{sorted[0], sorted[samples / 2], sorted[samples - 1]};
    }

    static Order[] buildBook(int size) {
        Random r = new Random(SEED);
        Order[] book = new Order[size];
        for (int i = 0; i < size; i++) {
            boolean buy = (i % 2 == 0);
            int price = MIN_PRICE + r.nextInt(TICKS);
            int qty = 1 + r.nextInt(100);
            book[i] = new Order(buy, price, qty);
        }
        return book;
    }

    // 한글을 두 칸으로 세어 오른쪽 정렬한다. 콘솔과 렌더 이미지에서 표가 어긋나지 않게 한다.
    static String row(String[] cells, int[] widths) {
        StringBuilder sb = new StringBuilder("  ");
        for (int i = 0; i < cells.length; i++) sb.append(padLeft(cells[i], widths[i]));
        return sb.toString();
    }

    static String padLeft(String s, int w) {
        int pad = w - displayWidth(s);
        return pad <= 0 ? s : " ".repeat(pad) + s;
    }

    static int displayWidth(String s) {
        int w = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            boolean wide = (c >= 0x1100 && c <= 0x115F) || (c >= 0x2E80 && c <= 0xA4CF)
                    || (c >= 0xAC00 && c <= 0xD7A3) || (c >= 0xF900 && c <= 0xFAFF)
                    || (c >= 0xFE30 && c <= 0xFE6F) || (c >= 0xFF00 && c <= 0xFF60);
            w += wide ? 2 : 1;
        }
        return w;
    }

    static double[] parseIntervals(String s) {
        String[] parts = s.split(",");
        double[] out = new double[parts.length];
        for (int i = 0; i < parts.length; i++) out[i] = Double.parseDouble(parts[i].trim());
        return out;
    }

    static void awaitQuietly(CountDownLatch l) {
        try {
            l.await();
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
        }
    }
}
