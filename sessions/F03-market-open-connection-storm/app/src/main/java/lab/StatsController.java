package lab;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 부하가 끝난 뒤 앱이 잰 값을 그대로 내보낸다. 이 출력은 results/에 파일로 저장한다.
 * k6가 클라이언트 쪽에서 잰 값과 나란히 놓고 봐야 계층별 몫이 갈린다.
 */
@RestController
public class StatsController {

    private final Timings timings;
    private final PoolSampler sampler;
    private final int poolSize;
    private final long connectionTimeout;
    private final int maxThreads;
    private final int acceptCount;
    private final int permits;

    public StatsController(Timings timings, PoolSampler sampler,
                           @Value("${spring.datasource.hikari.maximum-pool-size}") int poolSize,
                           @Value("${spring.datasource.hikari.connection-timeout}") long connectionTimeout,
                           @Value("${server.tomcat.threads.max:200}") int maxThreads,
                           @Value("${server.tomcat.accept-count}") int acceptCount,
                           @Value("${mts.shed.permits}") int permits) {
        this.timings = timings;
        this.sampler = sampler;
        this.poolSize = poolSize;
        this.connectionTimeout = connectionTimeout;
        this.maxThreads = maxThreads;
        this.acceptCount = acceptCount;
        this.permits = permits;
    }

    @GetMapping(value = "/stats", produces = MediaType.TEXT_PLAIN_VALUE)
    public String stats() {
        return String.format("# 설정  pool=%d connection-timeout=%dms tomcat.threads.max=%d accept-count=%d shed.permits=%d%n%n",
                poolSize, connectionTimeout, maxThreads, acceptCount, permits)
                + timings.report() + "\n" + sampler.report();
    }
}
