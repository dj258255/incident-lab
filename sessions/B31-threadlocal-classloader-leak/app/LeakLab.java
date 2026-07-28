import java.io.File;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryPoolMXBean;
import java.lang.ref.WeakReference;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.net.URL;
import java.net.URLClassLoader;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * B31 ThreadLocal·ClassLoader 누수 재현.
 *
 * Tomcat은 웹앱을 정지할 때 스레드에 남은 ThreadLocal을 뒤져 경고를 찍는다
 * (webappClassLoader.checkThreadLocalsForLeaks). 그 경고가 가리키는 상황을 Tomcat과 WAR 없이
 * URLClassLoader만으로 축소 재현한다. 재배포 한 번 = 새 URLClassLoader 하나다.
 *
 * 누수에는 세 조건이 동시에 필요하다.
 *   1. 워커 스레드가 재배포 후에도 살아있을 것 (스레드풀)
 *   2. 재배포마다 클래스로더가 새로 생길 것
 *   3. ThreadLocal 객체 자체가 웹앱 클래스로더 안의 static 필드에 있을 것
 *
 * 3번이 빠지면 새지 않는다. ThreadLocalMap의 키는 약한참조라서 ThreadLocal이 죽으면 엔트리가
 * 정리되는데, 값 -> 웹앱 클래스로더 -> 그 안의 클래스 -> static ThreadLocal 로 참조가 한 바퀴
 * 돌아오면 키가 영영 죽지 않아 엔트리가 stale이 되지 않기 때문이다.
 *
 * 계측은 OOM을 기다리지 않는다. 폐기한 클래스로더마다 WeakReference를 걸어 두고 GC 후 생존 수를
 * 센다. 빠르고 결과가 딱 떨어진다. Metaspace 사용량은 MemoryPoolMXBean으로 함께 찍는다.
 *
 * 실행: java LeakLab <웹앱-클래스-디렉터리> [all|leak|naive] [사이클수]
 */
public class LeakLab {

    static final int DEFAULT_CYCLES = 300;

    /** 대조군 3용. ThreadLocal 객체가 웹앱 클래스로더 "밖"(여기 = 실행기)에 있는 경우. */
    static final ThreadLocal<Object> SHARED_OUTSIDE = new ThreadLocal<>();

    static URL[] webappUrls;

    enum Mode { LEAKY, SAFE, OUTSIDE }

    record Arm(Mode mode, int cycles, int alive, long metaDelta,
               ExecutorService pool, List<WeakReference<ClassLoader>> refs) {}

    public static void main(String[] args) throws Exception {
        File dir = new File(args.length > 0 ? args[0] : "/tmp/webapp");
        webappUrls = new URL[]{dir.toURI().toURL()};
        String mode = args.length > 1 ? args[1] : "all";
        int cycles = args.length > 2 ? Integer.parseInt(args[2]) : DEFAULT_CYCLES;

        System.out.println("== B31 ThreadLocal·ClassLoader 누수 재현 (JDK " + Runtime.version() + ") ==");
        System.out.println("  웹앱 클래스 경로 = " + dir + " (실행기 클래스패스에는 없다)");
        System.out.println("  JVM 인자 = " + ManagementFactory.getRuntimeMXBean().getInputArguments());
        System.out.println("  계측 = 폐기한 클래스로더에 WeakReference를 걸고 GC 후 생존 수를 센다");
        System.out.println();

        switch (mode) {
            case "leak" -> { stress(Mode.LEAKY, cycles); return; }
            case "naive" -> { stress(Mode.OUTSIDE, cycles); return; }
            default -> { }
        }

        probeStructure();

        long base = metaspace();
        Arm leaky = runArm(Mode.LEAKY, cycles, base);
        report(1, "누수: ThreadLocal이 웹앱 클래스로더 안 static 필드 + remove() 없음", leaky);

        Arm safe = runArm(Mode.SAFE, cycles, metaspace());
        report(2, "해소: 같은 조건에서 try/finally로 remove() 호출", safe);

        Arm outside = runArm(Mode.OUTSIDE, cycles, metaspace());
        report(3, "대조: ThreadLocal이 웹앱 클래스로더 밖 + remove() 없음", outside);

        renewThreads(leaky);
        summary(leaky, safe, outside);

        // 남은 워커 스레드를 정리한다. 살아 있는 동안은 JVM이 종료되지 않는다.
        safe.pool().shutdown();
        outside.pool().shutdown();
    }

