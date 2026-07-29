package lab;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.socket.config.annotation.EnableWebSocket;
import org.springframework.web.socket.config.annotation.WebSocketConfigurer;
import org.springframework.web.socket.config.annotation.WebSocketHandlerRegistry;

/**
 * 증권 MTS 실시간 시세 스트리밍 서버를 축소한 것이다.
 * 초당 수천 틱을 전체 구독자에게 브로드캐스트하고, 구독자 중 하나가 느리게 읽을 때
 * 서버가 어떻게 무너지는지(또는 무너지지 않는지)를 재는 것이 목적이다.
 */
@SpringBootApplication
@EnableWebSocket
public class StreamApp implements WebSocketConfigurer {

    private final StreamHandler handler;

    public StreamApp(StreamHandler handler) {
        this.handler = handler;
    }

    public static void main(String[] args) {
        // 힙이 마르면 어느 스레드에서 먼저 터지는지가 이 세션의 관심사라서 전역으로 잡아 둔다.
        Thread.setDefaultUncaughtExceptionHandler((t, e) -> {
            if (e instanceof OutOfMemoryError oom) {
                Metrics.recordOom("thread " + t.getName(), oom);
            } else {
                System.out.println("[uncaught] " + t.getName() + " " + e);
            }
        });
        SpringApplication.run(StreamApp.class, args);
    }

    @Override
    public void registerWebSocketHandlers(WebSocketHandlerRegistry registry) {
        registry.addHandler(handler, "/stream").setAllowedOriginPatterns("*");
    }
}
