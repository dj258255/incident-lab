package lab;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

/**
 * 시세 조회. 실제 조회는 인덱스 한 방이면 끝나지만, 여기서는 조회 한 건이 커넥션을
 * 약 50ms 점유하는 상황(느린 조인, 직렬화, 외부 시세 대기 등)을 pg_sleep으로 모델링한다.
 * 커넥션은 쿼리가 도는 동안 풀에서 빠져 있다가 끝나면 반환된다.
 */
@Service
public class QuoteService {

    private final JdbcTemplate jdbc;

    public QuoteService(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public int lookup(String symbol) {
        // pg_sleep(0.05)를 교차 조인해 커넥션을 서버 측에서 약 50ms 잡아 둔다.
        Integer price = jdbc.queryForObject(
                "SELECT q.price FROM quote q, pg_sleep(0.05) WHERE q.symbol = ?",
                Integer.class, symbol);
        return price == null ? -1 : price;
    }
}
