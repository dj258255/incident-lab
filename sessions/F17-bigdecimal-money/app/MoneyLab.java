import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.HashSet;
import java.util.Locale;
import java.util.Random;
import java.util.Set;
import java.util.TreeSet;

/**
 * F17 부동소수점 금지 재현. 1982년 밴쿠버 증권거래소는 지수를 갱신할 때마다 소수 셋째 자리
 * 아래를 절삭했고, 그 손실이 22개월 누적되어 1000으로 시작한 지수가 1983년 11월 520대까지
 * 내려갔다. 주말 재계산 후 지수는 1098.892로 정정됐다. 여기서는 그 핵심(절삭·이진 표현 오차가
 * 돈과 지수를 조용히 깎는다)을 네 가지 실험으로 축소 재현한다.
 *
 * 실험 1: 0.1 단위 수수료 100만 건을 double로 누적하면 합계가 얼마나 어긋나는가
 * 실험 2: 밴쿠버 방식(소수 3자리 절삭) 갱신을 수만 번 반복하면 지수가 얼마나 녹는가
 * 실험 3: 0.5원 경계 수수료 대량 반올림에서 HALF_UP이 만드는 편향은 얼마인가
 * 실험 4: BigDecimal.equals는 scale까지 비교해서 HashSet 중복 제거가 왜 깨지는가
 *
 * 해소는 scale과 RoundingMode를 명시한 BigDecimal, 또는 최소 화폐단위 long이다.
 * 같은 조건(같은 건수, 같은 시드)으로 재계측해 오차를 다시 잰다.
 */
public class MoneyLab {

    static String won(BigDecimal v) {
        return v.toPlainString();
    }

    // 부호를 붙여 오차를 표시한다. 0이면 "0"을 그대로 둔다.
    static String signed(BigDecimal v) {
        return (v.signum() > 0 ? "+" : "") + v.toPlainString();
    }

    public static void main(String[] args) {
        System.out.println("== F17 부동소수점 금지 재현 (JDK " + Runtime.version().feature() + ") ==");
        System.out.println();
        Exp1 e1 = exp1();
        Exp2 e2 = exp2();
        Exp3 e3 = exp3();
        exp4();
        fixes(e1, e2, e3);
    }

    record Exp1(BigDecimal exact, BigDecimal dErr, BigDecimal bErr, long tenthsSum) {}

    // 실험 1. 수수료 110.1원(0.1 단위라 이진법으로 정확히 표현되지 않는 값) 100만 건 누적.
    static Exp1 exp1() {
        final int N = 1_000_000;
        double dSum = 0.0;
        for (int i = 0; i < N; i++) dSum += 110.1;

        BigDecimal fee = new BigDecimal("110.1");
        BigDecimal bSum = BigDecimal.ZERO;
        for (int i = 0; i < N; i++) bSum = bSum.add(fee);

        // 해소 후보: 최소 화폐단위(0.1원 = 1) long 누적. 오버플로는 addExact로 드러낸다.
        long tenths = 0;
        for (int i = 0; i < N; i++) tenths = Math.addExact(tenths, 1101);

        BigDecimal exact = fee.multiply(BigDecimal.valueOf(N)); // 110,100,000.0원
        BigDecimal dErr = new BigDecimal(dSum).subtract(exact); // double 합계의 정확한 십진값과의 차
        BigDecimal bErr = bSum.subtract(exact);
        // 오차 분해: 110.1을 double로 저장하는 순간의 표현 오차 몫과, 덧셈마다 생기는 반올림 누적 몫
        BigDecimal reprPart = new BigDecimal(110.1).subtract(fee).multiply(BigDecimal.valueOf(N));
        BigDecimal addPart = dErr.subtract(reprPart);
        BigDecimal addShare = addPart.multiply(BigDecimal.valueOf(100)).divide(dErr, 4, RoundingMode.HALF_EVEN);

        System.out.println("[실험 1] 수수료 110.1원 x 1,000,000건 누적 합계 (정확값 110,100,000원)");
        System.out.println("  double     합계 = " + new BigDecimal(dSum).toPlainString() + " 원 (이진값의 정확한 십진 전개)");
        System.out.println("  BigDecimal 합계 = " + won(bSum) + " 원");
        System.out.println("  double 오차 = " + signed(dErr) + " 원  <- 대사가 안 맞는다");
        System.out.println("  오차 분해: 110.1 표현 오차 몫  = " + signed(reprPart.stripTrailingZeros()) + " 원");
        System.out.println("             덧셈 반올림 누적 몫 = " + signed(addPart.stripTrailingZeros()) + " 원 (오차의 " + addShare.toPlainString() + "%)");
        System.out.println("  (0.1 + 0.2) = " + (0.1 + 0.2) + " | (0.1+0.2 == 0.3) = " + (0.1 + 0.2 == 0.3));
        System.out.println();
        return new Exp1(exact, dErr, bErr, tenths);
    }