    /**
     * 구조 확인. 재배포 1회분으로 참조 고리를 실제 객체에서 읽어 확인한다.
     * "값 -> 웹앱 클래스로더 -> static ThreadLocal(= 맵의 키)"이 한 바퀴 도는지가 핵심이다.
     */
    static void probeStructure() throws Exception {
        URLClassLoader cl = new URLClassLoader("webapp-probe", webappUrls, LeakLab.class.getClassLoader());
        Class<?> holder = cl.loadClass("webapp.RequestContextHolder");
        Field ctxField = holder.getField("CTX");
        Object ctxTl = ctxField.get(null);              // static ThreadLocal 인스턴스 = 맵의 키가 될 객체
        Class<?> valueType = Class.forName("webapp.RequestContextHolder$Ctx", true, cl);
        boolean sameLoader = valueType.getClassLoader() == holder.getClassLoader();
        boolean isThreadLocal = ctxTl instanceof ThreadLocal;

        System.out.println("[구조 확인] 재배포 1회분으로 참조 고리를 확인한다");
        System.out.println("  웹앱 클래스   = " + holder.getName()
                + "  <- " + (String) holder.getMethod("whoLoadedMe").invoke(null));
        System.out.println("  키(맵에 들어갈 ThreadLocal)를 담은 static 필드 = "
                + holder.getSimpleName() + "." + ctxField.getName()
                + " (" + ctxTl.getClass().getName() + ", ThreadLocal 여부 " + isThreadLocal + ")");
        System.out.println("  값 타입       = " + valueType.getName()
                + "  <- " + valueType.getClassLoader().getName());
        System.out.println("  값과 키의 클래스로더가 같은가 = " + sameLoader
                + "   <- 값에서 클래스로더를 거쳐 키로 되짚어진다, 그래서 약한참조 키가 죽지 않는다");
        System.out.println();
        cl.close();
    }

    /** 재배포 <cycles>회를 흉내낸다. 매 사이클 새 클래스로더를 만들고, 워커 스레드는 계속 산다. */
    static Arm runArm(Mode mode, int cycles, long metaBefore) throws Exception {
        ExecutorService pool = Executors.newSingleThreadExecutor(
                r -> worker("worker-" + mode.name().toLowerCase(Locale.US), r));
        List<WeakReference<ClassLoader>> refs = new ArrayList<>(cycles);

        for (int i = 0; i < cycles; i++) {
            URLClassLoader cl = new URLClassLoader("webapp-" + i, webappUrls, LeakLab.class.getClassLoader());
            deploy(pool, cl, mode, "user-" + i);
            refs.add(new WeakReference<>(cl));
            cl.close();   // 컨테이너가 재배포에서 하는 일: 클래스로더를 닫고 참조를 버린다
        }
        scrub(pool);

        long metaAfter = metaspaceAfterGc();
        return new Arm(mode, cycles, aliveCount(refs), metaAfter - metaBefore, pool, refs);
    }

    /** 요청 한 건을 워커 스레드에서 처리한다. 처리 후 실행기 쪽에는 아무 참조도 남기지 않는다. */
    static void deploy(ExecutorService pool, ClassLoader cl, Mode mode, String user) throws Exception {
        Class<?> holder = cl.loadClass("webapp.RequestContextHolder");
        pool.submit(() -> {
            Method m = switch (mode) {
                case LEAKY -> holder.getMethod("handleLeaky", String.class);
                case SAFE -> holder.getMethod("handleSafe", String.class);
                case OUTSIDE -> holder.getMethod("handleOutsideHolder", ThreadLocal.class, String.class);
            };
            if (mode == Mode.OUTSIDE) m.invoke(null, SHARED_OUTSIDE, user);
            else m.invoke(null, user);
            return null;
        }).get();
    }

    /** 워커 스레드 스택에 남은 마지막 사이클의 지역 참조를 밀어낸다. 계측 잡음을 줄이기 위한 것이다. */
    static void scrub(ExecutorService pool) throws Exception {
        pool.submit(() -> {
            long x = 0;
            for (int i = 0; i < 100_000; i++) x += i;
            return x;
        }).get();
    }

    /**
     * 해소 2. 워커 스레드를 갱신하면 어떻게 되는가.
     * Tomcat 경고 문구의 "Threads are going to be renewed over time"에 해당한다.
     */
    static void renewThreads(Arm leaky) throws Exception {
        leaky.pool().shutdown();
        while (!leaky.pool().isTerminated()) Thread.sleep(20);
        int alive = aliveCount(leaky.refs());
        System.out.println("[해소 2] 누수 실험의 워커 스레드를 종료(스레드 갱신)한 뒤 다시 셈");
        System.out.println("  생존 클래스로더 = " + alive + " / " + leaky.cycles()
                + "   <- 스레드가 죽으면 그 스레드의 ThreadLocalMap도 같이 죽는다");
        System.out.println("  Metaspace 총 사용량 = " + mb(metaspaceAfterGc()));
        System.out.println();
    }

