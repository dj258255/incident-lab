// README 의 "못 한 것" 하나를 잰다.
//
//   GC 압박으로 느려지는 경로는 재지 않았습니다
//   "OutOfMemoryError 까지 가는 것은 봤지만, 터지기 전에 GC 가 늘어 응답이 느려지는
//    구간은 재지 않았습니다."
//
// 이쪽이 실무에서 먼저 보이는 증상이다. Metaspace 가 꽉 차기 전에 GC 가 회수를 시도하며
// 점점 자주, 점점 오래 돈다. 그동안 애플리케이션 스레드는 멈춘다. 터지는 순간보다
// 그 앞의 완만한 열화가 길고, 그래서 원인을 못 찾은 채로 재기동만 반복하게 된다.
//
// 재배포 사이클을 늘려 가며 세 가지를 함께 본다.
//   1) Metaspace 사용량
//   2) 누적 GC 횟수와 누적 GC 시간
//   3) 고정된 일 한 단위의 벽시계 시간
//
// 셋째가 핵심이다. 같은 일을 같은 방식으로 시키는데 사이클이 쌓일수록 오래 걸리면,
// 그 늘어난 시간이 GC 가 가져간 몫이다.
//
// 실행: java -XX:MaxMetaspaceSize=<N>m GcPressure <웹앱-클래스-디렉터리> <leak|safe> <사이클수> <표본간격>
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryPoolMXBean;
import java.lang.ref.WeakReference;
import java.lang.reflect.Method;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class GcPressure {

    static URL[] webappUrls;
    static final ThreadLocal<Object> SHARED_SAFE = new ThreadLocal<>();

    record Sample(int cycle, long metaUsed, long gcCount, long gcMillis, double unitMs) {}

    static long metaUsed() {
        for (MemoryPoolMXBean p : ManagementFactory.getMemoryPoolMXBeans()) {
            if (p.getName().contains("Metaspace")) return p.getUsage().getUsed();
        }
        return -1;
    }

    static long[] gcStats() {
        long c = 0, t = 0;
        for (GarbageCollectorMXBean g : ManagementFactory.getGarbageCollectorMXBeans()) {
            c += Math.max(0, g.getCollectionCount());
            t += Math.max(0, g.getCollectionTime());
        }
        return new long[]{c, t};
    }

    // 고정된 일 한 단위. 사이클과 무관하게 항상 같은 양이다. 이것이 느려지면 GC 탓이다.
    static double unitWorkMs(ExecutorService pool) throws Exception {
        long t0 = System.nanoTime();
        pool.submit(() -> {
            long x = 0;
            for (int i = 0; i < 2_000_000; i++) x += i % 7;
            // 약간의 할당을 섞는다. 순수 계산만 시키면 GC 로 인한 멈춤에 안 걸린다.
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < 2_000; i++) sb.append(i % 10);
            return x + sb.length();
        }).get();
        return (System.nanoTime() - t0) / 1e6;
    }

    // 표본 한 줄. 미리 만든 포맷만 쓰고 새 객체를 거의 안 만든다.
    static void emit(Sample s, double base) {
        System.out.printf(Locale.US, "  %10d %11.1fMB %12d %11d ms %11.1f ms %11.2f배%n",
                s.cycle(), s.metaUsed() / 1048576.0, s.gcCount(), s.gcMillis(),
                s.unitMs(), base > 0 ? s.unitMs() / base : 0);
        System.out.flush();
    }

    public static void main(String[] args) throws Exception {
        String webapp = args.length > 0 ? args[0] : "/tmp/webapp";
        String mode = args.length > 1 ? args[1] : "leak";
        int cycles = args.length > 2 ? Integer.parseInt(args[2]) : 4000;
        int step = args.length > 3 ? Integer.parseInt(args[3]) : 250;
        webappUrls = new URL[]{Path.of(webapp).toUri().toURL()};

        System.out.printf(Locale.US, "# GC 압박 곡선 (mode=%s, 사이클 %,d, 표본 간격 %d)%n",
                mode, cycles, step);
        System.out.println("# " + ManagementFactory.getRuntimeMXBean().getInputArguments());
        System.out.println();

        ExecutorService pool = Executors.newSingleThreadExecutor(
                r -> { Thread t = new Thread(r, "worker-" + mode); t.setDaemon(true); return t; });
        List<WeakReference<ClassLoader>> refs = new ArrayList<>();
        List<Sample> samples = new ArrayList<>();

        // 표본을 모아 두었다가 끝에 찍으면, OOM 직후 그 출력이 다시 할당을 요구해
        // UncaughtExceptionHandler 에서 또 OOM 이 난다. 실제로 leak 조건이 그렇게 나서
        // 표가 통째로 안 남았다. 헤더를 먼저 찍고 표본마다 바로 출력한다.
        System.out.printf(Locale.US, "  %10s %14s %12s %14s %14s %12s%n",
                "사이클", "Metaspace", "누적 GC", "누적 GC 시간", "일 한 단위", "기준 대비");

        // 기준선. 사이클 0 에서의 일 한 단위 시간을 먼저 잡는다.
        for (int i = 0; i < 3; i++) unitWorkMs(pool);   // JIT 워밍업
        long[] g0 = gcStats();
        Sample first = new Sample(0, metaUsed(), 0, 0, unitWorkMs(pool));
        samples.add(first);
        final double base = first.unitMs();
        emit(first, base);

        boolean oom = false;
        int done = 0;
        try {
            for (int i = 1; i <= cycles; i++) {
                URLClassLoader cl = new URLClassLoader("webapp-" + i, webappUrls,
                        GcPressure.class.getClassLoader());
                Class<?> holder = cl.loadClass("webapp.RequestContextHolder");
                pool.submit(() -> {
                    if ("leak".equals(mode)) {
                        Method m = holder.getMethod("handleLeaky", String.class);
                        m.invoke(null, "user");
                    } else {
                        Method m = holder.getMethod("handleOutsideHolder", ThreadLocal.class, String.class);
                        m.invoke(null, SHARED_SAFE, "user");
                    }
                    return null;
                }).get();
                refs.add(new WeakReference<>(cl));
                cl.close();
                done = i;

                if (i % step == 0) {
                    long[] g = gcStats();
                    Sample sm = new Sample(i, metaUsed(), g[0] - g0[0], g[1] - g0[1],
                            unitWorkMs(pool));
                    samples.add(sm);
                    emit(sm, base);
                }
            }
        } catch (Throwable t) {
            Throwable c = t;
            while (c.getCause() != null) c = c.getCause();
            oom = c instanceof OutOfMemoryError;
            System.out.println();
            System.out.print("  중단 사이클 ");
            System.out.print(done);
            System.out.print(" : ");
            System.out.println(c.getClass().getName() + " " + c.getMessage());
            System.out.flush();
        }

        System.out.println();
        int alive = 0;
        for (WeakReference<ClassLoader> r : refs) if (r.get() != null) alive++;
        System.out.printf(Locale.US, "  살아 있는 클래스로더 = %,d / %,d%n", alive, refs.size());
        System.out.printf(Locale.US, "  OutOfMemoryError 도달 = %s%n", oom ? "예" : "아니오");
        System.out.println();
        System.out.println("  '일 한 단위' 는 사이클과 무관하게 항상 같은 양의 계산입니다.");
        System.out.println("  그것이 느려지면 늘어난 시간은 GC 가 가져간 몫입니다.");
        System.out.println("  터지기 전에 이 값이 먼저 오르면, 재기동 말고 볼 것이 있다는 신호입니다.");
    }
}
