// README 의 "못 한 것" 두 개를 잰다.
//
//   1) 덧셈 한 번마다의 반올림 방향 분포를 재지 않았습니다
//      확인한 것은 순 오차의 크기와 부호까지다. 실험 2 는 60,000 회를 돌려 최종 오차만
//      본다. 그 안에서 매 걸음이 올림인지 내림인지 그대로인지를 세면, 절삭이 왜 한 방향으로
//      쌓이고 HALF_EVEN 은 왜 안 쌓이는지가 최종값이 아니라 과정으로 보인다.
//
//   2) HALF_EVEN 의 잔여 +99원은 시드 하나의 표본입니다
//      다른 시드에서 이 어긋남이 얼마나 남는지 안 재봤다. 시드를 여럿 돌려
//      절삭 편향과 HALF_EVEN 잔여의 분포를 나란히 놓는다.
//
// 결론이 시드에 기대는지 아닌지가 이 실험의 질문이다. 절삭 편향은 구조라 시드가 바뀌어도
// 방향이 안 바뀌어야 하고, HALF_EVEN 잔여는 상쇄의 나머지라 부호가 오락가락해야 한다.
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Random;

public class SeedSweep {

    static final int STEPS = 60_000;
    static final int FEES = 100_000;
    static final int SEEDS = Integer.getInteger("seeds", 30);

    record Step(int down, int up, int exact) {}

    // 실험 2 를 한 시드로 돌리면서 걸음마다의 방향을 센다.
    static Object[] indexRun(long seed, boolean countSteps) {
        Random r = new Random(seed);
        BigDecimal trunc = new BigDecimal("1000.000");
        BigDecimal even = new BigDecimal("1000.000");
        BigDecimal exact = new BigDecimal("1000.000");
        BigDecimal discarded = BigDecimal.ZERO;
        int tDown = 0, tUp = 0, tExact = 0;      // 절삭의 걸음별 방향
        int eDown = 0, eUp = 0, eExact = 0;      // HALF_EVEN 의 걸음별 방향

        for (int i = 0; i < STEPS; i++) {
            BigDecimal delta = BigDecimal.valueOf(r.nextInt(200_001) - 100_000, 6);

            BigDecimal rawT = trunc.add(delta);
            BigDecimal cut = rawT.setScale(3, RoundingMode.DOWN);
            int cT = cut.compareTo(rawT);
            if (cT < 0) tDown++; else if (cT > 0) tUp++; else tExact++;
            discarded = discarded.add(rawT.subtract(cut));
            trunc = cut;

            BigDecimal rawE = even.add(delta);
            BigDecimal rnd = rawE.setScale(3, RoundingMode.HALF_EVEN);
            int cE = rnd.compareTo(rawE);
            if (cE < 0) eDown++; else if (cE > 0) eUp++; else eExact++;
            even = rnd;

            exact = exact.add(delta);
        }
        BigDecimal truncErr = exact.subtract(trunc);
        BigDecimal evenErr = exact.subtract(even);
        return new Object[]{truncErr, evenErr, discarded,
                new Step(tDown, tUp, tExact), new Step(eDown, eUp, eExact)};
    }

    // 실험 3 을 한 시드로 돌려 두 모드의 편향만 돌려준다.
    static long[] feeRun(long seed) {
        Random r = new Random(seed);
        BigDecimal rate = new BigDecimal("0.0015");
        BigDecimal sumExact = BigDecimal.ZERO, sumUp = BigDecimal.ZERO, sumEven = BigDecimal.ZERO;
        int evenDown = 0, evenUp = 0;
        for (int i = 0; i < FEES; i++) {
            int odd = 2 * r.nextInt(500) + 1;
            BigDecimal amount = BigDecimal.valueOf(1000L * odd);
            BigDecimal feeExact = amount.multiply(rate);
            BigDecimal up = feeExact.setScale(0, RoundingMode.HALF_UP);
            BigDecimal ev = feeExact.setScale(0, RoundingMode.HALF_EVEN);
            if (ev.compareTo(feeExact) < 0) evenDown++; else evenUp++;
            sumExact = sumExact.add(feeExact);
            sumUp = sumUp.add(up);
            sumEven = sumEven.add(ev);
        }
        // 이 세 합은 .5 가 짝수 개 모인 값이라 정수다. UNNECESSARY 로 두어
        // 전제가 깨지는 날 조용히 반올림되는 대신 예외로 드러나게 한다.
        return new long[]{
            sumUp.subtract(sumExact).setScale(0, RoundingMode.UNNECESSARY).longValueExact(),
            sumEven.subtract(sumExact).setScale(0, RoundingMode.UNNECESSARY).longValueExact(),
            evenDown, evenUp};
    }

