package lab;

import java.io.IOException;

import jakarta.servlet.Filter;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletRequest;
import jakarta.servlet.ServletResponse;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;

/**
 * 서블릿 필터 진입부터 응답이 끝날 때까지를 잰다. 이 시각에는 이미 Tomcat 스레드를 잡은 뒤라,
 * k6가 잰 시간에서 이 값을 빼면 accept 큐와 스레드 배정에서 기다린 시간이 남는다.
 * 상태코드별로 나눠 담으므로 503이 몇 ms에 나갔는지도 여기서 갈린다.
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class TimingFilter implements Filter {

    private final Timings timings;

    public TimingFilter(Timings timings) {
        this.timings = timings;
    }

    @Override
    public void doFilter(ServletRequest req, ServletResponse res, FilterChain chain)
            throws IOException, ServletException {
        String uri = (req instanceof HttpServletRequest hr) ? hr.getRequestURI() : "";
        if (uri.startsWith("/stats") || uri.startsWith("/health")) {
            chain.doFilter(req, res);
            return;
        }
        long t0 = System.nanoTime();
        boolean thrown = false;
        try {
            chain.doFilter(req, res);
        } catch (IOException | ServletException | RuntimeException | Error e) {
            // 컨트롤러가 던진 예외는 여기까지 올라온 뒤 컨테이너가 /error로 넘긴다.
            // 그 시점에는 응답 상태가 아직 200이라 500으로 직접 표시한다.
            thrown = true;
            throw e;
        } finally {
            int status = thrown ? 500 : ((HttpServletResponse) res).getStatus();
            timings.inApp(status, System.nanoTime() - t0);
        }
    }
}
