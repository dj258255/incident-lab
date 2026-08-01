package lab;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Random;

import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

/**
 * 내장 Tomcat이 뜬 뒤 자기 자신의 REST 엔드포인트로 주문 120건을 실제 HTTP로 쏜다.
 * 정상 100 + Infinity 유발 10 + NaN 유발 10을, 엔드포인트별로 보내 상태코드로 집계한다.
 * 최소 재현(Hanmac.java)과 같은 구성/순서/시드라 두 결과가 맞물리는지 대조할 수 있다.
 *
 * 2026-07-29 재측정: 응답을 값 종류별로 갈라 세고, 킬스위치 켬/끔 × 정렬/섞은 배치 네 조건을
 * 돌린다. 조건 사이에는 Killswitch를 되돌린다. 무엇을 가드가 막고 무엇을 킬스위치가 막았는지
 * 갈라내기 위한 구성이다.
 */
@Component
public class Driver implements ApplicationRunner {

    private enum Type { NORMAL, INF, NAN }

    private record Ord(Type type, double base, double num, double days) {}

    /** 상태코드 버킷. */
    private static final int CREATED = 0, REJECTED = 1, SERVER_ERROR = 2, KILLED = 3;

    private static final long SEED = 20131212L; // 사건 발생일

    private final ConfigurableApplicationContext ctx;
    private final Killswitch killswitch;
    private final RestClient client = RestClient.builder().baseUrl("http://localhost:8080").build();

    public Driver(ConfigurableApplicationContext ctx, Killswitch killswitch) {
        this.ctx = ctx;
        this.killswitch = killswitch;
    }

    private static List<Ord> orderedBook() {
        List<Ord> b = new ArrayList<>();
        for (int i = 0; i < 100; i++) b.add(new Ord(Type.NORMAL, 100.0, 3.0, 30.0)); // px=110.0
        for (int i = 0; i < 10; i++)  b.add(new Ord(Type.INF, 100.0, 1.5, 0.0));      // Infinity
        for (int i = 0; i < 10; i++)  b.add(new Ord(Type.NAN, 100.0, 0.0, 0.0));      // NaN
        return b;
    }

    /**
     * NaN 만 섞은 배치. 가드에 구멍이 있는 조건의 대조에 반드시 필요하다.
     *
     * 처음에는 orderedBook() 으로 조건 E 와 F 를 재고 둘이 같은 결과를 냈다.
     * 이유는 Infinity 10건이 NaN 보다 먼저 오기 때문이다. 구멍 난 가드도 Infinity 는
     * 잡으므로 그때 killswitch.record() 가 불려 임계값에 닿고, 뒤따르는 NaN 이
     * 킬스위치에 막힌다. **가드가 못 잡는 값을 킬스위치가 막은 것이 아니라
     * 다른 종류의 비정상이 먼저 와서 대신 켜 준 것이다.**
     * 그 우연을 걷어내려면 가드가 아무것도 못 잡는 배치가 필요하다.
     */
    private static List<Ord> nanOnlyBook() {
        List<Ord> b = new ArrayList<>();
        for (int i = 0; i < 100; i++) b.add(new Ord(Type.NORMAL, 100.0, 3.0, 30.0));
        for (int i = 0; i < 20; i++)  b.add(new Ord(Type.NAN, 100.0, 0.0, 0.0));
        return b;
    }

    /** 같은 120건을 고정 시드로 섞는다. 최소 재현과 같은 시드다. */
    private static List<Ord> mixedBook() {
        List<Ord> b = new ArrayList<>(orderedBook());
        Collections.shuffle(b, new Random(SEED));
        return b;
    }

