package lab;

import java.io.IOException;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import org.springframework.stereotype.Component;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.adapter.NativeWebSocketSession;
import org.springframework.web.socket.handler.TextWebSocketHandler;

/** 구독 접속을 받아 모드에 맞는 Subscriber를 붙인다. 클라이언트는 ?id=normal-1 로 자기를 밝힌다. */
@Component
public class StreamHandler extends TextWebSocketHandler {

    private final Conf conf;
    private final Map<String, Subscribers.Subscriber> subs = new ConcurrentHashMap<>();
    private volatile ExecutorService sharedPool;

    public StreamHandler(Conf conf) {
        this.conf = conf;
    }

    public Map<String, Subscribers.Subscriber> subscribers() {
        return subs;
    }

    @Override
    public void afterConnectionEstablished(WebSocketSession session) {
        String id = idOf(session);
        applyBlockingSendTimeout(session);
        Subscribers.Subscriber s = create(id, session);
        subs.put(id, s);
        s.start();
        System.out.println("[connect] " + id + " mode=" + conf.mode + " subscribers=" + subs.size());
    }

    @Override
    public void afterConnectionClosed(WebSocketSession session, CloseStatus status) {
        String id = idOf(session);
        Subscribers.Subscriber s = subs.get(id);
        if (s != null) {
            s.closed = true;
            if (s.closedAtMillis == 0) {
                s.closedAtMillis = System.currentTimeMillis();
                s.closeReason = "client/transport closed: " + status;
            }
            s.stop();
        }
        System.out.println("[disconnect] " + id + " status=" + status);
    }

    @Override
    public void handleTransportError(WebSocketSession session, Throwable ex) {
        System.out.println("[transport-error] " + idOf(session) + " " + ex);
    }

    /** 브로드캐스트. 모드에 따라 여기서 막히기도 하고(direct), 큐에 넣고 바로 돌아오기도 한다. */
    public void broadcast(Tick tick) {
        for (Subscribers.Subscriber s : subs.values()) {
            if (!s.closed) {
                s.offer(tick);
            }
        }
    }

    /** terminate/combo 모드의 감시자. 큐 바이트나 송신 지속시간이 임계를 넘으면 세션을 끊는다. */
    public void enforceLimits() {
        boolean terminateMode = "terminate".equals(conf.mode) || "combo".equals(conf.mode);
        if (!terminateMode) {
            return;
        }
        long now = System.currentTimeMillis();
        for (Subscribers.Subscriber s : subs.values()) {
            if (s.closed) {
                continue;
            }
            long started = s.sendStartedAtMillis;
            if (started > 0 && now - started > conf.sendTimeLimitMs) {
                s.closeNow("send time " + (now - started) + "ms exceeded limit " + conf.sendTimeLimitMs + "ms");
                System.out.println("[terminate] " + s.id + " " + s.closeReason);
                continue;
            }
            if (s.queuedBytes() > conf.bufferLimitBytes) {
                s.overLimitSeconds++;
                if (s.overLimitSeconds >= conf.overLimitSeconds) {
                    s.closeNow("buffer " + s.queuedBytes() + " bytes exceeded limit " + conf.bufferLimitBytes
                            + " for " + s.overLimitSeconds + "s");
                    System.out.println("[terminate] " + s.id + " " + s.closeReason);
                }
            } else {
                s.overLimitSeconds = 0;
            }
        }
    }

    private Subscribers.Subscriber create(String id, WebSocketSession session) {
        return switch (conf.mode) {
            case "direct" -> new Subscribers.Direct(id, session);
            case "unbounded" -> new Subscribers.Unbounded(id, session);
            case "bounded" -> new Subscribers.Bounded(id, session, conf.queueCapacity);
            case "conflate" -> new Subscribers.Conflate(id, session);
            case "terminate" -> new Subscribers.Terminate(id, session);
            case "combo" -> new Subscribers.Combo(id, session);
            case "decorator" ->
                new Subscribers.Decorated(id, session, conf.sendTimeLimitMs, conf.bufferLimitBytes, pool(), false);
            // 같은 데코레이터를 클라이언트별 전용 스레드 하나로만 쓴다.
            // 데코레이터의 한도 검사는 flush 락 경합이 있을 때만 도는데, 스레드가 하나면 경합이 없다.
            case "decorator-single" ->
                new Subscribers.Decorated(id, session, conf.sendTimeLimitMs, conf.bufferLimitBytes,
                        Executors.newSingleThreadExecutor(r -> {
                            Thread t = new Thread(r, "outbound-" + id);
                            t.setDaemon(true);
                            return t;
                        }), true);
            default -> throw new IllegalArgumentException("모르는 stream.mode: " + conf.mode);
        };
    }

    private ExecutorService pool() {
        ExecutorService p = sharedPool;
        if (p == null) {
            synchronized (this) {
                if (sharedPool == null) {
                    sharedPool = Executors.newFixedThreadPool(conf.poolThreads, r -> {
                        Thread t = new Thread(r, "outbound");
                        t.setDaemon(true);
                        return t;
                    });
                }
                p = sharedPool;
            }
        }
        return p;
    }

    /**
     * Tomcat의 블로킹 송신 제한시간은 세션 user property로 바꾼다.
     * 기본값을 그대로 두면 느린 클라이언트로의 송신이 20초쯤에서 끊기므로,
     * "무한 버퍼가 정말 힙을 다 먹는가"를 보려면 이 값을 명시적으로 풀어야 한다.
     */
    private void applyBlockingSendTimeout(WebSocketSession session) {
        if (conf.blockingSendTimeoutMs <= 0) {
            return;
        }
        try {
            if (session instanceof NativeWebSocketSession nws
                    && nws.getNativeSession() instanceof jakarta.websocket.Session js) {
                js.getUserProperties().put("org.apache.tomcat.websocket.BLOCKING_SEND_TIMEOUT",
                        Long.valueOf(conf.blockingSendTimeoutMs));
                System.out.println("[conf] BLOCKING_SEND_TIMEOUT=" + conf.blockingSendTimeoutMs + "ms 적용");
            } else {
                System.out.println("[conf] BLOCKING_SEND_TIMEOUT 적용 실패: 네이티브 세션 타입 불일치");
            }
        } catch (Throwable t) {
            System.out.println("[conf] BLOCKING_SEND_TIMEOUT 적용 실패: " + t);
        }
    }

    private static String idOf(WebSocketSession session) {
        String q = session.getUri() == null ? null : session.getUri().getQuery();
        if (q != null) {
            for (String part : q.split("&")) {
                if (part.startsWith("id=")) {
                    return part.substring(3);
                }
            }
        }
        return session.getId();
    }

    @Override
    protected void handleTextMessage(WebSocketSession session, TextMessage message) throws IOException {
        // 구독자는 아무것도 보내지 않는다. 받더라도 무시한다.
    }
}
