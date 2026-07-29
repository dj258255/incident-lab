import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.WebSocket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.List;
import java.util.Locale;
import java.util.Random;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * F15 부하·측정 클라이언트.
 *
 * 정상 구독자 N개는 JDK 내장 java.net.http.WebSocket으로 최대 속도로 읽고,
 * 느린 구독자 1개는 생 소켓으로 핸드셰이크만 하고 초당 정해진 바이트만 읽는다.
 * 모바일 회선 열화, GC 스톨, 백그라운드 전환으로 클라이언트가 읽기를 지연시키는 상황을 모사한 것이다.
 *
 * 실행: java -Durl=ws://app:8080/stream -Dnormal=5 -Dseconds=75 Client.java
 */
public class Client {

    public static void main(String[] args) throws Exception {
        String url = System.getProperty("url", "ws://app:8080/stream");
        int normalCount = Integer.parseInt(System.getProperty("normal", "5"));
        int seconds = Integer.parseInt(System.getProperty("seconds", "75"));
        int slowBytesPerSec = Integer.parseInt(System.getProperty("slowBytesPerSec", "32768"));
        int slowRcvBuf = Integer.parseInt(System.getProperty("slowRcvBuf", "8192"));
        // slow=0이면 느린 구독자 없이 정상 구독자만 붙인다(대조군).
        int slowCount = Integer.parseInt(System.getProperty("slow", "1"));
        String out = System.getProperty("out", "/results/client.txt");
        String mode = System.getProperty("mode", "?");
        String run = System.getProperty("run", "1");

        URI uri = URI.create(url);
        String host = uri.getHost();
        int port = uri.getPort() < 0 ? 80 : uri.getPort();
        String path = uri.getPath();

        // 느린 구독자를 먼저 붙인다. 발행은 구독자가 다 붙어야 시작한다.
        SlowReader slow = null;
        if (slowCount > 0) {
            slow = new SlowReader(host, port, path + "?id=slow-1", slowBytesPerSec, slowRcvBuf);
            slow.connect();
        } else {
            System.out.println("느린 구독자 없음(대조군)");
        }

        // JIT 워밍업 구간은 백분위 계산에서 뺀다. 모든 모드에 같은 값을 쓴다.
        int warmup = Integer.parseInt(System.getProperty("warmup", "5"));

        HttpClient http = HttpClient.newHttpClient();
        List<Normal> normals = new ArrayList<>();
        for (int i = 1; i <= normalCount; i++) {
            Normal n = new Normal("normal-" + i, seconds, warmup);
            WebSocket ws = http.newWebSocketBuilder()
                    .connectTimeout(java.time.Duration.ofSeconds(10))
                    .buildAsync(URI.create(url + "?id=" + n.id), n)
                    .join();
            n.ws = ws;
            normals.add(n);
        }
        System.out.println("접속 완료: 정상 " + normalCount + "개 + 느린 구독자 1개");

        long t0 = System.currentTimeMillis();
        if (slow != null) {
            slow.start(t0);
        }
        for (Normal n : normals) {
            n.t0 = t0;
        }

        Thread.sleep(seconds * 1000L);

        for (Normal n : normals) {
            n.stop();
        }
        if (slow != null) {
            slow.stop();
        }
        long elapsed = System.currentTimeMillis() - t0;

        StringBuilder sb = new StringBuilder();
        sb.append("== F15 클라이언트 측정 ==\n");
        sb.append(String.format(Locale.ROOT,
                "mode=%s run=%s 측정시간=%.1fs 정상구독자=%d 느린구독자=%s%n",
                mode, run, elapsed / 1000.0, normalCount,
                slow == null ? "없음(대조군)"
                        : String.format(Locale.ROOT, "1(읽기 %d B/s, SO_RCVBUF %dB)", slowBytesPerSec, slowRcvBuf)));
        sb.append(String.format(Locale.ROOT,
                "백분위는 워밍업 %ds를 뺀 구간의 값이고, 수신건수와 최종틱seq는 전 구간 값이다.%n", warmup));
        sb.append("\n-- 정상 구독자 --\n");
        sb.append(String.format(Locale.ROOT, "%-9s %9s %10s %8s %8s %9s %9s %9s %9s  %s%n",
                "id", "수신건수", "최종틱seq", "지연p50", "지연p95", "지연p99", "지연max",
                "간격p95", "간격max", "비고"));

        long totalRecv = 0;
        long minLastSeq = Long.MAX_VALUE;
        long maxLastSeq = 0;
        List<Long> allLat = new ArrayList<>();
        double worstP95 = 0;
        double worstMax = 0;
        for (Normal n : normals) {
            long[] lat = n.latSorted();
            long[] gap = n.gapSorted();
            totalRecv += n.count;
            minLastSeq = Math.min(minLastSeq, n.lastSeq);
            maxLastSeq = Math.max(maxLastSeq, n.lastSeq);
            worstP95 = Math.max(worstP95, pct(lat, 95));
            worstMax = Math.max(worstMax, pct(lat, 100));
            for (long v : lat) {
                allLat.add(v);
            }
            sb.append(String.format(Locale.ROOT, "%-9s %9d %10d %7.0fms %7.0fms %7.0fms %7.0fms %7.1fms %7.0fms  %s%n",
                    n.id, n.count, n.lastSeq,
                    pct(lat, 50), pct(lat, 95), pct(lat, 99), pct(lat, 100),
                    pct(gap, 95) / 1000.0, pct(gap, 100) / 1000.0,
                    n.note.isEmpty() ? "-" : n.note));
        }
        long[] agg = allLat.stream().mapToLong(Long::longValue).sorted().toArray();
        sb.append(String.format(Locale.ROOT,
                "%n합계 수신 %d건, 정상 구독자 전체 지연 p50=%.0fms p95=%.0fms p99=%.0fms max=%.0fms%n",
                totalRecv, pct(agg, 50), pct(agg, 95), pct(agg, 99), pct(agg, 100)));
        sb.append(String.format(Locale.ROOT, "최종 수신 틱 seq: 최소 %d, 최대 %d%n",
                minLastSeq == Long.MAX_VALUE ? 0 : minLastSeq, maxLastSeq));

        sb.append("\n-- 느린 구독자 --\n");
        sb.append(slow == null ? "없음(대조군)\n" : slow.report());

        sb.append(String.format(Locale.ROOT,
                "%nSUMMARY mode=%s run=%s recv_total=%d lat_p50_ms=%.0f lat_p95_ms=%.0f lat_p99_ms=%.0f "
                        + "lat_max_ms=%.0f last_seq_min=%d last_seq_max=%d worst_client_p95_ms=%.0f "
                        + "worst_client_max_ms=%.0f slow_read_bytes=%d slow_closed_at_s=%s%n",
                mode, run, totalRecv, pct(agg, 50), pct(agg, 95), pct(agg, 99), pct(agg, 100),
                minLastSeq == Long.MAX_VALUE ? 0 : minLastSeq, maxLastSeq, worstP95, worstMax,
                slow == null ? 0 : slow.readBytes, slow == null ? "n/a" : slow.closedAtSeconds()));

        String text = sb.toString();
        System.out.print(text);
        Path p = Path.of(out);
        if (p.getParent() != null) {
            Files.createDirectories(p.getParent());
        }
        try (PrintWriter w = new PrintWriter(Files.newBufferedWriter(p, StandardCharsets.UTF_8))) {
            w.print(text);
        }
        System.exit(0);
    }

