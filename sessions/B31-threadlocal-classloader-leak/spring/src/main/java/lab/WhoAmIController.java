package lab;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 컨트롤러는 ThreadLocal에서 사용자를 꺼내 쓴다. 헤더를 다시 읽지 않는다.
 * 응답에 처리 스레드 이름을 함께 실어, 같은 워커 스레드가 어떤 값을 물고 있는지 보이게 한다.
 */
@RestController
public class WhoAmIController {

    @GetMapping(value = {"/api/leaky/whoami", "/api/safe/whoami"}, produces = "text/plain;charset=UTF-8")
    public String whoami() {
        RequestContext.UserCtx ctx = RequestContext.get();
        return "thread=" + Thread.currentThread().getName()
                + " seenUser=" + (ctx == null ? "(none)" : ctx.user())
                + " requestNo=" + (ctx == null ? "-" : ctx.requestNo())
                + "\n";
    }
}
