import java.math.BigDecimal;
import java.math.RoundingMode;

/**
 * F09 IB 2020 음수 유가 재현: 파싱·표시 계층과 증거금 계층.
 *
 * 저장 계층은 app/sql 의 Postgres CHECK 제약으로 따로 재현한다.
 * 이 프로그램은 그 뒤의 두 계층만 다룬다.
 *
 * CFTC Docket No. 21-19 가 말하는 메커니즘은 두 갈래다.
 *   (1) 음수 가격을 시스템이 받지 못해 계좌 평가액이 과대계상됐고 자동 청산이 걸리지 않았다.
 *   (2) 요구증거금이 min(계약 명목가치, 하우스 증거금) 구조라 가격이 0에 가까워지자
 *       명목가치까지 함께 붕괴했고, 원문 표현으로 "3배 넘는 계약을 열 수 있었다".
 * 아래 코드는 그 구조를 축소해 옮긴 것이고, 실제 IB 시스템의 구현이 아니다.
 * 증거금 파라미터 넷 중 하우스 증거금만 명령서에 근거가 있다.
 * 원문은 "On April 20, 2020, the initial house margin for long WTI was $8,462.50 per contract." 이고
 * 여기서는 8,000 으로 반올림해 쓴다. 계약승수·자본·유지증거금 비율은 우리가 고른 값이다.
 * 8,462.50 을 그대로 넣으면 붕괴 분기점이 8.4625, 기준 수량이 11계약이 되고 배수가 그만큼 커진다.
 * 분기점 아래 구간은 min 이 명목가치를 고르므로 1,000계약·10,000계약과 과대계상 폭은 그대로다.
 * 아래 출력의 "우리가 고른 값" 라벨은 기록된 실행 출력과 맞추려고 그대로 둔다.
 */
public class NegativePrice {

    // ---- 파라미터. 하우스 증거금만 CFTC 문서 근거가 있고 나머지는 우리가 골랐다 ----
    static final BigDecimal MULTIPLIER   = new BigDecimal("1000");   // 계약당 배럴
    static final BigDecimal HOUSE_MARGIN = new BigDecimal("8000");   // 계약당 하우스 증거금(달러). 명령서 $8,462.50 을 반올림
    static final BigDecimal EQUITY       = new BigDecimal("100000"); // 계좌 자본(달러)
    static final BigDecimal MAINT_RATIO  = new BigDecimal("0.75");   // 유지증거금 = 요구증거금의 75%

    // 합성 하강 틱 10건. 마지막 -37.63 만 CFTC Docket 21-19 의 수치다.
    static final String[] TICKS = {
        "20.00", "10.00", "5.00", "1.00", "0.10", "0.01", "0.00", "-1.00", "-10.00", "-37.63"
    };

    // 증거금 표에 쓸 가격 사다리
    static final String[] LADDER = {
        "60.00", "20.00", "10.00", "8.00", "5.00", "2.70", "1.00", "0.10", "0.01", "0.00", "-37.63"
    };

    public static void main(String[] args) {
        System.out.println("== F09 음수 유가 재현: 가격이 양수라는 가정이 계층마다 다르게 깨진다 (JDK "
                + System.getProperty("java.version") + ") ==");
        System.out.println("틱 10건은 코드로 만든 하강 경로다. 마지막 -37.63 만 CFTC Docket 21-19 의 수치이고 나머지는 합성값이다.");
        System.out.println("저장 계층(CHECK 제약)은 app/sql 에서 Postgres 로 따로 잰다. 여기서는 파싱·표시 계층과 증거금 계층만 본다.");
        System.out.println();

        parsingLayer();
        System.out.println();
        marginLayer();
        System.out.println();
        liquidationLayer();
        System.out.println();
        fixedParsingLayer();
        System.out.println();
        fixedMarginLayer();
        System.out.println();
        fixedLiquidationLayer();
    }

    // ================= 파싱·표시 계층 =================

    record Res(BigDecimal px, String err) {}

    /** 시세 전문의 가격 필드. 가격을 100배 한 정수 문자열로 실어 보낸다. */
    static String field(String price) {
        return new BigDecimal(price).movePointRight(2).setScale(0).toPlainString();
    }

    /** P1 부호를 허용하지 않는 정수 파서. 예외를 던지고 멈춘다. */
    static Res p1(String f) {
        try {
            return new Res(BigDecimal.valueOf(Integer.parseUnsignedInt(f), 2), null);
        } catch (NumberFormatException e) {
            return new Res(null, e.getClass().getName() + ": " + e.getMessage());
        }
    }

