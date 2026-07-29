package lab;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import org.springframework.stereotype.Component;

/**
 * 계층별 대기 시간을 나눠 담는다.
 *
 *   k6가 잰 응답 시간
 *     = (accept 큐 대기 + Tomcat 스레드 대기)   <- 앱 안에서는 잴 수 없어 뺄셈으로 구한다
 *     + inapp_<상태코드>                        <- 서블릿 필터 진입부터 응답 완료까지
 *
 *   inapp = pool_acquire(커넥션 획득 대기) + query_after_acquire(쿼리 50ms) + 나머지
 *
 * 상태코드별로 나눠 담으므로 503 응답이 실제로 몇 ms에 나갔는지도 여기서 나온다.
 */
@Component
public class Timings {

    private final Map<Integer, Recorder> inApp = new ConcurrentHashMap<>();
    private final Recorder acquireOk = new Recorder("pool_acquire_ok");
    private final Recorder acquireFail = new Recorder("pool_acquire_timeout");
    private final Recorder query = new Recorder("query_after_acquire");

    /** 같은 요청 안에서 획득 시간과 쿼리 시간을 가르려고 스레드에 잠깐 얹어 둔다. */
    private final ThreadLocal<Long> lastAcquire = new ThreadLocal<>();

    public void inApp(int status, long nanos) {
        inApp.computeIfAbsent(status, s -> new Recorder("inapp_" + s)).record(nanos);
    }

    public void acquireOk(long nanos) {
        acquireOk.record(nanos);
        lastAcquire.set(nanos);
    }

    public void acquireFail(long nanos) {
        acquireFail.record(nanos);
        lastAcquire.remove();
    }

    /** DB 호출 전체 시간에서 획득 시간을 빼 쿼리 시간만 남긴다. */
    public void dbCall(long totalNanos) {
        Long acquired = lastAcquire.get();
        lastAcquire.remove();
        if (acquired != null) {
            query.record(Math.max(0, totalNanos - acquired));
        }
    }

    public String report() {
        StringBuilder sb = new StringBuilder();
        sb.append("# 앱 안에서 잰 계층별 시간 (서블릿 필터 기준)\n");
        inApp.entrySet().stream()
                .sorted(Map.Entry.comparingByKey())
                .forEach(e -> sb.append(e.getValue().report()).append('\n'));
        sb.append(acquireOk.report()).append('\n');
        sb.append(acquireFail.report()).append('\n');
        sb.append(query.report()).append('\n');
        return sb.toString();
    }
}
