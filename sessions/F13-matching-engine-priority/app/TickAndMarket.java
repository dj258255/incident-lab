// README 의 "못 한 것" 하나를 잰다.
//
//   호가 단위와 시장가 주문을 넣지 않았습니다
//   "거래소 안내의 서술을 코드로 옮긴 것이지 실제 거래소 구현이 아닙니다. 호가 단위,
//    단일가매매의 정확한 배분 규칙, 시장가 처리는 들어 있지 않습니다."
//
// 둘 다 넣으면 세션의 결론이 바뀌는지가 질문이다. 앞 절의 결론은 "병렬 매칭이 깨는 것은
// 시간우선만이 아니라 위탁매매우선과 수량우선까지" 였다. 그 결론이 아래 둘에서 어떻게
// 되는지 본다.
//
//   1) 호가 단위. 가격이 연속이 아니라 격자 위에만 존재한다. 격자가 성기면 같은 가격에
//      주문이 더 몰리고, 그러면 가격우선으로 안 갈리는 쌍이 늘어난다. 즉 3·4번 원칙이
//      개입할 자리가 늘어난다. 호가 단위를 바꿔 가며 그 비율을 잰다.
//
//   2) 시장가 주문. 가격이 없으므로 가격우선의 비교 대상이 아니다. 한국거래소 규정은
//      시장가를 지정가보다 우선한다. 그러면 비교자에 층이 하나 더 생긴다. 시장가 비율을
//      바꿔 가며 위반 건수가 어떻게 가는지 본다.
//
// 이 파일은 Principles.java 와 같은 주문장 생성 방식을 쓰되 두 축을 더한다.
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Random;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

public class TickAndMarket {

    enum Account { 위탁, 자기 }

    /** price 가 MARKET 이면 시장가다. 시장가는 가격 비교에서 지정가보다 항상 앞선다. */
    static final int MARKET = Integer.MIN_VALUE;

    record Ord(long seq, int price, int qty, Account acct) {
        boolean isMarket() { return price == MARKET; }
    }

    static final int ORDERS = Integer.getInteger("orders", 20_000);
    static final int BASE = 50_000;
    static final int BAND = 15_000;   // 상하한 폭

    // 가격우선. 시장가가 먼저, 그다음 지정가는 높은 가격이 먼저(매수 기준).
    static int priceRank(Ord o) { return o.isMarket() ? Integer.MAX_VALUE : o.price(); }

    static final Comparator<Ord> FULL = Comparator
            .comparingInt(TickAndMarket::priceRank).reversed()
            .thenComparingLong(Ord::seq)
            .thenComparing(o -> o.acct() == Account.위탁 ? 0 : 1)
            .thenComparing(Comparator.comparingInt(Ord::qty).reversed());

    static final Comparator<Ord> PRICE_TIME = Comparator
            .comparingInt(TickAndMarket::priceRank).reversed()
            .thenComparingLong(Ord::seq);

    /**
     * 호가 단위 tick 의 격자 위에서만 가격이 나오는 주문장.
     * marketPct 비율만큼 시장가를 섞는다. 접수 시각은 네 건씩 묶어 3·4번 원칙이 갈릴
     * 자리를 만든다(Principles.java 와 같은 방식).
     */
    static List<Ord> book(long seed, int tick, double marketPct) {
        Random r = new Random(seed);
        List<Ord> b = new ArrayList<>(ORDERS);
        int steps = Math.max(1, BAND / tick);
        // 접수 시각 묶음 하나에 네 건을 넣되 **가격은 각자 뽑는다.**
        //
        // 처음에는 Principles.java 처럼 묶음의 네 건에 같은 가격을 넣었다. 그러면 동률이
        // 구조적으로 3/4 = 75% 로 고정되어 호가 단위를 바꿔도 값이 안 움직인다.
        // 실제로 여섯 조건이 전부 75.0% 로 나왔다. 호가 단위의 효과를 보려면 가격이
        // 격자에서 독립으로 뽑혀 **부딪칠 때만** 동률이 되어야 한다.
        for (int i = 0; i < ORDERS; i += 4) {
            long seq = i / 4;
            for (int k = 0; k < 4 && i + k < ORDERS; k++) {
                boolean market = r.nextDouble() < marketPct;
                int price = market ? MARKET : BASE + (r.nextInt(steps) - steps / 2) * tick;
                b.add(new Ord(seq, price, 1 + r.nextInt(500),
                        r.nextInt(2) == 0 ? Account.위탁 : Account.자기));
            }
        }
        return b;
    }