    static double pct(long[] sorted, int p) {
        if (sorted.length == 0) {
            return 0;
        }
        if (p >= 100) {
            return sorted[sorted.length - 1];
        }
        int idx = (int) Math.ceil(sorted.length * p / 100.0) - 1;
        return sorted[Math.max(0, Math.min(sorted.length - 1, idx))];
    }

    /** 정상 구독자. 오는 대로 즉시 읽는다. */
    static final class Normal implements WebSocket.Listener {
        final String id;
        final int warmupSeconds;
        WebSocket ws;
        volatile long t0;
        long count;
        long lastSeq;
        String note = "";
        private final long[] lat;
        private final long[] gap;
        private int n;
        private long prevRecvNanos;
        private final StringBuilder partial = new StringBuilder();

        Normal(String id, int seconds, int warmupSeconds) {
            this.id = id;
            this.warmupSeconds = warmupSeconds;
            int cap = Math.max(4096, seconds * 6000);
            this.lat = new long[cap];
            this.gap = new long[cap];
        }

        void stop() {
            try {
                if (ws != null) {
                    ws.abort();
                }
            } catch (Throwable ignored) {
                // 측정이 끝났으니 정리 실패는 무시한다.
            }
        }

        @Override
        public void onOpen(WebSocket webSocket) {
            webSocket.request(1);
        }

