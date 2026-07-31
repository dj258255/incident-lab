// README 의 "못 한 것" 두 개를 잡는다.
//
//   1) 매매체결원칙 넷 중 둘만 다뤘습니다
//      거래소의 원칙에는 위탁매매우선과 수량우선이 함께 있는데 이 세션은 가격과 시간으로
//      좁혔다. 나머지 둘을 넣고, 병렬 매칭이 그 둘도 같은 방식으로 깨는지 본다.
//
//   2) 동시호가 예외를 재현하지 않았습니다
//      거래소 안내는 시가 등이 상·하한가로 결정되는 경우에만 위탁매매우선을 예외적으로
//      인정한다고 적는다. 그 조건을 만들어 배분이 어떻게 갈리는지 본다.
//
// 주의. 이 파일은 거래소 안내의 서술을 코드로 옮긴 것이지 실제 거래소 구현이 아니다.
// 호가 단위, 단일가매매의 정확한 배분 규칙, 시장가 처리 같은 것은 들어 있지 않다.
// 보이려는 것은 "원칙을 넷으로 늘리면 병렬 매칭이 무엇을 더 깨는가" 하나다.
//
// Matching.java 는 그대로 둔다. 발행된 수치가 거기서 나왔고, 이 파일은 옆에 붙는다.
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Random;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicLong;

public class Principles {

    /** 계좌 구분. 위탁은 고객 주문, 자기는 증권사 자기매매다. */
    enum Account { 위탁, 자기 }

    record Ord(long seq, int price, int qty, Account acct) {}

    static final int ORDERS = Integer.getInteger("orders", 20_000);
    static final int REPS = Integer.getInteger("reps", 11);
    static final int UPPER_LIMIT = 65_000;     // 상한가
    static final int BASE = 50_000;

    // 네 원칙을 순서대로 적용하는 비교자.
    //   1. 가격우선   매수는 높은 가격이 먼저
    //   2. 시간우선   같은 가격이면 먼저 접수된 것이 먼저
    //   3. 위탁매매우선 같은 가격·같은 시각이면 위탁이 자기보다 먼저
    //   4. 수량우선   그래도 같으면 수량이 많은 쪽이 먼저
    //
    // 3과 4가 실제로 갈리려면 앞의 둘이 같아야 한다. 같은 시각에 들어온 주문이
    // 그것이다. 그래서 아래 시나리오는 접수 시각을 묶음으로 만든다.
    static final Comparator<Ord> FULL = Comparator
            .comparingInt(Ord::price).reversed()
            .thenComparingLong(Ord::seq)
            .thenComparing(o -> o.acct() == Account.위탁 ? 0 : 1)
            .thenComparing(Comparator.comparingInt(Ord::qty).reversed());

    // 가격과 시간만 보는 비교자. 이 세션이 원래 다룬 범위다.
    static final Comparator<Ord> PRICE_TIME = Comparator
            .comparingInt(Ord::price).reversed()
            .thenComparingLong(Ord::seq);

    /** 같은 접수 시각(seq)을 여러 주문이 나눠 갖는 주문장. 3, 4번 원칙이 개입할 자리를 만든다. */
    static List<Ord> book(long seed) {
        Random r = new Random(seed);
        List<Ord> b = new ArrayList<>(ORDERS);
        // 접수 시각 묶음 하나에 네 건씩 넣는다. 네 건은 가격도 같다.
        // 그러면 우선순위를 가르는 것이 위탁 여부와 수량뿐이다.
        for (int i = 0; i < ORDERS / 4; i++) {
            long seq = i;
            int price = BASE + r.nextInt(3) * 100;
            b.add(new Ord(seq, price, 10 + r.nextInt(90), Account.자기));
            b.add(new Ord(seq, price, 10 + r.nextInt(90), Account.위탁));
            b.add(new Ord(seq, price, 100 + r.nextInt(400), Account.자기));
            b.add(new Ord(seq, price, 100 + r.nextInt(400), Account.위탁));
        }
        return b;
    }

    /** 체결 로그가 규칙 순서와 어긋난 건수를 센다. */
    static long violations(List<Ord> fills, Comparator<Ord> rule) {
        long v = 0;
        for (int i = 1; i < fills.size(); i++) {
            if (rule.compare(fills.get(i - 1), fills.get(i)) > 0) v++;
        }
        return v;
    }

