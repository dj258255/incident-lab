package lab;

import java.io.IOException;
import java.util.Map;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.atomic.AtomicLong;

import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.ConcurrentWebSocketSessionDecorator;
import org.springframework.web.socket.handler.SessionLimitExceededException;

/** 구독자별 송신 전략. 모드마다 하나씩 있다. */
public final class Subscribers {

    private Subscribers() {
    }

    /** 공통 뼈대. */
    public abstract static class Subscriber {
        final String id;
        final WebSocketSession session;
        final AtomicLong delivered = new AtomicLong();
        final AtomicLong dropped = new AtomicLong();
        volatile boolean closed;
        volatile String closeReason = "";
        volatile long closedAtMillis;
        /** 버퍼 상한을 연속으로 넘긴 초 수. 일시적 적체와 진짜 느린 소비자를 가른다. */
        volatile int overLimitSeconds;
        /** 현재 진행 중인 송신 한 건이 시작된 시각. 0이면 진행 중인 송신 없음. */
        volatile long sendStartedAtMillis;

        Subscriber(String id, WebSocketSession session) {
            this.id = id;
            this.session = session;
        }

        public abstract void offer(Tick tick);

        public abstract int queuedMessages();

        public abstract long queuedBytes();

        public void start() {
        }

        public void stop() {
        }

        void sendBlocking(TextMessage msg) throws IOException {
            sendStartedAtMillis = System.currentTimeMillis();
            try {
                session.sendMessage(msg);
                delivered.incrementAndGet();
            } finally {
                sendStartedAtMillis = 0;
            }
        }

        void closeNow(String reason) {
            if (closed) {
                return;
            }
            closed = true;
            closeReason = reason;
            closedAtMillis = System.currentTimeMillis();
            try {
                session.close(CloseStatus.SESSION_NOT_RELIABLE.withReason(reason));
            } catch (Throwable ignored) {
                // 이미 끊어진 소켓이면 무시한다.
            }
        }
    }

    /**
     * [버그 A] 브로드캐스터 스레드가 세션마다 sendMessage를 직접 부른다.
     * 손으로 짠 팬아웃에서 가장 흔한 모양이다. 큐가 없으므로 힙은 늘지 않지만,
     * 느린 구독자 하나에서 블로킹되면 그 뒤 구독자와 다음 틱 발행 전체가 멈춘다.
     */
    public static final class Direct extends Subscriber {
        Direct(String id, WebSocketSession session) {
            super(id, session);
        }

        @Override
        public void offer(Tick tick) {
            if (closed) {
                return;
            }
            try {
                sendBlocking(tick.message());
            } catch (Throwable t) {
                closeNow("send failed: " + t.getClass().getSimpleName() + ": " + t.getMessage());
            }
        }

        @Override
        public int queuedMessages() {
            return 0;
        }

        @Override
        public long queuedBytes() {
            return 0;
        }
    }

    /** 큐 + 전용 송신 스레드를 쓰는 모드들의 공통 뼈대. */
    abstract static class QueueSubscriber extends Subscriber {
        final AtomicLong bytes = new AtomicLong();
        private Thread sender;

        QueueSubscriber(String id, WebSocketSession session) {
            super(id, session);
        }

        @Override
        public void start() {
            sender = new Thread(this::loop, "sender-" + id);
            sender.setDaemon(true);
            sender.start();
        }

        @Override
        public void stop() {
            if (sender != null) {
                sender.interrupt();
            }
        }

        abstract TextMessage take() throws InterruptedException;

        private void loop() {
            while (!closed && !Thread.currentThread().isInterrupted()) {
                try {
                    TextMessage msg = take();
                    if (msg == null) {
                        continue;
                    }
                    sendBlocking(msg);
                } catch (InterruptedException e) {
                    return;
                } catch (OutOfMemoryError oom) {
                    Metrics.recordOom(id, oom);
                    closeNow("OOM: " + oom.getMessage());
                    return;
                } catch (Throwable t) {
                    closeNow("send failed: " + t.getClass().getSimpleName() + ": " + t.getMessage());
                    return;
                }
            }
        }

        @Override
        public long queuedBytes() {
            return bytes.get();
        }
    }

    /**
     * [버그 B] 클라이언트별 무한 큐. 교과서가 말하는 "백프레셔 없는 팬아웃"이다.
     * 브로드캐스터는 절대 막히지 않는 대신, 느린 구독자의 큐가 힙을 계속 먹는다.
     */
    public static class Unbounded extends QueueSubscriber {
        private final BlockingQueue<TextMessage> queue = new LinkedBlockingQueue<>();

        Unbounded(String id, WebSocketSession session) {
            super(id, session);
        }

        @Override
        public void offer(Tick tick) {
            if (closed) {
                return;
            }
            queue.add(tick.message());
            bytes.addAndGet(tick.bytes());
        }

        @Override
        TextMessage take() throws InterruptedException {
            TextMessage m = queue.take();
            bytes.addAndGet(-m.getPayloadLength());
            return m;
        }

        @Override
        public int queuedMessages() {
            return queue.size();
        }
    }

    /**
     * [해소 1] 클라이언트별 바운디드 큐. 가득 차면 가장 오래된 틱을 버린다(drop-oldest).
     * 시세는 오래된 값일수록 쓸모가 없으므로 최신을 버리는 것보다 낫다.
     */
    public static final class Bounded extends QueueSubscriber {
        private final ArrayBlockingQueue<TextMessage> queue;

