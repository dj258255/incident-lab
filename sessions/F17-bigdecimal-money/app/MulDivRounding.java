// README 의 "못 한 것" 하나를 잰다.
//
//   곱셈과 나눗셈의 반올림 방향은 재지 않았습니다
//   "실험 2 는 덧셈만 다뤘습니다. 곱셈과 나눗셈에서 같은 편향이 나오는지는
//    재지 않았습니다."
//
// 처음에는 곱셈이 더 벌어질 것으로 봤다. 이번 걸음에서 잘린 오차가 다음 걸음에 다시
// 곱해지므로 복리로 쌓인다는 예상이었다. 실측은 곱셈 29.984 대 덧셈 29.960 으로
// 사실상 같다. 걸음당 절삭 오차가 잔고 대비 1e-6 수준이라 복리 항이 2차이고, 6만
// 걸음으로는 안 드러난다. 예상이 틀린 자리라 그대로 적어 둔다.
//
// 나눗셈은 문제의 성질 자체가 다르다. BigDecimal.divide 를 스케일 없이 부르면
// 나누어떨어지지 않을 때 ArithmeticException 을 던진다. 조용히 틀리는 것이 아니라
// 터진다. 얼마나 자주 터지는지를 센다.
import java.math.BigDecimal;
import java.math.MathContext;
import java.math.RoundingMode;
import java.util.Locale;
import java.util.Random;

public class MulDivRounding {

    static final int STEPS = Integer.getInteger("steps", 60_000);
    static final int SEEDS = Integer.getInteger("seeds", 30);
    // 참값 계산에 쓸 정밀도. 곱셈을 그대로 두면 스케일이 걸음마다 늘어 18만 자리가 된다.
    static final MathContext REF = new MathContext(60);

    record Dir(int down, int up, int exact) {
        String pct(int total) {
            return String.format(Locale.ROOT, "내림 %5.1f%% 올림 %5.1f%% 그대로 %5.1f%%",
                    100.0 * down / total, 100.0 * up / total, 100.0 * exact / total);
        }
    }

    record MulResult(BigDecimal err, Dir dir) {}

    // 잔고에 (1 + 소액 수익률) 을 계속 곱하고, 걸음마다 3자리로 되돌린다.
    static MulResult mulRun(long seed, RoundingMode mode) {
        Random r = new Random(seed);
        BigDecimal acc = new BigDecimal("1000.000");
        BigDecimal exact = new BigDecimal("1000.000");
        int down = 0, up = 0, same = 0;
        for (int i = 0; i < STEPS; i++) {
            // 1 ± 0.0001 범위의 배율. 덧셈 실험의 델타와 크기를 맞춘다.
            BigDecimal rate = BigDecimal.ONE.add(
                    BigDecimal.valueOf(r.nextInt(200_001) - 100_000, 9));
            BigDecimal raw = acc.multiply(rate);
            BigDecimal cut = raw.setScale(3, mode);
            int c = cut.compareTo(raw);
            if (c < 0) down++; else if (c > 0) up++; else same++;
            acc = cut;
            exact = exact.multiply(rate, REF);
        }
        return new MulResult(exact.subtract(acc), new Dir(down, up, same));
    }

    // 덧셈 쪽을 같은 걸음 수로 다시 돌려 나란히 놓는다.
    static BigDecimal addRun(long seed, RoundingMode mode) {
        Random r = new Random(seed);
        BigDecimal acc = new BigDecimal("1000.000");
        BigDecimal exact = new BigDecimal("1000.000");
        for (int i = 0; i < STEPS; i++) {
            BigDecimal delta = BigDecimal.valueOf(r.nextInt(200_001) - 100_000, 6);
            acc = acc.add(delta).setScale(3, mode);
            exact = exact.add(delta);
        }
        return exact.subtract(acc);
    }

