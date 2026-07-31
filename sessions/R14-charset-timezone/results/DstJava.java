import java.time.*;
import java.time.format.DateTimeFormatter;

public class DstJava {
    public static void main(String[] a) {
        ZoneId ny = ZoneId.of("America/New_York");
        DateTimeFormatter F = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss zzz XXX");

        // 결손: 2026-03-08 02:30 은 존재하지 않는다(02:00 에서 03:00 으로 건너뜀).
        LocalDateTime gap = LocalDateTime.of(2026, 3, 8, 2, 30);
        ZonedDateTime g = gap.atZone(ny);
        System.out.println("결손 02:30");
        System.out.println("  atZone 결과      = " + g.format(F));
        System.out.println("  에러 없이 " + (g.toLocalTime().equals(LocalTime.of(2,30)) ? "그대로" : "이동됨")
                + " 처리됩니다. 예외를 던지지 않습니다.");

        // 중복: 2026-11-01 01:30 은 두 번 온다(EDT 와 EST).
        LocalDateTime dup = LocalDateTime.of(2026, 11, 1, 1, 30);
        ZonedDateTime early = dup.atZone(ny).withEarlierOffsetAtOverlap();
        ZonedDateTime later = dup.atZone(ny).withLaterOffsetAtOverlap();
        System.out.println();
        System.out.println("중복 01:30");
        System.out.println("  기본(atZone)     = " + dup.atZone(ny).format(F));
        System.out.println("  withEarlier      = " + early.format(F));
        System.out.println("  withLater        = " + later.format(F));
        System.out.println("  두 순간의 차이   = "
                + Duration.between(early.toInstant(), later.toInstant()).toSeconds() + "초");
        System.out.println("  atZone 의 기본값은 앞의 것(EDT)입니다. 뒤의 것을 고르려면");
        System.out.println("  withLaterOffsetAtOverlap 을 명시해야 합니다. 안 쓰면 매년 이 한 시간에");
        System.out.println("  들어온 요청이 한 시간 앞으로 기록됩니다.");

        // 저장 뒤에는 구별되지 않는다는 것을 보인다.
        System.out.println();
        System.out.println("LocalDateTime 으로만 저장하면");
        System.out.println("  early -> LocalDateTime = " + early.toLocalDateTime());
        System.out.println("  later -> LocalDateTime = " + later.toLocalDateTime());
        System.out.println("  같습니다. 오프셋을 버리면 두 순간이 한 값으로 뭉갭니다.");
        System.out.println("  MySQL 의 DATETIME 이 정확히 이 상태이고, TIMESTAMP 는 UTC 로 저장해 구별합니다.");
    }
}
