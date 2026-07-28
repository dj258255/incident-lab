package lab;

/**
 * 요청 컨텍스트 보관용 유틸. 로그인 사용자를 컨트롤러·서비스 어디서나 꺼내 쓰려고
 * static ThreadLocal 하나를 두는, 실무에서 아주 흔한 모양이다.
 *
 * 이 클래스는 WAR 안에 있으므로 웹앱 클래스로더가 적재한다. 즉 CTX(ThreadLocal 객체)와
 * UserCtx(값 타입)가 둘 다 웹앱 클래스로더 소속이고, 이것이 B31의 세 번째 조건이다.
 */
public final class RequestContext {

    public static final ThreadLocal<UserCtx> CTX = new ThreadLocal<>();

    public record UserCtx(String user, long requestNo) {}

    private RequestContext() {}

    public static void set(String user, long requestNo) {
        CTX.set(new UserCtx(user, requestNo));
    }

    public static UserCtx get() {
        return CTX.get();
    }

    public static void clear() {
        CTX.remove();
    }
}