    public static void main(String[] args) {
        System.out.println("# 곱셈과 나눗셈의 반올림");
        System.out.printf(Locale.ROOT, "# 걸음 %,d, 시드 %d개%n%n", STEPS, SEEDS);

        System.out.println("==================================================================");
        System.out.println("## 1) 곱셈과 덧셈의 오차 크기");
        System.out.println("==================================================================");
        System.out.printf(Locale.ROOT, "  %-12s %20s %20s%n", "반올림", "곱셈 오차 중앙", "덧셈 오차 중앙");
        for (RoundingMode mode : new RoundingMode[]{RoundingMode.DOWN, RoundingMode.HALF_UP,
                                                    RoundingMode.HALF_EVEN}) {
            BigDecimal[] mul = new BigDecimal[SEEDS];
            BigDecimal[] add = new BigDecimal[SEEDS];
            for (int s = 0; s < SEEDS; s++) {
                mul[s] = mulRun(s + 1, mode).err();
                add[s] = addRun(s + 1, mode);
            }
            java.util.Arrays.sort(mul);
            java.util.Arrays.sort(add);
            System.out.printf(Locale.ROOT, "  %-12s %20s %20s%n", mode,
                    mul[SEEDS / 2].setScale(3, RoundingMode.HALF_EVEN).toPlainString(),
                    add[SEEDS / 2].setScale(3, RoundingMode.HALF_EVEN).toPlainString());
        }
        System.out.println();
        System.out.println("  두 값이 거의 같습니다. 곱셈이 복리로 더 벌어질 것이라는 예상이 틀렸습니다.");
        System.out.println("  걸음당 절삭 오차가 잔고 대비 1e-6 수준이라 복리 항이 2차입니다.");
        System.out.println();

        System.out.println("  걸음별 반올림 방향(시드 1)");
        for (RoundingMode mode : new RoundingMode[]{RoundingMode.DOWN, RoundingMode.HALF_UP,
                                                    RoundingMode.HALF_EVEN}) {
            Dir d = mulRun(1, mode).dir();
            System.out.printf(Locale.ROOT, "    곱셈 %-11s %s%n", mode, d.pct(STEPS));
        }
        System.out.println();
        System.out.println("  DOWN 은 걸음마다 한 방향입니다. HALF_UP 과 HALF_EVEN 은 양쪽으로 갈립니다.");
        System.out.println("  갈리는데도 오차가 남는지, 남으면 부호가 시드마다 바뀌는지가 아래입니다.");
        System.out.println();

        System.out.printf(Locale.ROOT, "  %-12s %8s %8s %8s%n", "반올림", "양수", "음수", "0");
        for (RoundingMode mode : new RoundingMode[]{RoundingMode.DOWN, RoundingMode.HALF_UP,
                                                    RoundingMode.HALF_EVEN}) {
            int pos = 0, neg = 0, zero = 0;
            for (int s = 0; s < SEEDS; s++) {
                int sig = mulRun(s + 1, mode).err().signum();
                if (sig > 0) pos++; else if (sig < 0) neg++; else zero++;
            }
            System.out.printf(Locale.ROOT, "  %-12s %8d %8d %8d%n", mode, pos, neg, zero);
        }
        System.out.println();
        System.out.println("  한 방향으로 몰리면 구조적 편향이고, 갈리면 상쇄의 나머지입니다.");
        System.out.println();

        System.out.println("==================================================================");
        System.out.println("## 2) 나눗셈은 조용히 틀리지 않고 터집니다");
        System.out.println("==================================================================");
        System.out.println("  BigDecimal.divide 를 스케일 없이 부르면 나누어떨어지지 않을 때");
        System.out.println("  ArithmeticException 을 던집니다. 몇 번에 한 번 터지는지 셉니다.");
        System.out.println();

        Random r = new Random(20260731);
        int trials = 100_000, blown = 0;
        for (int i = 0; i < trials; i++) {
            BigDecimal a = BigDecimal.valueOf(r.nextInt(1_000_000) + 1, 3);
            BigDecimal b = BigDecimal.valueOf(r.nextInt(999) + 2);
            try {
                a.divide(b);
            } catch (ArithmeticException e) {
                blown++;
            }
        }
        System.out.printf(Locale.ROOT, "  %,d회 중 %,d회가 예외입니다 (%.1f%%)%n",
                trials, blown, 100.0 * blown / trials);
        System.out.println();
        System.out.println("  나누는 수가 2, 5, 10 처럼 10 의 소인수로만 이루어졌을 때만 끝납니다.");
        System.out.println("  실무의 나눗셈은 인원수나 개월수로 나누므로 3 과 7 이 흔합니다.");
        System.out.println();

        System.out.println("  스케일을 주면 안 터지는 대신 반올림이 들어갑니다.");
        System.out.printf(Locale.ROOT, "  %-12s %22s%n", "반올림", "나누고 곱하기 1,000번 뒤");
        for (RoundingMode mode : new RoundingMode[]{RoundingMode.DOWN, RoundingMode.HALF_UP,
                                                    RoundingMode.HALF_EVEN}) {
            // 1/n 로 나눈 뒤 다시 n 을 곱하면 원래로 돌아와야 하는데, 반올림이 끼면 안 돌아온다.
            BigDecimal v = new BigDecimal("1000.000");
            Random rr = new Random(7);
            for (int i = 0; i < 1000; i++) {
                int n = rr.nextInt(9) + 2;
                v = v.divide(BigDecimal.valueOf(n), 3, mode).multiply(BigDecimal.valueOf(n))
                     .setScale(3, mode);
            }
            System.out.printf(Locale.ROOT, "  %-12s %22s%n", mode, v.toPlainString());
        }
        System.out.println();
        System.out.println("  1000 으로 시작해 2~10 중 무작위 수로 나눈 뒤 같은 수로 곱하기를 1,000번 했습니다.");
        System.out.println("  나눈 뒤 같은 수로 곱하므로 참값은 1000.000 입니다.");
        System.out.println();
        System.out.println("  각 조건 1회 실행이고 곱셈 오차는 시드 " + SEEDS + "개의 중앙값입니다.");
    }
}
