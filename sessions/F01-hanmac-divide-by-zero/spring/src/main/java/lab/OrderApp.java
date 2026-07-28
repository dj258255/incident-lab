package lab;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * F01 한맥 재현의 '실제 스택' 버전. 최소 재현(../app/Hanmac.java)이 검증 로직만 떼어냈다면,
 * 여기서는 같은 버그가 진짜 Spring Boot 주문접수 REST API(내장 Tomcat + Jackson + Bean Validation)를
 * 통과하는지 확인한다. 증권사가 뽑는 환경이 이 스택이라, 도달성을 실측으로 보인다.
 */
@SpringBootApplication
public class OrderApp {
    public static void main(String[] args) {
        SpringApplication.run(OrderApp.class, args);
    }
}