    record Exp2(BigDecimal trunc, BigDecimal even, BigDecimal exact,
                BigDecimal truncErr, BigDecimal evenErr, BigDecimal discarded) {}

    // 실험 2. 밴쿠버 방식. 지수 1000.000에서 무작위 소량 갱신을 60,000회 반복한다.
    // 한쪽은 소수 셋째 자리 아래를 절삭(DOWN), 한쪽은 은행가 반올림(HALF_EVEN), 기준선은 무반올림.
    static Exp2 exp2() {
        final int STEPS = 60_000;
        Random r = new Random(42); // 고정 시드. 누구나 같은 결과를 얻는다.
        BigDecimal trunc = new BigDecimal("1000.000");
        BigDecimal even = new BigDecimal("1000.000");
        BigDecimal exact = new BigDecimal("1000.000");
        BigDecimal discarded = BigDecimal.ZERO;

        for (int i = 0; i < STEPS; i++) {
            // 갱신 폭: -0.100000 ~ +0.100000 (소수 6자리). 셋째 자리 아래 잔여가 항상 생긴다.
            BigDecimal delta = BigDecimal.valueOf(r.nextInt(200_001) - 100_000, 6);
            BigDecimal raw = trunc.add(delta);
            BigDecimal cut = raw.setScale(3, RoundingMode.DOWN); // 밴쿠버가 한 것: 절삭
            discarded = discarded.add(raw.subtract(cut));        // 매번 버린 잔여를 적산
            trunc = cut;
            even = even.add(delta).setScale(3, RoundingMode.HALF_EVEN);
            exact = exact.add(delta);
        }

        BigDecimal truncErr = exact.subtract(trunc);
        BigDecimal evenErr = exact.subtract(even);
        System.out.println("[실험 2] 밴쿠버 방식: 지수 1000.000에서 무작위 갱신 60,000회 (고정 시드 42, 소수 3자리)");
        System.out.println("  절삭(DOWN)        = " + won(trunc));
        System.out.println("  반올림(HALF_EVEN) = " + won(even));
        System.out.println("  무반올림 정밀값    = " + won(exact));
        System.out.println("  정밀값 대비 절삭 오차   = " + signed(truncErr.negate()) + " 포인트 (버린 잔여 적산 " + won(discarded) + "와 크기 일치)");
        System.out.println("  정밀값 대비 반올림 오차 = " + signed(evenErr.negate()) + " 포인트");
        System.out.println();
        return new Exp2(trunc, even, exact, truncErr, evenErr, discarded);
    }

    record Exp3(long exactSum, BigDecimal upBias, BigDecimal evenBias, int evenDown, int evenUp) {}

    // 실험 3. 0.5원 경계에 몰리는 수수료 100,000건. 주문금액을 1,000원 x 홀수로 만들어
    // 요율 0.15%의 수수료가 전부 x.5원이 되게 했다. 원 단위 반올림 모드별 합계를 비교한다.
    static Exp3 exp3() {
        final int N = 100_000;
        Random r = new Random(7); // 고정 시드
        BigDecimal rate = new BigDecimal("0.0015");
        BigDecimal sumExact = BigDecimal.ZERO, sumUp = BigDecimal.ZERO, sumEven = BigDecimal.ZERO;
        int evenDown = 0, evenUp = 0;

        for (int i = 0; i < N; i++) {
            int odd = 2 * r.nextInt(500) + 1;                       // 1, 3, ..., 999
            BigDecimal amount = BigDecimal.valueOf(1000L * odd);    // 주문금액
            BigDecimal feeExact = amount.multiply(rate);            // 항상 소수부 .5000원
            BigDecimal up = feeExact.setScale(0, RoundingMode.HALF_UP);
            BigDecimal ev = feeExact.setScale(0, RoundingMode.HALF_EVEN);
            if (ev.compareTo(feeExact) < 0) evenDown++; else evenUp++;
            sumExact = sumExact.add(feeExact);
            sumUp = sumUp.add(up);
            sumEven = sumEven.add(ev);
        }

        long exactSum = sumExact.setScale(0).longValueExact(); // .5원 짝수 개의 합이라 정수
        BigDecimal upBias = sumUp.subtract(sumExact);
        BigDecimal evenBias = sumEven.subtract(sumExact);
        System.out.println("[실험 3] 0.5원 경계 수수료 100,000건을 원 단위 반올림 (요율 0.15%, 고정 시드 7)");
        System.out.println(String.format(Locale.US, "  정확 합계      = %,d 원", exactSum));
        System.out.println(String.format(Locale.US, "  HALF_UP 합계   = %,d 원 (정확 대비 %+,d 원)",
                sumUp.longValueExact(), upBias.setScale(0).longValueExact()));
        System.out.println(String.format(Locale.US, "  HALF_EVEN 합계 = %,d 원 (정확 대비 %+,d 원, 내림 %,d건/올림 %,d건)",
                sumEven.longValueExact(), evenBias.setScale(0).longValueExact(), evenDown, evenUp));
        System.out.println();
        return new Exp3(exactSum, upBias, evenBias, evenDown, evenUp);
    }

