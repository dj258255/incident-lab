package lab;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * F03 장 시작 접속 폭주 재현. 증권 MTS의 시세 조회 API를 축소한 것이다.
 * 조회 한 건이 DB 커넥션을 약 50ms 점유하므로, HikariCP 풀 10으로는 초당 약 200건이 한계다.
 * 09:00 정각에 트래픽이 그 한계를 넘겨 쏟아지면 커넥션 획득이 큐에 쌓여 타임아웃으로 무너진다.
 * 버그 경로는 그대로 받고, 해소 경로는 부하 차단(load shedding)으로 들어올 양을 제한한다.
 */
@SpringBootApplication
public class MtsApp {
    public static void main(String[] args) {
        SpringApplication.run(MtsApp.class, args);
    }
}
