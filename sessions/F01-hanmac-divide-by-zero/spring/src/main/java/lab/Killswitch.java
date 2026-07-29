package lab;

import java.util.concurrent.atomic.AtomicInteger;

import org.springframework.stereotype.Component;

/**
 * 두 번째 방어선. 개별 거부만으로는 부족하다는 것이 한맥 사고의 교훈이라,
 * 비정상 값이 임계치를 넘으면 접수 자체를 멈춘다. 임계값 3은 시연용이다.
 */
@Component
public class Killswitch {
    private static final int THRESHOLD = 3;
    private final AtomicInteger nonFinite = new AtomicInteger(0);
    private volatile boolean tripped = false;

    /** 비정상 값 1건을 기록하고, 누적 건수를 돌려준다. 임계치에 닿으면 발동한다. */
    public int record() {
        int count = nonFinite.incrementAndGet();
        if (count >= THRESHOLD) {
            tripped = true;
        }
        return count;
    }

    public boolean tripped() {
        return tripped;
    }

    /**
     * 조건을 바꿔 다시 재기 위해 상태를 되돌린다. 드라이버가 배치 하나를 다 쏜 뒤 호출한다.
     * 운영용 기능이 아니라 측정용이다.
     */
    public void reset() {
        nonFinite.set(0);
        tripped = false;
    }
}
