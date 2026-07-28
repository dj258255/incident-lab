package lab;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 시세 조회 엔드포인트 둘.
 *   /quote/buggy : 들어오는 대로 다 받는다. 풀이 마르면 커넥션 획득이 타임아웃돼 500이 난다.
 *   /quote/fixed : 부하 차단기로 동시 처리량을 제한한다. 넘치면 즉시 503으로 흘려보낸다.
 * 두 경로는 같은 풀, 같은 조회 쿼리를 쓴다. 유일한 차이는 들어올 양을 제어하는가이다.
 */
@RestController
public class QuoteController {

    private final QuoteService quotes;
    private final LoadShedder shedder;

    public QuoteController(QuoteService quotes, LoadShedder shedder) {
        this.quotes = quotes;
        this.shedder = shedder;
    }

    @GetMapping("/health")
    public String health() {
        return "ok";
    }

    @GetMapping("/quote/buggy")
    public ResponseEntity<String> buggy(@RequestParam(defaultValue = "005930") String symbol) {
        int price = quotes.lookup(symbol); // 풀 고갈 시 여기서 커넥션 타임아웃 예외 -> 500
        return ResponseEntity.ok(symbol + "=" + price);
    }

    @GetMapping("/quote/fixed")
    public ResponseEntity<String> fixed(@RequestParam(defaultValue = "005930") String symbol) {
        if (!shedder.tryEnter()) {
            // 지금 처리 여력이 없다. 2초 타임아웃까지 매달리지 않고 바로 돌려보낸다.
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                    .body("busy: 잠시 후 다시 시도해 주세요");
        }
        try {
            int price = quotes.lookup(symbol);
            return ResponseEntity.ok(symbol + "=" + price);
        } finally {
            shedder.leave();
        }
    }
}
