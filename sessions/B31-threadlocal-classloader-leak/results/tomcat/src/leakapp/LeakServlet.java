package leakapp;

import java.io.IOException;
import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

/**
 * 요청 컨텍스트를 ThreadLocal 에 넣고 지우지 않는다.
 * 담기는 값의 클래스가 이 웹앱의 클래스로더에 적재된 것이라, 워커 스레드가 살아 있는 한
 * 그 클래스로더 전체가 회수되지 않는다. 재배포해도 마찬가지다.
 */
@WebServlet("/leak")
public class LeakServlet extends HttpServlet {
    static final ThreadLocal<Ctx> HOLDER = new ThreadLocal<>();

    public static class Ctx {
        final byte[] pad = new byte[4096];
        final String who = LeakServlet.class.getClassLoader().toString();
    }

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse res)
            throws ServletException, IOException {
        HOLDER.set(new Ctx());          // remove() 를 부르지 않는다
        res.setContentType("text/plain");
        res.getWriter().println("ok " + HOLDER.get().who);
    }
}
