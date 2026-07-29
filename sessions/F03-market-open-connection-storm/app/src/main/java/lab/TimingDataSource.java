package lab;

import java.sql.Connection;
import java.sql.SQLException;

import javax.sql.DataSource;

import org.springframework.jdbc.datasource.DelegatingDataSource;

/**
 * HikariCP 앞에 끼워 커넥션 획득에 걸린 시간만 따로 잰다.
 * 성공한 획득과 2초를 넘겨 터진 획득을 나눠 담는다. 예외는 그대로 다시 던지므로
 * Spring의 예외 변환과 500 응답 경로는 계측 전과 같다.
 */
public class TimingDataSource extends DelegatingDataSource {

    private final Timings timings;

    public TimingDataSource(DataSource target, Timings timings) {
        super(target);
        this.timings = timings;
    }

    @Override
    public Connection getConnection() throws SQLException {
        long t0 = System.nanoTime();
        try {
            Connection c = super.getConnection();
            timings.acquireOk(System.nanoTime() - t0);
            return c;
        } catch (SQLException e) {
            timings.acquireFail(System.nanoTime() - t0);
            throw e;
        }
    }

    @Override
    public Connection getConnection(String username, String password) throws SQLException {
        long t0 = System.nanoTime();
        try {
            Connection c = super.getConnection(username, password);
            timings.acquireOk(System.nanoTime() - t0);
            return c;
        } catch (SQLException e) {
            timings.acquireFail(System.nanoTime() - t0);
            throw e;
        }
    }
}
