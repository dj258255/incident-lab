package lab;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/** 실행 조건. 전부 환경변수로 덮어쓸 수 있다(compose에서 주입). */
@Component
public class Conf {

    /** direct | unbounded | bounded | conflate | terminate | combo | decorator */
    @Value("${stream.mode:direct}")
    public String mode;

    /** 초당 발행할 틱 수(전체 종목 합계). */
    @Value("${stream.tick-rate:3000}")
    public int tickRate;

    /** 종목 수. conflation의 큐 상한이 이 값이 된다. */
    @Value("${stream.symbols:20}")
    public int symbols;

    /** 틱 하나의 목표 바이트 수. 실제 호가 10단계 스냅샷 크기를 흉내 낸다. */
    @Value("${stream.payload-bytes:480}")
    public int payloadBytes;

    /** 이 수만큼 접속하면 발행을 시작한다. 모든 회차의 t=0을 같게 만들기 위한 것이다. */
    @Value("${stream.expect-clients:6}")
    public int expectClients;

    /** bounded 모드의 클라이언트별 큐 상한(메시지 수). */
    @Value("${stream.queue-capacity:1000}")
    public int queueCapacity;

    /** terminate/combo/decorator 모드의 클라이언트별 버퍼 상한(바이트). */
    @Value("${stream.buffer-limit-bytes:524288}")
    public int bufferLimitBytes;

    /** terminate/combo/decorator 모드에서 송신 한 건이 이 시간을 넘기면 절단한다(ms). */
    @Value("${stream.send-time-limit-ms:5000}")
    public int sendTimeLimitMs;

    /**
     * 버퍼 상한을 몇 초 연속으로 넘겨야 절단할지. 1이면 순간값 한 번으로 끊는다.
     * 접속 직후 워밍업 같은 일시적 적체로 정상 사용자를 끊지 않으려면 1보다 커야 한다.
     */
    @Value("${stream.over-limit-seconds:3}")
    public int overLimitSeconds;

    /** decorator 모드의 공유 송신 풀 스레드 수. */
    @Value("${stream.pool-threads:4}")
    public int poolThreads;

    /** 0보다 크면 Tomcat 블로킹 송신 제한시간을 이 값으로 바꾼다(ms). 0이면 Tomcat 기본값. */
    @Value("${stream.blocking-send-timeout-ms:0}")
    public long blockingSendTimeoutMs;

    /** 초 단위 계측 결과를 쓸 CSV 경로. */
    @Value("${stream.sample-file:/results/server.csv}")
    public String sampleFile;

    /** 회차 라벨(로그·CSV 헤더용). */
    @Value("${stream.label:run}")
    public String label;
}
