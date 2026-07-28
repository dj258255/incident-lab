package lab;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

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
 * 정상 100 + Infinity 유발 10 + NaN 유발 10을, 세 엔드포인트에 각각 보내 상태코드로 집계한다.
 * 최소 재현(Hanmac.java)과 같은 구성/순서라 두 결과가 맞물리는지 대조할 수 있다.
 */
@Component
public class Driver implements ApplicationRunner {

    private enum Type { NORMAL, INF, NAN }

    private record Ord(Type type, double base, double num, double days) {}

    private final ConfigurableApplicationContext ctx;
    private final RestClient client = RestClient.builder().baseUrl("http://localhost:8080").build();

    public Driver(ConfigurableApplicationContext ctx) {
        this.ctx = ctx;
    }

    private static List<Ord> book() {
        List<Ord> b = new ArrayList<>();
        for (int i = 0; i < 100; i++) b.add(new Ord(Type.NORMAL, 100.0, 3.0, 30.0)); // px=110.0
        for (int i = 0; i < 10; i++)  b.add(new Ord(Type.INF, 100.0, 1.5, 0.0));      // Infinity
        for (int i = 0; i < 10; i++)  b.add(new Ord(Type.NAN, 100.0, 0.0, 0.0));      // NaN
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
        List<Ord> book = book();

        // 1) 버그 엔드포인트
        int buggyNormal = 0, buggyNan = 0, buggyInfRejected = 0;
        for (Ord o : book) {
            int st = status("/orders/buggy", o);
            if (st == 201) {
                if (o.type() == Type.NORMAL) buggyNormal++; else buggyNan++;
            } else if (st == 422) {
                buggyInfRejected++;
            }
        }

        // 2) BigDecimal 강화 시도
        int bdCreated = 0, bdServerError = 0;
        for (Ord o : book) {
            int st = status("/orders/bigdecimal", o);
            if (st == 201) bdCreated++;
            else if (st == 500) bdServerError++;
        }

        // 3) 해소 엔드포인트 (유한성 가드 + 킬스위치). 정상 100건이 먼저, 비정상이 뒤에 온다.
        int fixCreated = 0, fixRejected = 0, fixKillswitch = 0;
        for (Ord o : book) {
            int st = status("/orders/fixed", o);
            if (st == 201) fixCreated++;
            else if (st == 422) fixRejected++;
            else if (st == 503) fixKillswitch++;
        }

        System.out.println();
        System.out.println("== [Spring] 실제 주문접수 API 재현 (POST /orders, 내장 Tomcat + Jackson + @Valid) ==");
        System.out.printf("  /orders/buggy      : 201 접수 %d건 (정상 %d + NaN %d), 422 거부 %d건 (Infinity는 상한 초과)%n",
                buggyNormal + buggyNan, buggyNormal, buggyNan, buggyInfRejected);
        System.out.printf("  /orders/bigdecimal : 201 접수 %d건, 500 서버오류 %d건 (BigDecimal.valueOf(NaN/Inf) 예외)%n",
                bdCreated, bdServerError);
        System.out.printf("  /orders/fixed      : 201 접수 %d건, 422 거부 %d건, 503 킬스위치 %d건 (비정상 3건에서 발동)%n",
                fixCreated, fixRejected, fixKillswitch);
        System.out.println("  입력 @Valid 검증은 전부 통과했다. 문제는 입력이 아니라 서버가 계산한 파생값이다.");

        System.exit(SpringApplication.exit(ctx, () -> 0));
    }
}