    static List<Ord> serial(List<Ord> b, Comparator<Ord> c) {
        List<Ord> s = new ArrayList<>(b);
        s.sort(c);
        return s;
    }

    /**
     * 이 세션의 병렬 모델과 같다. 규칙대로 정렬해 큐에 넣고 스레드 넷이 꺼내 처리한다.
     * 꺼낸 순서와 처리 결과가 기록되는 순서가 달라 위반이 생긴다.
     *
     * 처음에는 청크를 잘라 각자 정렬하고 이어 붙였는데, 그러면 경계 세 곳만 어긋나
     * 조건과 무관하게 위반이 항상 3 이었다. 무의미한 모델이었다.
     */
    static List<Ord> parallel(List<Ord> b, Comparator<Ord> c) throws Exception {
        java.util.concurrent.ConcurrentLinkedQueue<Ord> q =
                new java.util.concurrent.ConcurrentLinkedQueue<>();
        List<Ord> sorted = new ArrayList<>(b);
        sorted.sort(c);
        q.addAll(sorted);
        List<Ord> fills = java.util.Collections.synchronizedList(new ArrayList<>(b.size()));
        int threads = 4;
        java.util.concurrent.CountDownLatch done = new java.util.concurrent.CountDownLatch(threads);
        for (int t = 0; t < threads; t++) {
            Thread.ofPlatform().start(() -> {
                Ord o;
                while ((o = q.poll()) != null) fills.add(o);
                done.countDown();
            });
        }
        done.await();
        return fills;
    }

    /** 인접한 쌍이 비교자 순서를 어기는 횟수. */
    static long violations(List<Ord> l, Comparator<Ord> c) {
        long v = 0;
        for (int i = 1; i < l.size(); i++) if (c.compare(l.get(i - 1), l.get(i)) > 0) v++;
        return v;
    }

    /** 가격우선만으로 안 갈리는 인접 쌍의 비율. 3·4번 원칙이 개입할 자리다. */
    static double tieRate(List<Ord> l) {
        if (l.size() < 2) return 0;
        long tie = 0;
        List<Ord> s = serial(l, FULL);
        for (int i = 1; i < s.size(); i++) {
            Ord a = s.get(i - 1), b = s.get(i);
            if (priceRank(a) == priceRank(b) && a.seq() == b.seq()) tie++;
        }
        return 100.0 * tie / (s.size() - 1);
    }

