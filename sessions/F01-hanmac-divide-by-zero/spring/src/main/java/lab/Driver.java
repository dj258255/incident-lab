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

        System.exit(SpringApplication.exit(ctx, () -> 0));
    }
}
