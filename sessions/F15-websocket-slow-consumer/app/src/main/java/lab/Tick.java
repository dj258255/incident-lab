package lab;

import org.springframework.web.socket.TextMessage;

/**
 * 틱 하나. 브로드캐스트 대상 전원이 같은 TextMessage 인스턴스를 참조한다.
 * 그래서 느린 구독자 한 명이 큐에 참조를 붙들고 있으면 그 틱은 힙에서 회수되지 않는다.
 */
public record Tick(long seq, String symbol, long publishedAtMillis, TextMessage message, int bytes) {
}
