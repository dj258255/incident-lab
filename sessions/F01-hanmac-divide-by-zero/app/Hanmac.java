import java.util.ArrayList;
import java.util.List;

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
 */
public class Hanmac {

    record Order(String id, double base, double numerator, double days) {}

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
        if (!Double.isFinite(px)) return false; // NaN/Infinity 즉시 거부
        if (px > upper || px < lower) return false;
        return true;
    }

    public static void main(String[] args) {
        final double lower = 90.0, upper = 130.0;

        // 1) 0으로 나눈 값이 실제로 무엇이 되는지, 검증식에서 어떻게 행동하는지 관측
        double inf = price(new Order("INF", 100.0, 1.5, 0.0)); // 분자 != 0
        double nan = price(new Order("NAN", 100.0, 0.0, 0.0)); // 분자 == 0
        System.out.println("== 0으로 나눈 결과와 검증식 행동 ==");
        System.out.printf("  Infinity 주문가 = %s | (px>upper)=%b (px<lower)=%b -> 거부됨%n",
                inf, inf > upper, inf < lower);
        System.out.printf("  NaN      주문가 = %s | (px>upper)=%b (px<lower)=%b -> 둘 다 false라 안 걸림%n",
                nan, nan > upper, nan < lower);
        System.out.println();

        // 2) 배치: 정상 100건 + Infinity 유발 10건 + NaN 유발 10건
        List<Order> book = new ArrayList<>();
        for (int i = 0; i < 100; i++) book.add(new Order("N" + i, 100.0, 3.0, 30.0)); // px=110.0, 상한 경계 내
        for (int i = 0; i < 10; i++)  book.add(new Order("I" + i, 100.0, 1.5, 0.0));  // Infinity
        for (int i = 0; i < 10; i++)  book.add(new Order("Z" + i, 100.0, 0.0, 0.0));  // NaN

        // 3) 버그 검증으로 접수
        int okNormal = 0, okBad = 0;
        for (Order o : book) {
            double px = price(o);
            if (acceptBuggy(px, lower, upper)) {
                if (Double.isFinite(px)) okNormal++; else okBad++;
            }
        }
        System.out.println("== 버그 검증 결과 (총 " + book.size() + "건) ==");
        System.out.printf("  접수: 정상 %d건, 비정상(NaN/Inf) %d건  <- 비정상이 시장에 나간다%n%n", okNormal, okBad);

        // 4) 해소 검증(유한성 가드) + 킬스위치: 비정상 3건 감지 시 접수 중단
        int fixNormal = 0, fixBad = 0, rejectedNonFinite = 0;
        boolean killed = false;
        int processed = 0;
        for (Order o : book) {
            processed++;
            double px = price(o);
            if (!Double.isFinite(px)) {
                rejectedNonFinite++;
                if (rejectedNonFinite >= 3 && !killed) { // 킬스위치
                    killed = true;
                    System.out.printf("  [킬스위치] 비정상 주문 %d건 감지 -> %d/%d건 처리 지점에서 접수 중단%n",
                            rejectedNonFinite, processed, book.size());
                    break;
                }
                continue;
            }
            if (acceptFixed(px, lower, upper)) fixNormal++;
        }
        System.out.println("== 해소 검증(유한성 가드 + 킬스위치) 결과 ==");
        System.out.printf("  접수: 정상 %d건, 비정상 %d건 | 비정상 거부 %d건, 킬스위치 발동=%b%n",
                fixNormal, fixBad, rejectedNonFinite, killed);
    }
}