        Bounded(String id, WebSocketSession session, int capacity) {
            super(id, session);
            this.queue = new ArrayBlockingQueue<>(capacity);
        }

        @Override
        public void offer(Tick tick) {
            if (closed) {
                return;
            }
            while (!queue.offer(tick.message())) {
                TextMessage old = queue.poll();
                if (old == null) {
                    break;
                }
                bytes.addAndGet(-old.getPayloadLength());
                dropped.incrementAndGet();
            }
            bytes.addAndGet(tick.bytes());
        }

        @Override
        TextMessage take() throws InterruptedException {
            TextMessage m = queue.take();
            bytes.addAndGet(-m.getPayloadLength());
            return m;
        }

        @Override
        public int queuedMessages() {
            return queue.size();
        }
    }

    /**
     * [해소 2] conflation. 종목별로 최신 틱 하나만 남긴다.
     * 대기 중인 메시지 수의 상한이 종목 수로 고정되므로 큐 크기를 따로 튜닝할 필요가 없다.
     */
    public static class Conflate extends QueueSubscriber {
        private final Map<String, TextMessage> latest = new ConcurrentHashMap<>();
        private final BlockingQueue<String> pending = new LinkedBlockingQueue<>();
        private final java.util.Set<String> queued = ConcurrentHashMap.newKeySet();

        Conflate(String id, WebSocketSession session) {
            super(id, session);
        }

        @Override
        public void offer(Tick tick) {
            if (closed) {
                return;
            }
            TextMessage prev = latest.put(tick.symbol(), tick.message());
            if (prev != null) {
                // 아직 못 보낸 이전 틱을 덮어썼다. 이 클라이언트는 그 틱을 영영 못 본다.
                bytes.addAndGet(-prev.getPayloadLength());
                dropped.incrementAndGet();
            }
            bytes.addAndGet(tick.bytes());
            if (queued.add(tick.symbol())) {
                pending.add(tick.symbol());
            }
        }

        @Override
        TextMessage take() throws InterruptedException {
            String sym = pending.take();
            queued.remove(sym);
            TextMessage m = latest.remove(sym);
            if (m != null) {
                bytes.addAndGet(-m.getPayloadLength());
            }
            return m;
        }

        @Override
        public int queuedMessages() {
            return latest.size();
        }
    }

    /**
     * [해소 3] 느린 소비자 절단. 무한 큐를 그대로 두되 감시자가 임계를 넘으면 세션을 끊는다.
     * Spring의 ConcurrentWebSocketSessionDecorator가 STOMP 경로에서 하는 일을
     * 직접 짠 브로드캐스트 경로에 옮겨 놓은 것이다.
     */
    public static final class Terminate extends Unbounded {
        Terminate(String id, WebSocketSession session) {
            super(id, session);
        }
    }

    /** [해소 4] conflation + 절단. 실무에서 쓰는 조합. */
    public static final class Combo extends Conflate {
        Combo(String id, WebSocketSession session) {
            super(id, session);
        }
    }

    /**
     * [프레임워크 기본] Spring의 ConcurrentWebSocketSessionDecorator를 그대로 쓴다.
     * 공유 송신 풀의 여러 스레드가 같은 세션으로 보내려 할 때만 데코레이터의 한도 검사가 돈다.
     * 그래서 여기서는 클라이언트별 전용 스레드가 아니라 공유 풀을 쓴다(Spring STOMP 경로와 같은 구조).
     */
    public static final class Decorated extends Subscriber {
        private final ConcurrentWebSocketSessionDecorator decorator;
        private final ExecutorService pool;
        private final boolean ownsPool;

        Decorated(String id, WebSocketSession session, int sendTimeLimitMs, int bufferLimitBytes,
                ExecutorService pool, boolean ownsPool) {
            super(id, session);
            this.decorator = new ConcurrentWebSocketSessionDecorator(session, sendTimeLimitMs, bufferLimitBytes);
            this.pool = pool;
            this.ownsPool = ownsPool;
        }

        @Override
        public void stop() {
            if (ownsPool) {
                pool.shutdownNow();
            }
        }

        @Override
        public void offer(Tick tick) {
            if (closed) {
                return;
            }
            try {
                pool.execute(() -> {
                    if (closed) {
                        return;
                    }
                    try {
                        sendStartedAtMillis = System.currentTimeMillis();
                        decorator.sendMessage(tick.message());
                        delivered.incrementAndGet();
                    } catch (SessionLimitExceededException e) {
                        closeNow("ConcurrentWebSocketSessionDecorator: " + e.getMessage());
                    } catch (OutOfMemoryError oom) {
                        Metrics.recordOom(id, oom);
                        closeNow("OOM: " + oom.getMessage());
                    } catch (Throwable t) {
                        closeNow("send failed: " + t.getClass().getSimpleName() + ": " + t.getMessage());
                    } finally {
                        sendStartedAtMillis = 0;
                    }
                });
            } catch (Throwable t) {
                dropped.incrementAndGet();
            }
        }

        @Override
        public int queuedMessages() {
            return decorator.getBufferSize() > 0 ? -1 : 0; // 데코레이터는 건수를 노출하지 않는다
        }

        @Override
        public long queuedBytes() {
            return decorator.getBufferSize();
        }
    }

}
