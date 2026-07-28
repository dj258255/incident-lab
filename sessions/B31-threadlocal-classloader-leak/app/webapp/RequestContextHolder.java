package webapp;

/**
 * 웹앱 역할 클래스. 실행기(LeakLab)의 클래스패스에 없고, 재배포마다 새로 만드는
 * URLClassLoader가 이 디렉터리에서 따로 읽어 들인다. 그래서 클래스로더가 다르면
 * 아래 static 필드 CTX도 서로 다른 ThreadLocal 인스턴스가 된다.
 *
 * 실무에서 흔한 "요청 컨텍스트 보관용 유틸" 모양 그대로다. 로그인 사용자나 추적 ID를
 * 컨트롤러·서비스 어디서나 꺼내 쓰려고 static ThreadLocal 하나를 두는 그 패턴이다.
 */
public class RequestContextHolder {

    /** 웹앱 클래스로더가 적재한 클래스의 static 필드. 이 위치가 누수의 3번 조건이다. */
    public static final ThreadLocal<Object> CTX = new ThreadLocal<>();

    /** 컨텍스트 값. 이 타입 역시 웹앱 클래스로더 소속이라 값 하나가 클래스로더 전체를 붙잡는다. */
    public static class Ctx {
        public final String user;
        // 값이 커야 새는 게 아니다. 크기와 무관하게 참조 한 줄이면 클래스로더가 남는다.
        private final byte[] payload = new byte[8 * 1024];

        public Ctx(String user) {
            this.user = user;
        }

        @Override
        public String toString() {
            return "Ctx(user=" + user + ", payload=" + payload.length + "B)";
        }
    }

    /** 누수 경로. 필터가 컨텍스트를 심고 지우지 않는다. */
    public static void handleLeaky(String user) {
        CTX.set(new Ctx(user));
    }

    /** 해소 경로. 서블릿 필터·인터셉터가 실무에서 하는 일: try/finally로 반드시 지운다. */
    public static void handleSafe(String user) {
        try {
            CTX.set(new Ctx(user));
        } finally {
            CTX.remove();
        }
    }

    /**
     * 대조군. ThreadLocal 객체 자체는 웹앱 밖(컨테이너·공용 클래스로더)에 있고
     * 값만 웹앱 것을 넣는다. remove()는 여기서도 부르지 않는다.
     */
    public static void handleOutsideHolder(ThreadLocal<Object> shared, String user) {
        shared.set(new Ctx(user));
    }

    /** 진단용. 이 클래스가 어느 클래스로더에서 왔는지 이름으로 확인한다. */
    public static String whoLoadedMe() {
        ClassLoader cl = RequestContextHolder.class.getClassLoader();
        return cl == null ? "bootstrap" : cl.getName() + " (" + cl.getClass().getSimpleName() + ")";
    }
}
