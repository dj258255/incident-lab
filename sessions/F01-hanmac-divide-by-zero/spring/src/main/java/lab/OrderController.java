package lab;

import java.math.BigDecimal;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import jakarta.validation.Valid;

/**
 * 같은 검증 로직을 실제 REST 엔드포인트 네 개로 노출한다.
 *   /orders/buggy      : 순수 double 비교. NaN이 통과한다(201).
 *   /orders/bigdecimal : 정밀도를 위해 BigDecimal로 검증하려는 순진한 강화 시도.
 *   /orders/guard      : 유한성 가드만. 킬스위치 없음.
 *   /orders/leaky      : 가드가 Infinity 만 잡는 경우 + 가드 연동 킬스위치.
 *   /orders/leaky-independent : 같은 구멍 난 가드 + 탐지원이 독립인 킬스위치.
 *   /orders/fixed      : 유한성 가드 + 킬스위치.
 * 접수는 201 Created, 값 때문에 거부하면 422 Unprocessable Entity로 응답한다.
 * 킬스위치가 발동한 뒤에는 503 Service Unavailable이다.
 */
@RestController
public class OrderController {

    static final double LOWER = 90.0;
    static final double UPPER = 130.0;

    private final Killswitch killswitch;

    public OrderController(Killswitch killswitch) {
        this.killswitch = killswitch;
    }

    /** 주문가 = base * (1 + numerator/days). days==0이면 IEEE 754상 예외 없이 Infinity 또는 NaN. */
    static double price(OrderRequest o) {
        double factor = o.numerator() / o.days();
        return o.base() * (1.0 + factor);
    }

    @GetMapping("/health")
    public String health() {
        return "ok";
    }

    // (버그) 상한 초과거나 하한 미만이면 거부, 아니면 접수. NaN은 두 비교가 모두 false라 접수된다.
    @PostMapping("/orders/buggy")
    public ResponseEntity<String> buggy(@Valid @RequestBody OrderRequest o) {
        double px = price(o);
        if (px > UPPER || px < LOWER) {
            return ResponseEntity.unprocessableEntity().body("rejected px=" + px);
        }
        return ResponseEntity.status(HttpStatus.CREATED).body("accepted px=" + px);
    }

    // (순진한 강화 시도) 정밀도를 위해 BigDecimal로 비교하려다, NaN/Infinity를 BigDecimal로 바꾸는
    // 순간 NumberFormatException이 나 500이 된다. 조용한 접수가 서버 오류로 바뀔 뿐 근본 해결이 아니다.
    @PostMapping("/orders/bigdecimal")
    public ResponseEntity<String> bigdecimal(@Valid @RequestBody OrderRequest o) {
        double px = price(o);
        BigDecimal p = BigDecimal.valueOf(px); // NaN/Infinity에서 NumberFormatException
        if (p.compareTo(BigDecimal.valueOf(UPPER)) > 0 || p.compareTo(BigDecimal.valueOf(LOWER)) < 0) {
            return ResponseEntity.unprocessableEntity().body("rejected px=" + px);
        }
        return ResponseEntity.status(HttpStatus.CREATED).body("accepted px=" + px);
    }

    // (해소·가드 단독) 킬스위치 없이 유한성 화이트리스트만 둔다. /orders/fixed와 한 변수만 다르므로,
    // 두 엔드포인트를 같은 배치로 쏘면 무엇을 가드가 막고 무엇을 킬스위치가 막았는지 갈린다.
    @PostMapping("/orders/guard")
    public ResponseEntity<String> guard(@Valid @RequestBody OrderRequest o) {
        double px = price(o);
        if (!Double.isFinite(px)) {
            return ResponseEntity.unprocessableEntity().body("rejected non-finite px=" + px);
        }
        if (px > UPPER || px < LOWER) {
            return ResponseEntity.unprocessableEntity().body("rejected px=" + px);
        }
        return ResponseEntity.status(HttpStatus.CREATED).body("accepted px=" + px);
    }

