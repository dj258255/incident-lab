import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Random;

/**
 * F01 한맥 재현. 2013년 한맥투자증권은 옵션 이론가 계산에서 잔존일수를 분모로 쓰다가
 * 만기 당일 분모가 0이 되어 계산값이 비정상이 되었고, 그 주문이 상·하한 검증을 통과해
 * 143초 동안 대량 체결됐다. 여기서는 그 핵심(0으로 나눈 값이 검증을 뚫는다)을 축소 재현한다.
 *
 * 관전 포인트: "0으로 나누면 문제"라고 뭉뚱그리기 쉽지만, IEEE 754에서
 *   - 5.0 / 0.0 = +Infinity  (분자가 0이 아님)
 *   - 0.0 / 0.0 = NaN        (분자도 0)
 * 이고, 검증식이 "상한 초과거나 하한 미만이면 거부"라면 Infinity는 (Inf > 상한)=true로 거부되지만
 * NaN은 모든 비교가 false라 어느 쪽에도 안 걸려 그대로 접수된다. 실제로 뚫는 건 NaN 쪽이다.
 *
 * 2026-07-29 재측정: 이전 드라이버는 루프가 !Double.isFinite(px)로 먼저 걸러내고 3건째에
 * 킬스위치로 break해서, acceptFixed의 유한성 검사가 한 번도 실행되지 않았다. 무엇이 무엇을
 * 막았는지 가르기 위해 루프에서 사전 필터를 걷어내 화이트리스트가 모든 주문을 판정하게 하고,
 * 킬스위치 켬/끔과 정렬/섞은 배치를 조건으로 나눠 네 번 돌린다.
 */
public class Hanmac {

    record Order(String id, double base, double numerator, double days) {}

    /** 킬스위치 임계값. 시연용 값이다. */
    static final int KILL_THRESHOLD = 3;

    /**
     * 계측용 카운터. acceptFixed 안의 유한성 검사가 실제로 몇 번 참이 됐는지를 값 종류별로 센다.
     * "가드가 도달 가능한가"와 "가드가 NaN을 실제로 거부하는가"를 출력으로 확인하기 위한 것이다.
     */
    static int guardRejectedNaN = 0;
    static int guardRejectedInf = 0;

    // 주문가 = base * (1 + numerator/days). days==0 이면 IEEE 754상 예외 없이 Infinity 또는 NaN.
    static double price(Order o) {
        double factor = o.numerator() / o.days(); // 분모 0에서 예외가 나지 않는다
        return o.base() * (1.0 + factor);
    }

    // (버그) 접수 로직: 상한 초과거나 하한 미만이면 거부, 아니면 접수.
    static boolean acceptBuggy(double px, double lower, double upper) {
        if (px > upper || px < lower) return false; // 거부
        return true;                                 // 접수
    }

    // (해소) 유한성 가드를 먼저 둔다. 비정상 값은 명시적으로 거부한다.
    static boolean acceptFixed(double px, double lower, double upper) {
        if (!Double.isFinite(px)) {                              // NaN/Infinity 즉시 거부
            if (Double.isNaN(px)) guardRejectedNaN++; else guardRejectedInf++; // 계측
            return false;
        }
        if (px > upper || px < lower) return false;
        return true;
    }

    interface Acceptor {
        boolean accept(double px, double lower, double upper);
    }

    record Result(String label, boolean killswitchOn,
                  int total, int processed,
                  int acceptedNormal, int acceptedBad,
                  int rejectedInf, int rejectedNaN, int rejectedRange,
                  int guardNaN, int guardInf,
                  boolean killed, int killedAt,
                  int unevaluated, int unevaluatedNormal) {}