    // 실험 4. BigDecimal.equals는 값과 scale을 함께 비교한다. 같은 2,500원이
    // DB numeric에서 "2500.00", API 응답에서 "2500.0"으로 들어오면 HashSet 중복 제거가 깨진다.
    static void exp4() {
        BigDecimal a = new BigDecimal("2500.0");
        BigDecimal b = new BigDecimal("2500.00");
        Set<BigDecimal> dedup = new HashSet<>();
        dedup.add(a);
        dedup.add(b);
        System.out.println("[실험 4] BigDecimal equals 함정: 같은 2,500원이 scale만 다르게 두 번 들어온다");
        System.out.println("  a = new BigDecimal(\"2500.0\"), b = new BigDecimal(\"2500.00\")");
        System.out.println("  a.equals(b) = " + a.equals(b) + " | a.compareTo(b) = " + a.compareTo(b));
        System.out.println("  a.hashCode() = " + a.hashCode() + " | b.hashCode() = " + b.hashCode());
        System.out.println("  HashSet에 둘 다 넣으면 size = " + dedup.size() + "  <- 중복 제거 실패, 같은 돈이 두 번 산다");
        System.out.println();
    }

    // 해소 재계측. 같은 건수, 같은 시드에서 해소 방식의 오차를 다시 잰다.
    static void fixes(Exp1 e1, Exp2 e2, Exp3 e3) {
        System.out.println("== 해소 재계측 (scale·RoundingMode 명시, 최소 화폐단위 long) ==");

        // 1) BigDecimal("110.1") 누적과 long(0.1원 단위) 누적의 오차
        long tenthsExact = 1101L * 1_000_000L;
        System.out.println("[해소 1] BigDecimal(\"110.1\") 누적 오차 = " + won(e1.bErr()) + " 원"
                + " | long(0.1원 단위) 누적 오차 = " + (e1.tenthsSum() - tenthsExact) + " (합계 "
                + String.format(Locale.US, "%,d", e1.tenthsSum() / 10) + "." + (e1.tenthsSum() % 10) + " 원)");
        System.out.println("  주의: new BigDecimal(0.1) = " + new BigDecimal(0.1));
        System.out.println("        BigDecimal.valueOf(0.1) = " + BigDecimal.valueOf(0.1) + "  <- 문자열/valueOf로 만들어야 한다");

        // 2) 지수는 HALF_EVEN으로: 절삭 대비 오차 비율
        BigDecimal ratio = e2.truncErr().abs().divide(e2.evenErr().abs(), 0, RoundingMode.HALF_EVEN);
        System.out.println("[해소 2] HALF_EVEN 지수 오차 = " + e2.evenErr().abs().toPlainString()
                + " 포인트 (절삭 " + e2.truncErr().toPlainString() + "의 1/" + ratio.toPlainString() + ")");

        // 3) 수수료 반올림은 HALF_EVEN으로: 편향 비교
        System.out.println(String.format(Locale.US, "[해소 3] HALF_EVEN 편향 %+,d 원 vs HALF_UP 편향 %+,d 원 (100,000건)",
                e3.evenBias().setScale(0).longValueExact(), e3.upBias().setScale(0).longValueExact()));

        // 4) 중복 제거는 scale 통일 또는 compareTo 기반 컬렉션으로
        BigDecimal a = new BigDecimal("2500.0");
        BigDecimal b = new BigDecimal("2500.00");
        Set<BigDecimal> unified = new HashSet<>();
        unified.add(a.setScale(2, RoundingMode.UNNECESSARY));
        unified.add(b.setScale(2, RoundingMode.UNNECESSARY));
        Set<BigDecimal> tree = new TreeSet<>(); // TreeSet은 compareTo로 판단한다
        tree.add(a);
        tree.add(b);
        System.out.println("[해소 4] setScale(2) 통일 HashSet.size() = " + unified.size()
                + " | TreeSet(compareTo).size() = " + tree.size());
        System.out.println("  주의: stripTrailingZeros().toString() = \"" + a.stripTrailingZeros() + "\""
                + " (지수 표기가 된다, 출력은 toPlainString 사용)");
    }
}
