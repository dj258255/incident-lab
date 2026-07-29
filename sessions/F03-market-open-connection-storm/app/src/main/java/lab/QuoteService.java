package lab;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

/**
 * 시세 조회. 실제 조회는 인덱스 한 방이면 끝나지만, 여기서는 조회 한 건이 커넥션을
 * 약 50ms 점유하는 상황(느린 조인, 직렬화, 외부 시세 대기 등)을 pg_sleep으로 모델링한다.
 * 커넥션은 쿼리가 도는 동안 풀에서 빠져 있다가 끝나면 반환된다.
 *
 * DB 호출 전체 시간을 재고, 그 안에서 커넥션 획득에 걸린 시간(TimingDataSource가 잰 값)을
 * 빼 쿼리 시간만 남긴다. 중앙값 가운데 풀 대기의 몫을 가르려고 넣은 계측이다.
 */
@Service
public class QuoteService {

    private final JdbcTemplate jdbc;
    private final Timings timings;

    public QuoteService(JdbcTemplate jdbc, Timings timings) {
        this.jdbc = jdbc;
        this.timings = timings;
    }

    public int lookup(String symbol) {
        long t0 = System.nanoTime();
        try {
            // pg_sleep(0.05)를 교차 조인해 커넥션을 서버 측에서 약 50ms 잡아 둔다.
            Integer price = jdbc.queryForObject(
                    "SELECT q.price FROM quote q, pg_sleep(0.05) WHERE q.symbol = ?",
                    Integer.class, symbol);
            return price == null ? -1 : price;
        } finally {
            timings.dbCall(System.nanoTime() - t0);
        }
    }
}
