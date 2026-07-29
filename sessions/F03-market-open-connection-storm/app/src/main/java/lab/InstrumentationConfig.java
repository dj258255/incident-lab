package lab;

import javax.sql.DataSource;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jdbc.core.JdbcTemplate;

/**
 * JdbcTemplate이 쓰는 DataSource만 계측용으로 감싼다. 풀 자체(HikariDataSource)는 그대로다.
 * 스키마·시드 초기화는 원래 DataSource를 쓰므로 이 계측에 섞이지 않는다.
 */
@Configuration
public class InstrumentationConfig {

    @Bean
    public JdbcTemplate jdbcTemplate(DataSource dataSource, Timings timings) {
        return new JdbcTemplate(new TimingDataSource(dataSource, timings));
    }
}
