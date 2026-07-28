package lab;

import java.util.concurrent.Semaphore;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/**
 * 부하 차단기(load shedding). 동시에 DB 경로로 들어갈 수 있는 요청 수를 풀 크기에 맞춰 제한한다.
 * 자리가 없으면 기다리지 않고 즉시 실패시켜, 커넥션 획득 큐가 타임아웃까지 쌓이는 것을 막는다.
 * 증권 MTS의 가상 대기열과 같은 원리다. 전원을 다 받아 다 같이 무너지느니, 받을 만큼만 받고
 * 나머지는 빨리 돌려보내 받은 요청의 응답 시간을 지킨다.
 *
 * 논블로킹 tryAcquire를 쓰는 이유: 대기(블로킹)를 허용하면 그 대기가 다시 큐 적체가 되어
 * 문제를 미룰 뿐이다. 여기서는 "지금 처리 가능한가"만 보고 아니면 바로 흘려보낸다.
 */
@Component
public class LoadShedder {

    private final Semaphore permits;

    public LoadShedder(@Value("${mts.shed.permits:10}") int permitCount) {
        this.permits = new Semaphore(permitCount);
    }

    public boolean tryEnter() {
        return permits.tryAcquire();
    }

    public void leave() {
        permits.release();
    }
}