    /** 단일 스레드 매칭. 규칙대로 정렬해 그대로 체결한다. */
    static List<Ord> serial(List<Ord> b, Comparator<Ord> rule) {
        List<Ord> s = new ArrayList<>(b);
        s.sort(rule);
        return s;
    }

    /**
     * 병렬 매칭. 접수 스레드가 큐에 넣고 매칭 스레드 여럿이 꺼내 체결한다.
     * 큐가 순서를 보장해도 꺼낸 뒤의 처리 순서는 스레드 스케줄링이 정한다.
     * Matching.java 가 시간우선에서 보인 것과 같은 구조다.
     */
    static List<Ord> parallel(List<Ord> b, int matchThreads) throws Exception {
        ConcurrentLinkedQueue<Ord> q = new ConcurrentLinkedQueue<>();
        List<Ord> sorted = new ArrayList<>(b);
        sorted.sort(FULL);                 // 규칙 순서대로 큐에 들어간다
        q.addAll(sorted);

        List<Ord> fills = java.util.Collections.synchronizedList(new ArrayList<>(b.size()));
        CountDownLatch done = new CountDownLatch(matchThreads);
        AtomicLong notional = new AtomicLong();
        for (int t = 0; t < matchThreads; t++) {
            Thread.ofPlatform().start(() -> {
                Ord o;
                while ((o = q.poll()) != null) {
                    // 체결 처리. 큐에서 꺼낸 순서와 여기 도달하는 순서가 다르다.
                    notional.addAndGet((long) o.price() * o.qty());
                    fills.add(o);
                }
                done.countDown();
            });
        }
        done.await();
        return fills;
    }

    static double median(double[] xs) {
        double[] c = xs.clone();
        java.util.Arrays.sort(c);
        return c[c.length / 2];
    }