    /** P2 숫자가 아닌 문자를 잡음으로 보고 걷어내는 방어적 파서. 부호까지 걷어낸다. */
    static Res p2(String f) {
        try {
            return new Res(BigDecimal.valueOf(Integer.parseInt(f.replaceAll("[^0-9]", "")), 2), null);
        } catch (NumberFormatException e) {
            return new Res(null, e.getClass().getName() + ": " + e.getMessage());
        }
    }

    /** P3 32비트 정수 필드를 부호 없는 값으로 넓히는 바이너리 피드 디코더. */
    static Res p3(String f) {
        try {
            return new Res(BigDecimal.valueOf(Integer.toUnsignedLong(Integer.parseInt(f)), 2), null);
        } catch (NumberFormatException e) {
            return new Res(null, e.getClass().getName() + ": " + e.getMessage());
        }
    }

    /** 해소 파서. 부호를 명시적으로 허용하고 재직렬화 왕복으로 원본과 대조한다. */
    static Res pFixed(String f) {
        if (!f.matches("-?\\d{1,9}")) return new Res(null, "형식 위반으로 거부: " + f);
        BigDecimal px = BigDecimal.valueOf(Long.parseLong(f), 2);
        String back = px.movePointRight(2).setScale(0).toPlainString();
        if (!back.equals(f)) return new Res(null, "왕복 불일치로 거부: " + f + " -> " + back);
        return new Res(px, null);
    }

    static final String[] SHOWN = {"20.00", "0.01", "0.00", "-1.00", "-37.63"};

    static void parsingLayer() {
        System.out.println("[버그 2] 파싱·표시 계층: 부호를 상정하지 않은 파서 3종에 같은 틱을 넣는다");
        System.out.println("  P1 부호 없는 정수 파서 | P2 숫자만 남기는 방어적 파서 | P3 32비트 무부호 확장 디코더");
        System.out.println();
        System.out.println("  " + padR("실제 틱", 10) + padR("전문 필드", 12)
                + padR("P1", 12) + padR("P2", 12) + "P3");
        System.out.println("  " + "-".repeat(62));
        for (String t : SHOWN) {
            String f = field(t);
            System.out.println("  " + padR(t, 10) + padR(f, 12)
                    + padR(show(p1(f)), 12) + padR(show(p2(f)), 12) + show(p3(f)));
        }
        System.out.println();
        summary("P1", NegativePrice::p1);
        summary("P2", NegativePrice::p2);
        summary("P3", NegativePrice::p3);
        System.out.println("  P1 예외 원문: " + p1(field("-37.63")).err());
    }

    static String show(Res r) {
        return r.err() != null ? "예외 발생" : money(r.px());
    }

    static String money(BigDecimal v) {
        return (v.signum() < 0 ? "-$" : "$") + String.format("%,.2f", v.abs());
    }

    interface Parser { Res parse(String f); }

    static void summary(String name, Parser p) {
        int ok = 0, thrown = 0, silent = 0;
        String example = "";
        for (String t : TICKS) {
            Res r = p.parse(field(t));
            if (r.err() != null) {
                thrown++;
            } else if (r.px().compareTo(new BigDecimal(t)) == 0) {
                ok++;
            } else {
                silent++;
                if (t.equals("-37.63")) example = " (-37.63 -> " + money(r.px()) + ")";
            }
        }
        System.out.println("  " + name + " 틱 10건 중 일치 " + ok + "건, 예외 " + thrown
                + "건, 예외 없이 값이 틀린 것 " + silent + "건" + example);
    }

    static void fixedParsingLayer() {
        System.out.println("[해소 2] 파싱: 부호를 명시적으로 허용하고 재직렬화 왕복으로 대조한다");
        System.out.println();
        System.out.println("  " + padR("실제 틱", 10) + padR("전문 필드", 12) + "해소 파서");
        System.out.println("  " + "-".repeat(38));
        for (String t : SHOWN) {
            String f = field(t);
            System.out.println("  " + padR(t, 10) + padR(f, 12) + show(pFixed(f)));
        }
        System.out.println();
        summary("해소 파서", NegativePrice::pFixed);
        System.out.println("  참고: 단위를 100배 틀린 전문 -376300 은 왕복 검증을 통과하므로 저장 계층의 도메인 하한이 따로 막아야 한다"
                + " -> " + show(pFixed("-376300")));
    }

    // ================= 증거금 계층 =================

    static BigDecimal notional(BigDecimal price) {
        return price.multiply(MULTIPLIER);
    }

    /** 버그: 요구증거금 = min(계약 명목가치, 하우스 증거금) */
    static BigDecimal reqBuggy(BigDecimal price) {
        return notional(price).min(HOUSE_MARGIN);
    }