    // (가드에 구멍) 화이트리스트가 Infinity 만 잡고 NaN 을 놓치는 경우.
    // 실무에서 흔한 모양이다. isInfinite 만 확인하거나 상한·하한 비교에 절댓값을 쓰면
    // Infinity 는 걸리는데 NaN 은 두 비교가 모두 false 라 그대로 지나간다.
    //
    // 여기에 킬스위치를 붙이되, 킬스위치가 세는 것은 "가드가 거부한 건수"다.
    // 가드가 못 잡은 값은 거부되지 않으므로 킬스위치도 못 센다.
    // **탐지원이 가드와 같으면 킬스위치는 가드가 놓친 것을 못 막는다.** 이것을 잰다.
    @PostMapping("/orders/leaky")
    public ResponseEntity<String> leaky(@Valid @RequestBody OrderRequest o) {
        if (killswitch.tripped()) {
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body("killswitch tripped");
        }
        double px = price(o);
        if (Double.isInfinite(px)) {                 // NaN 은 여기 안 걸린다
            int count = killswitch.record();
            return ResponseEntity.unprocessableEntity().body("rejected infinite px=" + px + " count=" + count);
        }
        if (px > UPPER || px < LOWER) {
            return ResponseEntity.unprocessableEntity().body("rejected px=" + px);
        }
        return ResponseEntity.status(HttpStatus.CREATED).body("accepted px=" + px);
    }

    // (가드에 구멍 + 독립 탐지) 같은 구멍 난 가드에, 탐지원이 다른 킬스위치를 붙인다.
    // 접수하기로 결정한 값이 기준가에서 크게 벗어났는지를 접수 직전에 본다.
    // NaN 은 어떤 비교에도 안 걸리므로 "기준가 대비 비율을 계산할 수 없는 값"으로 잡힌다.
    // 가드의 판정이 아니라 접수 결과를 보므로 가드가 무엇을 놓치든 셀 수 있다.
    @PostMapping("/orders/leaky-independent")
    public ResponseEntity<String> leakyIndependent(@Valid @RequestBody OrderRequest o) {
        if (killswitch.tripped()) {
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body("killswitch tripped");
        }
        double px = price(o);
        if (Double.isInfinite(px)) {
            killswitch.record();
            return ResponseEntity.unprocessableEntity().body("rejected infinite px=" + px);
        }
        if (px > UPPER || px < LOWER) {
            return ResponseEntity.unprocessableEntity().body("rejected px=" + px);
        }
        // 접수 직전에 기준가 이탈을 본다. ratio 가 NaN 이면 비교가 전부 false 이므로
        // "정상 범위 안"으로 판정되지 않도록 부정형이 아니라 긍정형으로 쓴다.
        double ratio = px / o.base();
        boolean withinBand = ratio >= 0.5 && ratio <= 2.0;
        if (!withinBand) {
            int count = killswitch.recordDeviation();
            return ResponseEntity.unprocessableEntity()
                    .body("rejected deviation px=" + px + " count=" + count);
        }
        return ResponseEntity.status(HttpStatus.CREATED).body("accepted px=" + px);
    }

    // (해소) 유한성 가드를 먼저 두고, 비정상이 임계치를 넘으면 킬스위치로 접수를 멈춘다.
    @PostMapping("/orders/fixed")
    public ResponseEntity<String> fixed(@Valid @RequestBody OrderRequest o) {
        if (killswitch.tripped()) {
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body("killswitch tripped");
        }
        double px = price(o);
        if (!Double.isFinite(px)) {
            int count = killswitch.record();
            return ResponseEntity.unprocessableEntity().body("rejected non-finite px=" + px + " count=" + count);
        }
        if (px > UPPER || px < LOWER) {
            return ResponseEntity.unprocessableEntity().body("rejected px=" + px);
        }
        return ResponseEntity.status(HttpStatus.CREATED).body("accepted px=" + px);
    }
}