    public static void main(String[] args) throws Exception {
        System.out.println("# 호가 단위와 시장가를 넣으면");
        System.out.printf(Locale.US, "# 주문 %,d건, 기준가 %,d, 상하한 폭 ±%,d%n", ORDERS, BASE, BAND);
        System.out.println();

        System.out.println("==================================================================");
        System.out.println("## 1) 호가 단위가 성길수록 3·4번 원칙이 개입할 자리가 늘어납니다");
        System.out.println("==================================================================");
        System.out.printf(Locale.US, "  %10s %16s %18s %16s%n",
                "호가 단위", "가격·시간 동률", "단일 스레드 위반", "병렬 위반");
        for (int tick : new int[]{1, 10, 50, 100, 500, 1000}) {
            List<Ord> b = book(20130101L, tick, 0.0);
            List<Ord> ser = serial(b, FULL);
            List<Ord> par = parallel(b, FULL);
            System.out.printf(Locale.US, "  %10d %15.1f%% %,18d %,16d%n",
                    tick, tieRate(b), violations(ser, FULL), violations(par, FULL));
        }
        System.out.println();
        System.out.println("  호가 단위가 성길수록 같은 가격에 주문이 몰립니다. 가격우선으로 안 갈리는");
        System.out.println("  쌍이 늘고, 그만큼 위탁매매우선과 수량우선이 판정에 개입합니다.");
        System.out.println("  단일 스레드는 비교자대로 정렬하므로 위반이 0 입니다.");
        System.out.println("  병렬 위반은 호가 단위와 단조 관계가 없습니다. 스레드가 큐에서 꺼낸 뒤");
        System.out.println("  기록까지 걸리는 시간이 정하므로 그 값은 스케줄링 잡음입니다. 방향을 읽으면 안 됩니다.");
        System.out.println();

        System.out.println("==================================================================");
        System.out.println("## 2) 시장가를 섞으면");
        System.out.println("==================================================================");
        System.out.println("  시장가는 가격이 없으므로 가격우선의 비교 대상이 아닙니다.");
        System.out.println("  한국거래소 규정은 시장가를 지정가보다 앞에 둡니다.");
        System.out.println();
        System.out.printf(Locale.US, "  %10s %14s %16s %16s%n",
                "시장가 비율", "가격·시간 동률", "단일 스레드 위반", "병렬 위반");
        for (double pct : new double[]{0.0, 0.05, 0.20, 0.50}) {
            List<Ord> b = book(20130101L, 50, pct);
            List<Ord> ser = serial(b, FULL);
            List<Ord> par = parallel(b, FULL);
            System.out.printf(Locale.US, "  %9.0f%% %13.1f%% %,16d %,16d%n",
                    pct * 100, tieRate(b), violations(ser, FULL), violations(par, FULL));
        }
        System.out.println();
        System.out.println("  시장가끼리는 가격이 다 같으므로 그 안에서는 시간·위탁·수량이 판정합니다.");
        System.out.println("  비율이 오를수록 동률이 늘어나는 것이 그 뜻입니다.");
        System.out.println();

        System.out.println("==================================================================");
        System.out.println("## 3) 시장가를 층으로 안 두면 무엇이 깨지는가");
        System.out.println("==================================================================");
        System.out.println("  시장가를 지정가와 같은 축에서 다루면(가격을 0 으로 두면) 규정과 어긋납니다.");
        System.out.println("  그 상태의 순서를 규정 비교자로 채점합니다.");
        System.out.println();
        List<Ord> b = book(20130101L, 50, 0.20);
        // 시장가를 가격 0 인 지정가처럼 다루는 잘못된 비교자
        Comparator<Ord> WRONG = Comparator
                .comparingInt((Ord o) -> o.isMarket() ? 0 : o.price()).reversed()
                .thenComparingLong(Ord::seq)
                .thenComparing(o -> o.acct() == Account.위탁 ? 0 : 1)
                .thenComparing(Comparator.comparingInt(Ord::qty).reversed());
        List<Ord> wrong = serial(b, WRONG);
        List<Ord> right = serial(b, FULL);

        // 인접 쌍 위반만 세면 시장가가 통째로 뒤로 밀려도 경계 한 곳만 잡혀 1건이 된다.
        // 실제 피해는 "시장가 한 건이 몇 건의 지정가에 밀렸는가" 다.
        long markets = 0, behindTotal = 0, behindMax = 0, hurt = 0;
        long limitsSeen = 0;
        for (Ord o : wrong) {
            if (o.isMarket()) {
                markets++;
                behindTotal += limitsSeen;
                if (limitsSeen > behindMax) behindMax = limitsSeen;
                if (limitsSeen > 0) hurt++;
            } else {
                limitsSeen++;
            }
        }
        System.out.printf(Locale.US, "  %-34s %,12d건%n",
                "규정대로 정렬한 뒤 규정으로 채점(인접 쌍)", violations(right, FULL));
        System.out.printf(Locale.US, "  %-34s %,12d건%n",
                "시장가를 0원으로 보고 정렬(인접 쌍)", violations(wrong, FULL));
        System.out.println();
        System.out.printf(Locale.US, "  시장가 주문 %,d건 중 지정가에 밀린 것 %,d건 (%.1f%%)%n",
                markets, hurt, markets == 0 ? 0.0 : 100.0 * hurt / markets);
        System.out.printf(Locale.US, "  시장가 한 건이 밀린 지정가 수: 평균 %,.0f건, 최대 %,d건%n",
                markets == 0 ? 0.0 : (double) behindTotal / markets, behindMax);
        System.out.println();
        System.out.println("  인접 쌍으로 세면 1건입니다. 시장가가 통째로 뒤로 몰려 경계가 한 곳뿐이기");
        System.out.println("  때문입니다. 실제로는 시장가 대부분이 지정가 수천 건에 밀렸습니다.");
        System.out.println("  **위반 건수를 인접 쌍으로 세는 지표는 이런 통짜 오류를 못 잡습니다.**");
        System.out.println();
        System.out.println("  그리고 이것은 단일 스레드에서 난 것입니다. 동시성 문제가 아니라 규칙을");
        System.out.println("  잘못 옮긴 것인데, 병렬 매칭의 위반과 겉모습이 같습니다. 위반 건수만 보고");
        System.out.println("  스레드를 줄이는 쪽으로 가면 원인을 못 찾습니다.");
        System.out.println();
        System.out.println("  각 조건 1회 실행이고 시드는 고정입니다.");
    }
}