    public static void main(String[] a) throws Exception {
        System.out.println("# 매매체결원칙 넷과 동시호가 예외");
        System.out.printf(Locale.US, "# 주문 %,d건, 반복 %d회. 접수 시각 묶음마다 네 건이 같은 가격으로 들어옵니다.%n",
                ORDERS, REPS);
        System.out.println("# 그래야 가격·시간이 같아져 위탁매매우선과 수량우선이 판정에 개입합니다.");
        System.out.println();

        // ── 1) 원칙 넷을 병렬 매칭이 어떻게 깨는가 ─────────────────────
        System.out.println("## 1) 병렬 매칭이 깨는 것은 시간우선만이 아닙니다");
        System.out.printf("   %-16s %14s %14s %14s%n",
                "매칭", "가격·시간 위반", "네 원칙 위반", "차이");
        List<Ord> b = book(20130101L);

        List<Ord> ser = serial(b, FULL);
        System.out.printf("   %-16s %,14d %,14d %,14d%n", "단일 스레드",
                violations(ser, PRICE_TIME), violations(ser, FULL),
                violations(ser, FULL) - violations(ser, PRICE_TIME));

        for (int threads : new int[]{2, 4, 8}) {
            double[] vPT = new double[REPS], vFull = new double[REPS];
            for (int i = 0; i < REPS; i++) {
                List<Ord> f = parallel(b, threads);
                vPT[i] = violations(f, PRICE_TIME);
                vFull[i] = violations(f, FULL);
            }
            System.out.printf("   %-16s %,14.0f %,14.0f %,14.0f%n",
                    "매칭 " + threads + "스레드", median(vPT), median(vFull),
                    median(vFull) - median(vPT));
        }
        System.out.println();
        System.out.println("   가격·시간만 보면 같은 시각의 네 건이 어떤 순서로 체결되든 위반이 아닙니다.");
        System.out.println("   네 원칙으로 보면 그 안의 순서도 규칙이 정합니다. 그래서 같은 실행에서");
        System.out.println("   위반 건수가 늘어납니다. **원칙을 좁게 잡으면 위반이 안 보일 뿐입니다.**");
        System.out.println();

        // ── 2) 어느 원칙이 깨졌는가 ────────────────────────────────────
        System.out.println("## 2) 깨진 것이 어느 원칙인가");
        List<Ord> f8 = parallel(b, 8);
        long vPrice = 0, vTime = 0, vAcct = 0, vQty = 0;
        for (int i = 1; i < f8.size(); i++) {
            Ord p = f8.get(i - 1), c = f8.get(i);
            if (p.price() < c.price()) { vPrice++; continue; }
            if (p.price() > c.price()) continue;
            if (p.seq() > c.seq()) { vTime++; continue; }
            if (p.seq() < c.seq()) continue;
            if (p.acct() == Account.자기 && c.acct() == Account.위탁) { vAcct++; continue; }
            if (p.acct() != c.acct()) continue;
            if (p.qty() < c.qty()) vQty++;
        }
        System.out.printf("   %-20s %,10d건%n", "가격우선 위반", vPrice);
        System.out.printf("   %-20s %,10d건%n", "시간우선 위반", vTime);
        System.out.printf("   %-20s %,10d건%n", "위탁매매우선 위반", vAcct);
        System.out.printf("   %-20s %,10d건%n", "수량우선 위반", vQty);
        System.out.println("   (매칭 8스레드 1회 실행)");
        System.out.println();

        // ── 3) 동시호가 예외 ───────────────────────────────────────────
        System.out.println("## 3) 동시호가에서 시가가 상한가로 결정되는 경우");
        System.out.println("   거래소 안내는 위탁매매우선을 시가 등이 상·하한가로 결정되는 경우에만");
        System.out.println("   예외적으로 인정한다고 적습니다. 그 조건을 만들어 배분을 비교합니다.");
        System.out.println();
        // 단일가매매. 상한가에 매수가 몰려 공급보다 수요가 많은 상황을 만든다.
        // 배분 가능한 수량이 모자라므로 우선순위가 실제로 누가 받느냐를 정한다.
        List<Ord> auction = new ArrayList<>();
        Random r = new Random(20130102L);
        for (int i = 0; i < 1000; i++) {
            auction.add(new Ord(0, UPPER_LIMIT, 10 + r.nextInt(90), Account.자기));
            auction.add(new Ord(0, UPPER_LIMIT, 10 + r.nextInt(90), Account.위탁));
        }
        int supply = 0;
        for (Ord o : auction) supply += o.qty();
        supply = supply / 3;    // 공급이 수요의 3분의 1

        System.out.printf("   상한가 %,d원에 매수 %,d건, 총 %,d주 신청. 공급 %,d주.%n",
                UPPER_LIMIT, auction.size(),
                auction.stream().mapToInt(Ord::qty).sum(), supply);
        System.out.println();
        System.out.printf("   %-24s %14s %14s %10s%n", "배분 규칙", "위탁 배분(주)", "자기 배분(주)", "위탁 비중");
        allocate("가격·시간만 (예외 미적용)", auction, supply,
                Comparator.comparingInt(Ord::price).reversed().thenComparingLong(Ord::seq));
        allocate("위탁매매우선 적용", auction, supply, FULL);
        System.out.println();
        System.out.println("   가격과 시간이 전부 같으므로 앞의 규칙으로는 순서가 정해지지 않습니다.");
        System.out.println("   그러면 리스트에 담긴 순서가 그대로 배분 순서가 되고, 그것은 규칙이");
        System.out.println("   아니라 구현 부산물입니다. 위탁매매우선을 적용하면 배분이 결정됩니다.");
        System.out.println();
        System.out.println("   **예외가 인정되는 조건이 따로 있는 이유가 여기 보입니다.** 평시에는 시간우선이");
        System.out.println("   순서를 정하므로 위탁매매우선이 개입할 자리가 거의 없습니다. 동시호가는 접수");
        System.out.println("   시각이 무의미해지는 구간이라 그때만 이 원칙이 실제로 배분을 바꿉니다.");
    }

    static void allocate(String label, List<Ord> demand, int supply, Comparator<Ord> rule) {
        List<Ord> s = new ArrayList<>(demand);
        s.sort(rule);
        int left = supply, wit = 0, own = 0;
        for (Ord o : s) {
            if (left <= 0) break;
            int give = Math.min(left, o.qty());
            if (o.acct() == Account.위탁) wit += give; else own += give;
            left -= give;
        }
        int tot = wit + own;
        System.out.printf(Locale.US, "   %-24s %,14d %,14d %9.1f%%%n",
                label, wit, own, tot == 0 ? 0.0 : 100.0 * wit / tot);
    }
}