    /** 해소 A: 명목가치에 연동하지 않고 하우스 증거금을 하한으로 고정한다 */
    static BigDecimal reqFixedFloor(BigDecimal price) {
        return HOUSE_MARGIN;
    }

    /** 해소 B: 가격 수준이 아니라 관측된 변동폭에 연동한다 */
    static BigDecimal reqFixedVol(BigDecimal price) {
        return HOUSE_MARGIN.max(swing().multiply(MULTIPLIER));
    }

    /** 틱 10건에서 관측된 최대 변동폭 */
    static BigDecimal swing() {
        BigDecimal hi = new BigDecimal(TICKS[0]), lo = new BigDecimal(TICKS[0]);
        for (String t : TICKS) {
            BigDecimal v = new BigDecimal(t);
            hi = hi.max(v);
            lo = lo.min(v);
        }
        return hi.subtract(lo);
    }

    static long baseline = -1;

    static String contracts(BigDecimal req) {
        if (req.signum() <= 0) return "제한없음";
        return String.format("%,d", EQUITY.divide(req, 0, RoundingMode.DOWN).longValue());
    }

    static String ratio(BigDecimal req) {
        if (req.signum() <= 0) return "-";
        long n = EQUITY.divide(req, 0, RoundingMode.DOWN).longValue();
        return String.format("%.2f배", (double) n / baseline);
    }

    interface Rule { BigDecimal req(BigDecimal price); }

    static void marginTable(Rule rule) {
        System.out.println("  " + padR("가격", 10) + padL("명목가치", 14) + padL("요구증거금", 14)
                + padL("개설가능 계약수", 18) + padL("기준 대비", 12));
        System.out.println("  " + "-".repeat(68));
        for (String p : LADDER) {
            BigDecimal px = new BigDecimal(p);
            BigDecimal req = rule.req(px);
            System.out.println("  " + padR(p, 10)
                    + padL(String.format("%,.2f", notional(px)), 14)
                    + padL(String.format("%,.2f", req), 14)
                    + padL(contracts(req), 18)
                    + padL(ratio(req), 12));
        }
    }

    static void marginLayer() {
        baseline = EQUITY.divide(reqBuggy(new BigDecimal("60.00")), 0, RoundingMode.DOWN).longValue();
        System.out.println("[버그 3] 증거금 계층: 요구증거금 = min(계약 명목가치, 하우스 증거금)");
        System.out.println("  파라미터(우리가 고른 값): 계약승수 " + String.format("%,.0f", MULTIPLIER)
                + "배럴, 하우스 증거금 $" + String.format("%,.2f", HOUSE_MARGIN)
                + "/계약, 계좌 자본 $" + String.format("%,.2f", EQUITY));
        System.out.println("  기준은 가격 60.00달러에서의 개설가능 " + baseline + "계약이다.");
        System.out.println();
        marginTable(NegativePrice::reqBuggy);
        System.out.println();
        System.out.println("  명목가치가 하우스 증거금 아래로 내려가는 분기점은 가격 8.00달러다. 그 아래부터 요구증거금이 가격을 따라 붕괴한다.");
        System.out.println("  가격 2.70달러에서 개설가능 계약수가 기준의 3배를 넘고, 0.01달러에서는 " + contracts(reqBuggy(new BigDecimal("0.01")))
                + "계약까지 열린다.");
        System.out.println("  가격 0.00달러에서는 요구증거금이 0이라 계약 수 제한 자체가 사라진다.");
        System.out.println("  맨 아랫줄은 음수 틱이 증거금 엔진까지 도달했을 때 우리 모델이 내는 값이다. CFTC 문서가 말한 경로는 아니다.");
        System.out.println("  원문이 말한 경로는 음수 틱이 애초에 거부되는 쪽이고, 그것은 [버그 4] 에서 잰다.");
    }

    static void fixedMarginLayer() {
        System.out.println("[해소 3] 증거금: 명목가치 연동을 끊는다");
        System.out.println();
        System.out.println("  해소 A: 요구증거금 = 하우스 증거금 고정(명목가치 비연동)");
        marginTable(NegativePrice::reqFixedFloor);
        System.out.println();
        System.out.println("  해소 B: 요구증거금 = max(하우스 증거금, 관측 변동폭 " + String.format("%,.2f", swing())
                + " x 계약승수 " + String.format("%,.0f", MULTIPLIER) + "배럴)");
        System.out.println("    가격 사다리 전 구간에서 요구증거금 "
                + String.format("%,.2f", reqFixedVol(BigDecimal.ZERO))
                + ", 개설가능 " + contracts(reqFixedVol(BigDecimal.ZERO)) + "계약으로 고정된다. 가격 수준을 아예 보지 않는다.");
    }

    // ================= 평가액과 자동 청산 =================

