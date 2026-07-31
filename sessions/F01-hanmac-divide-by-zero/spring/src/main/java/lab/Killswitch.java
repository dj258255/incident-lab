package lab;

import java.util.concurrent.atomic.AtomicInteger;

import org.springframework.stereotype.Component;

/**
 * 두 번째 방어선. 개별 거부만으로는 부족하다는 것이 한맥 사고의 교훈이라,
 * 비정상 값이 임계치를 넘으면 접수 자체를 멈춘다.
 *
 * 2026-07-31: 임계값을 바꿔 가며 잴 수 있게 고쳤다. 원래는 3으로 고정이었고
 * "임계값도 3건 하나만 썼습니다"가 못 한 것에 남아 있었다.
 *
 * 그리고 탐지원을 둘로 나눴다. 이 구분이 이 세션에서 새로 재는 자리다.
 *   record()          가드가 거부한 건수를 센다. 가드와 같은 판정에 기댄다
 *   recordDeviation() 접수된 주문의 기준가 이탈을 센다. 가드와 독립이다
 * 가드에 구멍이 있으면 앞의 것은 아무것도 못 센다. 가드가 못 잡은 값은
 * 거부되지 않으므로 record()가 불리지 않기 때문이다.
 */
@Component
public class Killswitch {
    /** 시연용 기본값 3. -Dkillswitch.threshold 로 바꾼다. */
    private volatile int threshold = Integer.getInteger("killswitch.threshold", 3);
    private final AtomicInteger nonFinite = new AtomicInteger(0);
    private final AtomicInteger deviation = new AtomicInteger(0);
    private volatile boolean tripped = false;

    /** 가드가 거부한 비정상 값 1건을 기록한다. */
    public int record() {
        int count = nonFinite.incrementAndGet();
        if (count >= threshold) {
            tripped = true;
        }
        return count;
    }

    /**
     * 접수된 주문이 기준가에서 크게 벗어난 것을 1건 기록한다.
     * 가드가 무엇을 놓치든 접수 결과를 보므로 가드와 독립이다.
     */
    public int recordDeviation() {
        int count = deviation.incrementAndGet();
        if (count >= threshold) {
            tripped = true;
        }
        return count;
    }

    public boolean tripped() {
        return tripped;
    }

    public int threshold() {
        return threshold;
    }

    public void setThreshold(int t) {
        this.threshold = t;
    }

    /**
     * 조건을 바꿔 다시 재기 위해 상태를 되돌린다. 드라이버가 배치 하나를 다 쏜 뒤 호출한다.
     * 운영용 기능이 아니라 측정용이다.
     */
    public void reset() {
        nonFinite.set(0);
        deviation.set(0);
        tripped = false;
    }
}