    /**
     * 조건 하나를 돌린다. 사전 필터 없이 acceptor가 모든 주문을 판정하므로,
     * 화이트리스트가 실제로 실행되고 그 결과가 카운터에 남는다.
     * killswitchOn이 true면 비정상 값 누적이 임계값에 닿는 순간 루프를 멈춘다.
     */
    static Result run(String label, List<Order> book, Acceptor acceptor,
                      boolean killswitchOn, double lower, double upper) {
        guardRejectedNaN = 0;
        guardRejectedInf = 0;

        int acceptedNormal = 0, acceptedBad = 0;
        int rejectedInf = 0, rejectedNaN = 0, rejectedRange = 0, nonFinite = 0;
        boolean killed = false;
        int processed = 0, killedAt = 0;

        for (Order o : book) {
            processed++;
            double px = price(o);
            if (acceptor.accept(px, lower, upper)) {
                // 접수된 것을 값 종류로 다시 가른다. 비정상 값이 접수되면 여기서 세진다.
                if (Double.isFinite(px)) acceptedNormal++; else acceptedBad++;
                continue;
            }
            if (Double.isNaN(px)) { rejectedNaN++; nonFinite++; }
            else if (Double.isInfinite(px)) { rejectedInf++; nonFinite++; }
            else { rejectedRange++; }

            if (killswitchOn && !killed && nonFinite >= KILL_THRESHOLD) {
                killed = true;
                killedAt = processed;
                break;
            }
        }

        // 킬스위치로 멈춘 뒤 평가되지 않고 남은 주문. 그중 정상 주문이 부수 피해다.
        int unevaluated = book.size() - processed;
        int unevaluatedNormal = 0;
        for (int i = processed; i < book.size(); i++) {
            if (Double.isFinite(price(book.get(i)))) unevaluatedNormal++;
        }

        return new Result(label, killswitchOn, book.size(), processed,
                acceptedNormal, acceptedBad,
                rejectedInf, rejectedNaN, rejectedRange,
                guardRejectedNaN, guardRejectedInf,
                killed, killedAt, unevaluated, unevaluatedNormal);
    }

    static void printBlock(String tag, Result r, boolean guarded) {
        System.out.printf("[%s] %s%n", tag, r.label());
        if (r.killed()) {
            System.out.printf("  처리 %d/%d건, 킬스위치 발동=true (%d건째에서 중단)%n",
                    r.processed(), r.total(), r.killedAt());
        } else {
            System.out.printf("  처리 %d/%d건, 킬스위치 발동=false%n", r.processed(), r.total());
        }
        System.out.printf("  접수: 정상 %d건, 비정상 %d건%n", r.acceptedNormal(), r.acceptedBad());
        if (guarded) {
            System.out.printf("  유한성 가드가 거부: Infinity %d건, NaN %d건%n", r.guardInf(), r.guardNaN());
        } else {
            System.out.printf("  거부(상하한 비교): Infinity %d건, 유한값 %d건, NaN %d건%n",
                    r.rejectedInf(), r.rejectedRange(), r.rejectedNaN());
        }
        System.out.printf("  평가되지 않고 남은 주문: %d건 (그중 정상 %d건 = 킬스위치 부수 피해)%n%n",
                r.unevaluated(), r.unevaluatedNormal());
    }

    static List<Order> orderedBook() {
        List<Order> book = new ArrayList<>();
        for (int i = 0; i < 100; i++) book.add(new Order("N" + i, 100.0, 3.0, 30.0)); // px=110.0, 상한 경계 내
        for (int i = 0; i < 10; i++)  book.add(new Order("I" + i, 100.0, 1.5, 0.0));  // Infinity
        for (int i = 0; i < 10; i++)  book.add(new Order("Z" + i, 100.0, 0.0, 0.0));  // NaN
        return book;
    }

    /** 같은 120건을 고정 시드로 섞는다. 시드를 박아 두어 몇 번 돌려도 같은 순서가 나온다. */
    static List<Order> mixedBook(long seed) {
        List<Order> book = new ArrayList<>(orderedBook());
        Collections.shuffle(book, new Random(seed));
        return book;
    }

