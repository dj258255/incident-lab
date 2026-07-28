package lab;

import jakarta.validation.constraints.NotNull;

/**
 * 클라이언트가 보내는 값은 전부 유한한 정상 숫자다(base, numerator, days).
 * 표준 JSON은 NaN/Infinity를 표현하지 못하므로, 비정상 값은 클라이언트가 보내는 게 아니라
 * 서버가 price = base * (1 + numerator/days)를 계산하는 순간 days==0에서 만들어진다.
 * 한맥도 그랬다. 나쁜 값은 외부 입력이 아니라 내부 계산에서 나왔다.
 *
 * @NotNull은 입력 검증(@Valid)이 도는 것을 보이기 위한 것이고, 실제로 전부 통과한다.
 * 문제는 입력이 아니라 '파생값'이라는 점을 이 세션이 드러낸다.
 */
public record OrderRequest(
        @NotNull Double base,
        @NotNull Double numerator,
        @NotNull Double days) {
}