        @Override
        public CompletionStage<?> onText(WebSocket webSocket, CharSequence data, boolean last) {
            partial.append(data);
            if (last) {
                record(partial.toString());
                partial.setLength(0);
            }
            webSocket.request(1);
            return null;
        }

        @Override
        public CompletionStage<?> onClose(WebSocket webSocket, int statusCode, String reason) {
            note = "서버가 끊음 code=" + statusCode + " reason=" + reason;
            return null;
        }

        @Override
        public void onError(WebSocket webSocket, Throwable error) {
            if (note.isEmpty()) {
                note = "오류 " + error.getClass().getSimpleName();
            }
        }

        private void record(String msg) {
            long nowNanos = System.nanoTime();
            long nowMillis = System.currentTimeMillis();
            count++;
            long seq = readLong(msg, "\"seq\":");
            long pub = readLong(msg, "\"t\":");
            if (seq > lastSeq) {
                lastSeq = seq;
            }
            boolean warm = t0 > 0 && nowMillis - t0 >= warmupSeconds * 1000L;
            if (warm && n < lat.length) {
                lat[n] = Math.max(0, nowMillis - pub);
                gap[n] = prevRecvNanos == 0 ? 0 : (nowNanos - prevRecvNanos) / 1000;
                n++;
            }
            prevRecvNanos = nowNanos;
        }

        private static long readLong(String s, String key) {
            int i = s.indexOf(key);
            if (i < 0) {
                return 0;
            }
            int j = i + key.length();
            int k = j;
            while (k < s.length() && (Character.isDigit(s.charAt(k)) || s.charAt(k) == '-')) {
                k++;
            }
            try {
                return Long.parseLong(s.substring(j, k));
            } catch (RuntimeException e) {
                return 0;
            }
        }

        long[] latSorted() {
            long[] a = Arrays.copyOf(lat, n);
            Arrays.sort(a);
            return a;
        }

        long[] gapSorted() {
            long[] a = Arrays.copyOf(gap, n);
            Arrays.sort(a);
            return a;
        }
    }

    /**
     * 느린 구독자. WebSocket 핸드셰이크만 직접 하고 프레임은 파싱하지 않는다.
     * 초당 정해진 바이트만 읽어 TCP 수신 창을 막고, 서버 쪽에 백프레셔를 만든다.
     */
    static final class SlowReader {
        final String host;
        final int port;
        final String path;
        final int bytesPerSec;
        final int rcvBuf;
        Socket sock;
        InputStream in;
        volatile long readBytes;
        volatile boolean running = true;
        volatile long closedAtMillis;
        volatile String closeNote = "";
        private long t0;
        private Thread thread;
        private final CountDownLatch done = new CountDownLatch(1);

        SlowReader(String host, int port, String path, int bytesPerSec, int rcvBuf) {
            this.host = host;
            this.port = port;
            this.path = path;
            this.bytesPerSec = bytesPerSec;
            this.rcvBuf = rcvBuf;
        }