    static void report(int no, String title, Arm arm) {
        System.out.println("[실험 " + no + "] " + title);
        System.out.println("  재배포(새 클래스로더) " + String.format(Locale.US, "%,d", arm.cycles())
                + "회, 워커 스레드 1개를 끝까지 유지");
        String mark = switch (arm.mode()) {
            case LEAKY -> "   <- 폐기했어야 할 클래스로더가 전부 남았다";
            case SAFE -> "   <- 전부 수거됐다";
            case OUTSIDE -> "   <- 마지막 값 하나만 남는다. 덮어쓰기가 이전 것을 놓아주기 때문이다";
        };
        System.out.println("  생존 클래스로더 = " + arm.alive() + " / " + arm.cycles() + mark);
        System.out.println("  Metaspace 증가분 = " + mb(arm.metaDelta()) + " (총 " + mb(metaspace()) + ")");
        System.out.println();
    }

    static void summary(Arm leaky, Arm safe, Arm outside) {
        System.out.println("== 요약 (재배포 " + String.format(Locale.US, "%,d", leaky.cycles()) + "회, JDK "
                + Runtime.version().feature() + ") ==");
        line("누수 (웹앱 안 ThreadLocal, remove 없음)", leaky);
        line("해소 (같은 조건 + try/finally remove)", safe);
        line("대조 (ThreadLocal이 웹앱 밖, remove 없음)", outside);
    }

    static void line(String label, Arm arm) {
        System.out.println("  " + pad(label, 42) + " 생존 "
                + pad(arm.alive() + " / " + arm.cycles(), 10)
                + " Metaspace 증가분 " + mb(arm.metaDelta()));
    }

    /** 한글은 폭 2로 세어 자리를 맞춘다. 콘솔 표가 어긋나지 않게 하려는 것뿐이다. */
    static String pad(String s, int width) {
        int w = 0;
        for (int i = 0; i < s.length(); i++) w += s.charAt(i) >= 0x1100 ? 2 : 1;
        return s + " ".repeat(Math.max(0, width - w));
    }

    /** OOM 관찰용. 같은 사이클을 대량 반복하며 Metaspace 사용량을 주기적으로 찍는다. */
    static void stress(Mode mode, int cycles) throws Exception {
        String label = mode == Mode.LEAKY
                ? "누수 조건(웹앱 안 ThreadLocal + remove 없음)"
                : "순진한 설계(ThreadLocal 하나를 계속 덮어쓰기)";
        System.out.println("[부하] " + label + "으로 재배포 "
                + String.format(Locale.US, "%,d", cycles) + "회를 돌린다");
        ExecutorService pool = Executors.newSingleThreadExecutor(r -> worker("worker-stress", r));
        int i = 0;
        try {
            for (; i < cycles; i++) {
                URLClassLoader cl = new URLClassLoader("webapp-" + i, webappUrls, LeakLab.class.getClassLoader());
                deploy(pool, cl, mode, "user-" + i);
                cl.close();
                if ((i + 1) % 2_000 == 0) {
                    System.out.println(String.format(Locale.US, "  %,7d 사이클: Metaspace %s", i + 1, mb(metaspace())));
                }
            }
        } catch (OutOfMemoryError e) {
            System.out.println(String.format(Locale.US, "  %,7d 사이클에서 %s: %s", i + 1,
                    e.getClass().getName(), e.getMessage()));
            throw e;
        }
        System.out.println(String.format(Locale.US, "  %,d 사이클 완주, OOM 없음. Metaspace %s",
                cycles, mb(metaspace())));
        pool.shutdownNow();
    }

    /**
     * 워커 스레드를 만든다. 데몬으로 두는 이유는 하나뿐이다. OOM으로 main이 죽었을 때
     * 남은 워커가 JVM을 붙잡아 컨테이너가 끝나지 않는 일을 막으려는 것이다.
     * 데몬 여부는 ThreadLocalMap의 수명과는 무관하다.
     */
    static Thread worker(String name, Runnable r) {
        Thread t = new Thread(r, name);
        t.setDaemon(true);
        return t;
    }

    static int aliveCount(List<WeakReference<ClassLoader>> refs) throws InterruptedException {
        gc();
        int n = 0;
        for (WeakReference<ClassLoader> r : refs) if (r.get() != null) n++;
        return n;
    }

    static void gc() throws InterruptedException {
        for (int i = 0; i < 5; i++) {
            System.gc();
            Thread.sleep(60);
        }
    }

    static long metaspaceAfterGc() throws InterruptedException {
        gc();
        return metaspace();
    }

    static long metaspace() {
        for (MemoryPoolMXBean p : ManagementFactory.getMemoryPoolMXBeans()) {
            if ("Metaspace".equals(p.getName())) return p.getUsage().getUsed();
        }
        return -1;
    }

    static String mb(long bytes) {
        return String.format(Locale.US, "%.1f MB", bytes / 1024.0 / 1024.0);
    }
}