    private int status(String path, Ord o) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("base", o.base());
        body.put("numerator", o.num());
        body.put("days", o.days());
        ResponseEntity<String> res = client.post().uri(path)
                .contentType(MediaType.APPLICATION_JSON)
                .body(body)
                .exchange((req, resp) -> ResponseEntity
                        .status(resp.getStatusCode())
                        .body(new String(resp.getBody().readAllBytes(), StandardCharsets.UTF_8)));
        return res.getStatusCode().value();
    }

    /** 배치 하나를 엔드포인트에 쏘고, [값 종류][상태코드 버킷]으로 집계한다. */
    private int[][] fire(String path, List<Ord> book) {
        int[][] t = new int[Type.values().length][4];
        for (Ord o : book) {
            int bucket = switch (status(path, o)) {
                case 201 -> CREATED;
                case 422 -> REJECTED;
                case 500 -> SERVER_ERROR;
                case 503 -> KILLED;
                default -> -1;
            };
            if (bucket >= 0) t[o.type().ordinal()][bucket]++;
        }
        return t;
    }

    private static int sum(int[][] t, int bucket) {
        int s = 0;
        for (int[] row : t) s += row[bucket];
        return s;
    }

    private static int of(int[][] t, Type type, int bucket) {
        return t[type.ordinal()][bucket];
    }

    private static void printCondition(String tag, String label, int[][] t) {
        System.out.printf("[%s] %s%n", tag, label);
        System.out.printf("  201 접수     %3d건 (정상 %d / Inf %d / NaN %d)%n", sum(t, CREATED),
                of(t, Type.NORMAL, CREATED), of(t, Type.INF, CREATED), of(t, Type.NAN, CREATED));
        System.out.printf("  422 거부     %3d건 (정상 %d / Inf %d / NaN %d)%n", sum(t, REJECTED),
                of(t, Type.NORMAL, REJECTED), of(t, Type.INF, REJECTED), of(t, Type.NAN, REJECTED));
        System.out.printf("  503 킬스위치 %3d건 (정상 %d / Inf %d / NaN %d)  <- 정상 %d건이 부수 피해%n%n",
                sum(t, KILLED), of(t, Type.NORMAL, KILLED), of(t, Type.INF, KILLED), of(t, Type.NAN, KILLED),
                of(t, Type.NORMAL, KILLED));
    }

    private void awaitReady() throws InterruptedException {
        for (int i = 0; i < 40; i++) {
            try {
                ResponseEntity<String> h = client.get().uri("/health")
                        .exchange((req, resp) -> ResponseEntity.status(resp.getStatusCode()).body(""));
                if (h.getStatusCode().is2xxSuccessful()) return;
            } catch (Exception ignore) {
                // 내장 서버가 아직 소켓을 열기 전
            }
            Thread.sleep(250);
        }
    }

    @Override
    public void run(ApplicationArguments args) throws Exception {
        // 서버 모드에서는 내장 드라이버를 안 돌린다. 동시 부하 실험은 밖에서 k6 로 쏘고
        // 앱은 계속 떠 있어야 한다. 기본값은 지금까지와 같은 드라이버 실행이다.
        if ("server".equalsIgnoreCase(System.getenv().getOrDefault("LAB_MODE", ""))) {
            System.out.println("[Driver] LAB_MODE=server 이므로 내장 드라이버를 건너뜁니다.");
            return;
        }
        awaitReady();
        List<Ord> ordered = orderedBook();
        List<Ord> mixed = mixedBook();

        // 1) 버그 엔드포인트
        int[][] buggy = fire("/orders/buggy", ordered);

        // 2) BigDecimal 강화 시도
        int[][] bd = fire("/orders/bigdecimal", ordered);

        // 3) 해소 엔드포인트 (유한성 가드 + 킬스위치). 정상 100건이 먼저, 비정상이 뒤에 온다.
        int[][] fixedOrdered = fire("/orders/fixed", ordered);

        // 4) 가드 단독. 킬스위치가 없으니 120건 전부가 화이트리스트의 판정을 받는다.
        killswitch.reset();
        int[][] guardOrdered = fire("/orders/guard", ordered);

        // 5) 같은 해소 엔드포인트에 섞은 배치. 킬스위치의 부수 피해를 잰다.
        killswitch.reset();
        int[][] fixedMixed = fire("/orders/fixed", mixed);

        // 6) 가드 단독 + 섞은 배치. 순서에 무관한지 확인하는 대조군이다.
        killswitch.reset();
        int[][] guardMixed = fire("/orders/guard", mixed);

        System.out.println();
        System.out.println("== [Spring] 실제 주문접수 API 재현 (POST /orders, 내장 Tomcat + Jackson + @Valid) ==");
        System.out.printf("  /orders/buggy      : 201 접수 %d건 (정상 %d + NaN %d), 422 거부 %d건 (Infinity는 상한 초과)%n",
                sum(buggy, CREATED), of(buggy, Type.NORMAL, CREATED), of(buggy, Type.NAN, CREATED),
                sum(buggy, REJECTED));
        System.out.printf("  /orders/bigdecimal : 201 접수 %d건, 500 서버오류 %d건 (BigDecimal.valueOf(NaN/Inf) 예외)%n",
                sum(bd, CREATED), sum(bd, SERVER_ERROR));
        System.out.printf("  /orders/fixed      : 201 접수 %d건, 422 거부 %d건, 503 킬스위치 %d건 (비정상 3건에서 발동)%n",
                sum(fixedOrdered, CREATED), sum(fixedOrdered, REJECTED), sum(fixedOrdered, KILLED));
        System.out.println("  입력 @Valid 검증은 전부 통과했다. 문제는 입력이 아니라 서버가 계산한 파생값이다.");
        System.out.println();

        System.out.println("== [Spring] 조건별 재측정 (가드 단독 / 킬스위치 · 정렬 / 섞은 배치, 섞음 시드 " + SEED + ") ==");
        System.out.println();
        printCondition("조건 A", "/orders/fixed · 정렬 배치 · 유한성 가드 + 킬스위치", fixedOrdered);
        printCondition("조건 B", "/orders/guard · 정렬 배치 · 유한성 가드 단독", guardOrdered);
        printCondition("조건 C", "/orders/fixed · 섞은 배치 · 유한성 가드 + 킬스위치", fixedMixed);
        printCondition("조건 D", "/orders/guard · 섞은 배치 · 유한성 가드 단독", guardMixed);

        // ── 2026-07-31 추가 ────────────────────────────────────────────
        // "못 한 것"의 두 항목을 잡는다.
        //   가드가 놓치는 값이 있을 때 킬스위치가 무엇을 건지는가
        //   임계값을 3 하나만 썼다
        System.out.println("== [Spring] 가드에 구멍이 있을 때 킬스위치가 무엇을 건지는가 ==");
        System.out.println();
        System.out.println("  앞의 조건들은 가드가 완전한 화이트리스트(isFinite)라 NaN 도 Infinity 도 다 잡습니다.");
        System.out.println("  실무의 가드는 자주 불완전합니다. isInfinite 만 확인하거나 절댓값으로 상한을 보면");
        System.out.println("  Infinity 는 걸리는데 NaN 은 두 비교가 모두 false 라 그대로 지나갑니다.");
        System.out.println("  그 조건에서 킬스위치의 탐지원이 가드와 같은지 다른지로 결과가 갈립니다.");
        System.out.println();
        List<Ord> nanOnly = nanOnlyBook();
        killswitch.reset();
        int[][] leakyOrdered = fire("/orders/leaky", ordered);
        killswitch.reset();
        int[][] leakyIndep = fire("/orders/leaky-independent", ordered);
        killswitch.reset();
        int[][] leakyNan = fire("/orders/leaky", nanOnly);
        killswitch.reset();
        int[][] leakyNanIndep = fire("/orders/leaky-independent", nanOnly);
        System.out.println("  먼저 Infinity 가 섞인 배치입니다(정상 100 + Inf 10 + NaN 10).");
        printCondition("조건 E", "/orders/leaky · 구멍 난 가드 + 가드 연동 킬스위치", leakyOrdered);
        printCondition("조건 F", "/orders/leaky-independent · 같은 가드 + 독립 탐지 킬스위치", leakyIndep);
        System.out.println("  두 조건이 같습니다. 가드가 Infinity 는 잡으므로 그때 킬스위치가 켜지고");
        System.out.println("  뒤따르는 NaN 이 막힙니다. **가드가 못 잡는 값을 킬스위치가 막은 것이 아니라");
        System.out.println("  다른 종류의 비정상이 먼저 와서 대신 켜 준 것입니다.** 그 우연을 걷어냅니다.");
        System.out.println();
        System.out.println("  이번에는 NaN 만 있는 배치입니다(정상 100 + NaN 20). 가드가 아무것도 못 잡습니다.");
        printCondition("조건 E2", "/orders/leaky · NaN 만 · 가드 연동 킬스위치", leakyNan);
        printCondition("조건 F2", "/orders/leaky-independent · NaN 만 · 독립 탐지 킬스위치", leakyNanIndep);
        System.out.printf("  조건 E2 는 NaN %d건이 접수됐습니다. 킬스위치가 세는 것이 '가드가 거부한 건수'라,%n",
                of(leakyNan, Type.NAN, CREATED));
        System.out.println("  가드가 못 잡은 값은 거부되지 않으니 킬스위치도 세지 못합니다.");
        System.out.printf("  조건 F2 는 NaN 접수 %d건입니다. 탐지원을 접수 결과(기준가 이탈)로 옮기면%n",
                of(leakyNanIndep, Type.NAN, CREATED));
        System.out.println("  가드가 무엇을 놓치든 셀 수 있습니다.");
        System.out.println();
        System.out.println("  **킬스위치의 값어치는 존재가 아니라 탐지원이 가드와 독립인가에서 나옵니다.**");
        System.out.println("  가드가 거부한 건수만 세는 킬스위치는 가드의 사본이지 두 번째 방어선이 아닙니다.");
        System.out.println();

        // 임계값 스윕. 발동까지 몇 건이 지나가는지와 정상 주문의 부수 피해를 함께 본다.
        System.out.println("== [Spring] 킬스위치 임계값 스윕 (섞은 배치, /orders/fixed) ==");
        System.out.println();
        System.out.printf("  %-8s %10s %10s %10s %14s%n",
                "임계값", "201 접수", "422 거부", "503 차단", "정상 부수 피해");
        int original = killswitch.threshold();
        for (int th : new int[]{1, 3, 5, 10, 20, 50, 999}) {
            killswitch.reset();
            killswitch.setThreshold(th);
            int[][] t = fire("/orders/fixed", mixed);
            System.out.printf("  %-8d %10d %10d %10d %14d%n",
                    th, sum(t, CREATED), sum(t, REJECTED), sum(t, KILLED),
                    of(t, Type.NORMAL, KILLED));
        }
        killswitch.setThreshold(original);
        killswitch.reset();
        System.out.println();
        System.out.println("  임계값 999 는 사실상 킬스위치를 끈 조건입니다. 가드 단독과 같아야 합니다.");
        System.out.println("  임계값을 낮출수록 비정상은 빨리 멈추고 정상 주문의 부수 피해가 커집니다.");
        System.out.println("  이 배치는 정상 100 대 비정상 20 이라 그 교환이 눈에 보입니다.");
        System.out.println("  실제 값은 도메인이 정합니다. 한맥의 경우 2분 남짓에 3만 6천 건이 나갔으므로");
        System.out.println("  부수 피해를 아끼려다 임계값을 높게 잡는 쪽이 훨씬 비쌌습니다.");

        System.exit(SpringApplication.exit(ctx, () -> 0));
    }
}