    static final BigDecimal ENTRY = new BigDecimal("0.10");
    static final BigDecimal REAL  = new BigDecimal("-37.63");
    static final BigDecimal STALE = new BigDecimal("0.01"); // 저장 계층이 거부하고 남긴 마지막 양수 틱

    static BigDecimal equityAt(BigDecimal price, long qty) {
        return EQUITY.add(price.subtract(ENTRY).multiply(MULTIPLIER).multiply(BigDecimal.valueOf(qty)));
    }

    static void liquidationLayer() {
        long qty = EQUITY.divide(reqBuggy(ENTRY), 0, RoundingMode.DOWN).longValue();
        BigDecimal maint = reqBuggy(STALE).multiply(MAINT_RATIO).multiply(BigDecimal.valueOf(qty));
        BigDecimal seen = equityAt(STALE, qty);
        BigDecimal real = equityAt(REAL, qty);

        System.out.println("[버그 4] 음수 틱이 거부되면 평가액이 과대계상되어 자동 청산이 걸리지 않는다");
        System.out.println("  계좌: 가격 " + ENTRY + "달러에서 " + String.format("%,d", qty)
                + "계약 매수(요구증거금이 계약당 " + money(reqBuggy(ENTRY)) + "까지 내려가 자본 전액으로 열린 수량이다)");
        System.out.println("  유지증거금 = 요구증거금의 75% = " + money(maint) + " (두 경우 모두 같은 값을 쓴다)");
        System.out.println();
        System.out.println("  시스템이 보는 가격 " + STALE + "달러 (음수 틱이 거부되고 남은 마지막 양수 틱)");
        System.out.println("    계좌 순자산 " + money(seen) + " > 유지증거금 " + money(maint)
                + " -> 자동 청산 발동=" + (seen.compareTo(maint) < 0));
        System.out.println("  실제 가격 " + REAL + "달러");
        System.out.println("    계좌 순자산 " + money(real) + " < 유지증거금 " + money(maint)
                + " -> 자동 청산 발동=" + (real.compareTo(maint) < 0));
        System.out.println("  평가액 과대계상 폭 " + money(seen.subtract(real)));
    }

    static void fixedLiquidationLayer() {
        System.out.println("[해소 4] 같은 시나리오를 해소 규칙으로 다시 연다");
        System.out.println("  " + padR("규칙", 38) + padL("가격 0.10에서 개설가능", 24) + padL("-37.63 마감 시 계좌 순자산", 30));
        System.out.println("  " + "-".repeat(92));
        report("버그: min(명목가치, 하우스 증거금)", NegativePrice::reqBuggy);
        report("해소 A: 하우스 증거금 고정", NegativePrice::reqFixedFloor);
        report("해소 B: 변동폭 연동", NegativePrice::reqFixedVol);
        System.out.println();
        long qtyA = EQUITY.divide(reqFixedFloor(ENTRY), 0, RoundingMode.DOWN).longValue();
        BigDecimal maintA = reqFixedFloor(REAL).multiply(MAINT_RATIO).multiply(BigDecimal.valueOf(qtyA));
        BigDecimal realA = equityAt(REAL, qtyA);
        System.out.println("  해소 뒤에는 -37.63 이 저장·파싱되므로 평가액이 실제와 같아진다.");
        System.out.println("    해소 A 기준: 순자산 " + money(realA) + " < 유지증거금 " + money(maintA)
                + " -> 자동 청산 발동=" + (realA.compareTo(maintA) < 0));
    }

    static void report(String name, Rule rule) {
        long qty = EQUITY.divide(rule.req(ENTRY), 0, RoundingMode.DOWN).longValue();
        System.out.println("  " + padR(name, 38)
                + padL(String.format("%,d", qty) + "계약", 24)
                + padL(money(equityAt(REAL, qty)), 30));
    }

    // ================= 표 정렬 도우미 (한글은 두 칸으로 센다) =================

    static int dw(String s) {
        int w = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            boolean wide = (c >= 0x1100 && c <= 0x115F)
                    || (c >= 0x2E80 && c <= 0xA4CF)
                    || (c >= 0xAC00 && c <= 0xD7A3)
                    || (c >= 0xF900 && c <= 0xFAFF)
                    || (c >= 0xFE30 && c <= 0xFE6F)
                    || (c >= 0xFF00 && c <= 0xFF60)
                    || (c >= 0xFFE0 && c <= 0xFFE6);
            w += wide ? 2 : 1;
        }
        return w;
    }

    static String padR(String s, int w) {
        return s + " ".repeat(Math.max(0, w - dw(s)));
    }

    static String padL(String s, int w) {
        return " ".repeat(Math.max(0, w - dw(s))) + s;
    }
}