    public static void main(String[] a) {
        System.out.println("# 걸음별 반올림 방향과 시드 민감도");
        System.out.println("# 지수 갱신 " + String.format(Locale.US, "%,d", STEPS)
                + "회, 수수료 " + String.format(Locale.US, "%,d", FEES)
                + "건, 시드 " + SEEDS + "개. 각 조건 1회 실행입니다.");
        System.out.println();

        // ── 1) 걸음별 방향 분포 (본문과 같은 시드 42) ──────────────────
        System.out.println("## 1) 걸음마다의 반올림 방향 (시드 42, 본문과 같은 조건)");
        Object[] r42 = indexRun(42, true);
        Step tS = (Step) r42[3], eS = (Step) r42[4];
        System.out.printf(Locale.US, "  %-16s %10s %10s %10s %14s%n",
                "방식", "내림", "올림", "그대로", "순 오차(포인트)");
        System.out.printf(Locale.US, "  %-16s %,10d %,10d %,10d %14s%n",
                "절삭(DOWN)", tS.down(), tS.up(), tS.exact(),
                ((BigDecimal) r42[0]).negate().toPlainString());
        System.out.printf(Locale.US, "  %-16s %,10d %,10d %,10d %14s%n",
                "HALF_EVEN", eS.down(), eS.up(), eS.exact(),
                ((BigDecimal) r42[1]).negate().toPlainString());
        System.out.println();
        System.out.println("  절삭은 올림이 0건입니다. 값이 양수인 한 항상 0 쪽으로 깎으므로");
        System.out.println("  한 방향으로만 움직이고, 그래서 오차가 상쇄 없이 쌓입니다.");
        System.out.printf(Locale.US, "  HALF_EVEN 은 내림 %,d건과 올림 %,d건이 거의 반반입니다(차이 %,d건).%n",
                eS.down(), eS.up(), Math.abs(eS.down() - eS.up()));
        System.out.println("  최종 오차가 작은 것은 걸음마다 작아서가 아니라 방향이 갈려 상쇄되기 때문입니다.");
        System.out.println();

        // ── 2) 시드 민감도 ────────────────────────────────────────────
        System.out.println("## 2) 시드를 바꾸면 결론이 바뀌는가");
        List<BigDecimal> truncErrs = new ArrayList<>();
        List<BigDecimal> evenErrs = new ArrayList<>();
        int truncNegative = 0, evenNegative = 0;
        for (int s = 1; s <= SEEDS; s++) {
            Object[] r = indexRun(s, false);
            BigDecimal te = ((BigDecimal) r[0]).negate();   // 정밀값 대비 부호
            BigDecimal ee = ((BigDecimal) r[1]).negate();
            truncErrs.add(te);
            evenErrs.add(ee);
            if (te.signum() < 0) truncNegative++;
            if (ee.signum() < 0) evenNegative++;
        }
        summarize("지수 절삭 오차", truncErrs, truncNegative, SEEDS);
        summarize("지수 HALF_EVEN 오차", evenErrs, evenNegative, SEEDS);
        System.out.println();

        List<BigDecimal> upBias = new ArrayList<>();
        List<BigDecimal> evenBias = new ArrayList<>();
        int upPositive = 0, evenPositive = 0;
        for (int s = 1; s <= SEEDS; s++) {
            long[] f = feeRun(s);
            upBias.add(BigDecimal.valueOf(f[0]));
            evenBias.add(BigDecimal.valueOf(f[1]));
            if (f[0] > 0) upPositive++;
            if (f[1] > 0) evenPositive++;
        }
        summarize("수수료 HALF_UP 편향(원)", upBias, SEEDS - upPositive, SEEDS);
        summarize("수수료 HALF_EVEN 편향(원)", evenBias, SEEDS - evenPositive, SEEDS);
        System.out.println();
        System.out.println("  읽는 법. 절삭과 HALF_UP 은 부호가 한쪽으로 몰려야 합니다. 구조적 편향이라");
        System.out.println("  시드가 바뀌어도 방향이 안 바뀝니다. HALF_EVEN 은 부호가 갈려야 합니다.");
        System.out.println("  상쇄하고 남은 나머지라 시드에 따라 위아래로 흔들립니다.");
        System.out.println("  본문의 +99원은 그 흔들림 안의 한 점이지 HALF_EVEN 의 성질이 아닙니다.");
    }

    static void summarize(String label, List<BigDecimal> xs, int negatives, int n) {
        List<BigDecimal> sorted = new ArrayList<>(xs);
        sorted.sort(BigDecimal::compareTo);
        BigDecimal sum = BigDecimal.ZERO;
        for (BigDecimal x : xs) sum = sum.add(x);
        BigDecimal mean = sum.divide(BigDecimal.valueOf(n), 3, RoundingMode.HALF_EVEN);
        System.out.printf(Locale.US, "  %-26s 최소 %14s  중앙 %14s  최대 %14s  음수 %d/%d%n",
                label,
                sorted.get(0).toPlainString(),
                sorted.get(n / 2).toPlainString(),
                sorted.get(n - 1).toPlainString(),
                negatives, n);
        System.out.printf(Locale.US, "  %-26s 평균 %14s%n", "", mean.toPlainString());
    }
}