        void connect() throws IOException {
            sock = new Socket();
            // SYN 이전에 잡아야 수신 창에 반영된다. 커널 자동 튜닝으로 수 MB가 버퍼링되는 것을 막는다.
            sock.setReceiveBufferSize(rcvBuf);
            sock.connect(new InetSocketAddress(host, port), 10_000);
            sock.setSoTimeout(2000);
            byte[] key = new byte[16];
            new Random(7).nextBytes(key);
            String k = Base64.getEncoder().encodeToString(key);
            String req = "GET " + path + " HTTP/1.1\r\n"
                    + "Host: " + host + ":" + port + "\r\n"
                    + "Upgrade: websocket\r\n"
                    + "Connection: Upgrade\r\n"
                    + "Sec-WebSocket-Key: " + k + "\r\n"
                    + "Sec-WebSocket-Version: 13\r\n\r\n";
            OutputStream os = sock.getOutputStream();
            os.write(req.getBytes(StandardCharsets.ISO_8859_1));
            os.flush();
            in = sock.getInputStream();
            StringBuilder head = new StringBuilder();
            int c;
            while ((c = in.read()) != -1) {
                head.append((char) c);
                if (head.length() >= 4 && head.substring(head.length() - 4).equals("\r\n\r\n")) {
                    break;
                }
            }
            String status = head.toString().split("\r\n")[0];
            System.out.println("느린 구독자 핸드셰이크: " + status
                    + " (SO_RCVBUF 요청 " + rcvBuf + "B, 실제 " + sock.getReceiveBufferSize() + "B)");
        }

        void start(long t0) {
            this.t0 = t0;
            thread = new Thread(this::loop, "slow-reader");
            thread.setDaemon(true);
            thread.start();
        }

        private void loop() {
            byte[] buf = new byte[8192];
            int perTick = bytesPerSec <= 0 ? 0 : Math.max(1, bytesPerSec / 10);
            try {
                while (running) {
                    Thread.sleep(100);
                    int budget = perTick;
                    while (budget > 0 && running) {
                        int r;
                        try {
                            r = in.read(buf, 0, Math.min(buf.length, budget));
                        } catch (SocketTimeoutException te) {
                            break; // 보낼 게 없다. 다음 주기에 다시 본다.
                        }
                        if (r < 0) {
                            closedAtMillis = System.currentTimeMillis();
                            closeNote = "서버가 스트림을 닫음(EOF)";
                            done.countDown();
                            return;
                        }
                        budget -= r;
                        readBytes += r;
                    }
                }
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
            } catch (IOException e) {
                closedAtMillis = System.currentTimeMillis();
                closeNote = "소켓 오류: " + e.getClass().getSimpleName() + " " + e.getMessage();
            } finally {
                done.countDown();
            }
        }

        void stop() {
            running = false;
            try {
                done.await(3, TimeUnit.SECONDS);
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
            try {
                sock.close();
            } catch (Throwable ignored) {
                // 정리 실패는 무시한다.
            }
        }

        String closedAtSeconds() {
            return closedAtMillis == 0 ? "none"
                    : String.format(Locale.ROOT, "%.1f", (closedAtMillis - t0) / 1000.0);
        }

        String report() {
            long elapsed = Math.max(1, System.currentTimeMillis() - t0);
            if (bytesPerSec <= 0) {
                return "slow-1  한 바이트도 읽지 않음(완전 정지 클라이언트). "
                        + "읽지 않으므로 서버의 종료를 클라이언트에서 감지하지 않는다. 서버 로그로 확인할 것.\n";
            }
            return String.format(Locale.ROOT,
                    "slow-1  읽은 바이트 %,d (평균 %.1f KB/s, 목표 %.1f KB/s)  %s%n",
                    readBytes, readBytes / 1024.0 / (elapsed / 1000.0), bytesPerSec / 1024.0,
                    closedAtMillis == 0 ? "서버가 끊지 않음(측정 끝까지 연결 유지)"
                            : "서버가 t=" + closedAtSeconds() + "s에 끊음 — " + closeNote);
        }
    }
}
