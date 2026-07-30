package lab;

import java.lang.reflect.Method;
import java.util.concurrent.atomic.AtomicInteger;

import javax.sql.DataSource;

import com.zaxxer.hikari.HikariDataSource;
import com.zaxxer.hikari.HikariPoolMXBean;

import jakarta.annotation.PostConstruct;

import org.apache.catalina.connector.Connector;
import org.apache.coyote.AbstractProtocol;
import org.apache.tomcat.util.threads.ThreadPoolExecutor;
import org.springframework.boot.web.embedded.tomcat.TomcatWebServer;
import org.springframework.boot.web.servlet.context.ServletWebServerApplicationContext;
import org.springframework.context.ApplicationContext;
import org.springframework.stereotype.Component;

/**
 * 100ms마다 두 계층의 큐 길이를 같이 찍는다.
 *   HikariCP : total / active / idle / waiting(획득 대기 큐)
 *   Tomcat   : busy(작업 중 스레드) / pool(스레드 수) / queue(스레드를 기다리는 요청) / conn(열린 소켓)
 * 어느 계층에 얼마가 쌓였는지를 한 시각에서 같이 봐야 중앙값의 몫을 가를 수 있다.
 */
@Component
public class PoolSampler {

    private static final int CAP = 12_000; // 100ms * 12,000 = 20분

    private final ApplicationContext ctx;
    private final DataSource dataSource;

    private final long[] tMillis = new long[CAP];
    private final int[] hikariActive = new int[CAP];
    private final int[] hikariIdle = new int[CAP];
    private final int[] hikariWaiting = new int[CAP];
    private final int[] tomcatBusy = new int[CAP];
    private final int[] tomcatPool = new int[CAP];
    private final int[] tomcatQueue = new int[CAP];
    private final int[] tomcatConn = new int[CAP];
    private final AtomicInteger idx = new AtomicInteger();
    private volatile long startMillis;

    private volatile ThreadPoolExecutor executor;
    private volatile AbstractProtocol<?> protocol;
    private volatile Object endpoint;
    private volatile Method connectionCount;

    public PoolSampler(ApplicationContext ctx, DataSource dataSource) {
        this.ctx = ctx;
        this.dataSource = dataSource;
    }

    @PostConstruct
    void start() {
        startMillis = System.currentTimeMillis();
        Thread t = new Thread(this::loop, "pool-sampler");
        t.setDaemon(true);
        t.start();
    }

    private void loop() {
        while (true) {
            try {
                sample();
                Thread.sleep(100);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            } catch (RuntimeException e) {
                // 계측이 재현을 방해하지 않도록 조용히 넘어간다.
            }
        }
    }

    private void sample() {
        int i = idx.get();
        if (i >= CAP) {
            return;
        }
        HikariPoolMXBean pool = (dataSource instanceof HikariDataSource hds) ? hds.getHikariPoolMXBean() : null;
        ThreadPoolExecutor ex = tomcatExecutor();
        tMillis[i] = System.currentTimeMillis() - startMillis;
        hikariActive[i] = pool == null ? -1 : pool.getActiveConnections();
        hikariIdle[i] = pool == null ? -1 : pool.getIdleConnections();
        hikariWaiting[i] = pool == null ? -1 : pool.getThreadsAwaitingConnection();
        tomcatBusy[i] = ex == null ? -1 : ex.getActiveCount();
        tomcatPool[i] = ex == null ? -1 : ex.getPoolSize();
        tomcatQueue[i] = ex == null ? -1 : ex.getQueue().size();
        tomcatConn[i] = connectionCount();
        idx.incrementAndGet();
    }

    private ThreadPoolExecutor tomcatExecutor() {
        if (executor != null) {
            return executor;
        }
        if (ctx instanceof ServletWebServerApplicationContext swc
                && swc.getWebServer() instanceof TomcatWebServer tws) {
            // findConnectors()로 "읽기만" 한다. Tomcat.getConnector()를 부르면 안 된다.
            // 그 메서드는 서비스에 커넥터가 하나도 없을 때 8080짜리 커넥터를 새로 만들어 붙인다.
            // Spring Boot는 기동 중 커넥터를 잠시 떼어 두었다가 start()에서 되돌리므로,
            // 이 샘플러 스레드가 하필 그 창에서 getConnector()를 부르면 커넥터가 둘이 되어
            // 진짜 커넥터가 바인드에 실패하고 "Port 8080 was already in use"로 앱이 죽는다.
            // 실제로 그렇게 죽었고, 그때 새로 생긴 쪽이 /health에 응답해 기동에 성공한 것처럼 보였다.
            Connector[] connectors = tws.getTomcat().getService().findConnectors();
            if (connectors.length == 0) {
                return null;
            }
            Object ph = connectors[0].getProtocolHandler();
            if (ph instanceof AbstractProtocol<?> ap) {
                protocol = ap;
                // 내장 Tomcat의 작업 스레드 풀은 java.util.concurrent 쪽이 아니라
                // org.apache.tomcat.util.threads.ThreadPoolExecutor다. 앞서 java.util.concurrent
                // 타입으로 검사해 계속 -1이 찍혔다.
                if (ap.getExecutor() instanceof ThreadPoolExecutor tpe) {
                    executor = tpe;
                }
            }
        }
        return executor;
    }

    /** AbstractEndpoint.getConnectionCount()는 열린 소켓 수다. 못 읽으면 -1을 넣는다. */
    private int connectionCount() {
        try {
            if (endpoint == null) {
                AbstractProtocol<?> ap = protocol;
                if (ap == null) {
                    return -1;
                }
                Method get = AbstractProtocol.class.getDeclaredMethod("getEndpoint");
                get.setAccessible(true);
                endpoint = get.invoke(ap);
                connectionCount = endpoint.getClass().getMethod("getConnectionCount");
                connectionCount.setAccessible(true);
            }
            return (int) (long) (Long) connectionCount.invoke(endpoint);
        } catch (ReflectiveOperationException | RuntimeException e) {
            return -1;
        }
    }

    public String report() {
        int n = Math.min(idx.get(), CAP);
        StringBuilder sb = new StringBuilder();
        sb.append("# 큐 길이 표본 100ms 간격, ").append(n).append("개\n");
        if (n == 0) {
            return sb.toString();
        }
        sb.append(String.format("최댓값  hikari_active=%d hikari_waiting=%d tomcat_busy=%d tomcat_queue=%d tomcat_conn=%d%n",
                max(hikariActive, n), max(hikariWaiting, n), max(tomcatBusy, n), max(tomcatQueue, n), max(tomcatConn, n)));
        sb.append("t(s)  hikari(active/idle/waiting)  tomcat(busy/pool/queue/conn)\n");
        for (int i = 0; i < n; i += 10) { // 1초 간격으로 솎아 적는다
            sb.append(String.format("%5.1f  %3d/%3d/%5d              %4d/%4d/%5d/%5d%n",
                    tMillis[i] / 1000.0, hikariActive[i], hikariIdle[i], hikariWaiting[i],
                    tomcatBusy[i], tomcatPool[i], tomcatQueue[i], tomcatConn[i]));
        }
        return sb.toString();
    }

    private static int max(int[] a, int n) {
        int m = Integer.MIN_VALUE;
        for (int i = 0; i < n; i++) {
            m = Math.max(m, a[i]);
        }
        return m;
    }
}
