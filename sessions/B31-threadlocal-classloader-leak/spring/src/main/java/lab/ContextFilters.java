package lab;

import jakarta.servlet.Filter;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletRequest;
import jakarta.servlet.ServletResponse;
import jakarta.servlet.http.HttpServletRequest;
import java.io.IOException;
import java.util.concurrent.atomic.AtomicLong;

/**
 * 같은 필터를 두 벌 만든다. 차이는 finally 블록 한 줄뿐이다.
 * 요청 헤더 X-User가 있을 때만 컨텍스트를 심는다. 헤더 없이 들어온 요청이 무엇을 보게 되는지가
 * 이 실험의 관측 지점이다.
 */
public final class ContextFilters {

    private static final AtomicLong SEQ = new AtomicLong();

    private ContextFilters() {}

    /** 누수 경로. 심기만 하고 지우지 않는다. */
    public static class Leaky implements Filter {
        @Override
        public void doFilter(ServletRequest req, ServletResponse res, FilterChain chain)
                throws IOException, ServletException {
            String user = ((HttpServletRequest) req).getHeader("X-User");
            if (user != null) {
                RequestContext.set(user, SEQ.incrementAndGet());
            }
            chain.doFilter(req, res);
            // remove() 없음. 요청이 끝나도 값이 워커 스레드에 그대로 남는다.
        }
    }

    /** 해소 경로. try/finally로 반드시 지운다. */
    public static class Safe implements Filter {
        @Override
        public void doFilter(ServletRequest req, ServletResponse res, FilterChain chain)
                throws IOException, ServletException {
            String user = ((HttpServletRequest) req).getHeader("X-User");
            try {
                if (user != null) {
                    RequestContext.set(user, SEQ.incrementAndGet());
                }
                chain.doFilter(req, res);
            } finally {
                RequestContext.clear();
            }
        }
    }
}