    public static void main(String[] args) {
        final double lower = 90.0, upper = 130.0;
        final long seed = 20131212L; // 사건 발생일

        // 1) 0으로 나눈 값이 실제로 무엇이 되는지, 검증식에서 어떻게 행동하는지 관측
        double inf = price(new Order("INF", 100.0, 1.5, 0.0)); // 분자 != 0
        double nan = price(new Order("NAN", 100.0, 0.0, 0.0)); // 분자 == 0
        System.out.println("== 0으로 나눈 결과와 검증식 행동 ==");
        System.out.printf("  Infinity 주문가 = %s | (px>upper)=%b (px<lower)=%b -> 거부됨%n",
                inf, inf > upper, inf < lower);
        System.out.printf("  NaN      주문가 = %s | (px>upper)=%b (px<lower)=%b -> 둘 다 false라 안 걸림%n",
                nan, nan > upper, nan < lower);
        System.out.println();

        // 2) 배치 두 가지. 정렬 = 정상 100 -> Infinity 10 -> NaN 10, 섞음 = 같은 120건을 고정 시드로 섞은 것
        List<Order> ordered = orderedBook();
        List<Order> mixed = mixedBook(seed);

        // 3) 버그 검증으로 접수. 접수된 것을 값 종류로 가르는 카운터는 아래 해소 조건과 같은 코드다.
        Result buggy = run("버그 검증 · 정렬 배치", ordered, Hanmac::acceptBuggy, false, lower, upper);
        System.out.println("== 버그 검증 결과 (총 " + ordered.size() + "건) ==");
        System.out.printf("  접수: 정상 %d건, 비정상(NaN/Inf) %d건  <- 비정상이 시장에 나간다%n%n",
                buggy.acceptedNormal(), buggy.acceptedBad());

        // 4) 해소 검증. 킬스위치 켬/끔 × 정렬/섞은 배치 네 조건으로 나눠, 무엇이 무엇을 막았는지 가른다.
        System.out.println("== 해소 검증 조건별 결과 (임계값 " + KILL_THRESHOLD + "건, 섞음 시드 " + seed + ") ==");
        System.out.println();
        Result a = run("유한성 가드 + 킬스위치 · 정렬 배치", ordered, Hanmac::acceptFixed, true, lower, upper);
        printBlock("조건 A", a, true);
        Result b = run("유한성 가드 단독(킬스위치 끔) · 정렬 배치", ordered, Hanmac::acceptFixed, false, lower, upper);
        printBlock("조건 B", b, true);
        Result c = run("유한성 가드 + 킬스위치 · 섞은 배치", mixed, Hanmac::acceptFixed, true, lower, upper);
        printBlock("조건 C", c, true);
        Result d = run("유한성 가드 단독(킬스위치 끔) · 섞은 배치", mixed, Hanmac::acceptFixed, false, lower, upper);
        printBlock("조건 D", d, true);

        // 5) 요약. 숫자를 앞에 두어 라벨 길이와 무관하게 열이 맞게 한다.
        System.out.println("== 요약 (비정상 접수 / 가드가 거부한 Inf + NaN / 정상 접수 / 정상 부수 차단) ==");
        System.out.printf("  %2d /   -  +  -  / %3d / %3d   버그 검증 · 정렬 배치%n",
                buggy.acceptedBad(), buggy.acceptedNormal(), buggy.unevaluatedNormal());
        summaryRow(a, "조건 A 가드 + 킬스위치 · 정렬 배치");
        summaryRow(b, "조건 B 가드 단독 · 정렬 배치");
        summaryRow(c, "조건 C 가드 + 킬스위치 · 섞은 배치");
        summaryRow(d, "조건 D 가드 단독 · 섞은 배치");
    }

    static void summaryRow(Result r, String label) {
        System.out.printf("  %2d /  %2d  + %2d  / %3d / %3d   %s%n",
                r.acceptedBad(), r.guardInf(), r.guardNaN(),
                r.acceptedNormal(), r.unevaluatedNormal(), label);
    }
}
