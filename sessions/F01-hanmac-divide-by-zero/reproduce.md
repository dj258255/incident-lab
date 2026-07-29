# 재현 기록

실행한 명령과 출력을 원문 그대로 남깁니다. 요약하지 않습니다.

## 환경

- 호스트: Rocky Linux 9 (aarch64), Docker 29.4.2, Docker Compose v5.1.3
- 이미지: eclipse-temurin:21-jdk-alpine (JDK 21로 컨테이너에서 컴파일·실행)
- 일시: 2026-07-22
- 데이터: 코드로 생성한 주문 120건(정상 100 + 잔존일수 0으로 Infinity 유발 10 + 잔존일수 0·분자 0으로 NaN 유발 10)

## 1. 기동과 실행

```console
$ docker compose up --abort-on-container-exit
 Image eclipse-temurin:21-jdk-alpine Pulled
 Container lab-f01-hanmac  Started
```

## 2. 최초 실행에서 관측한 것 (상한 110)

처음에는 상·하한을 [90, 110]으로 두었습니다. 정상 주문가는 `100 * (1 + 3/30) = 100 * 1.1`이라 110으로 딱 상한에 걸치도록 설계했는데, 정상 주문이 한 건도 접수되지 않았습니다.

```console
lab-f01-hanmac  | == 버그 검증 결과 (총 120건) ==
lab-f01-hanmac  |   접수: 정상 0건, 비정상(NaN/Inf) 10건  <- 비정상이 시장에 나간다
```

원인은 부동소수점이었습니다. IEEE 754 double에서 `100 * 1.1`은 정확히 110이 아니라 `110.00000000000001`이라 `px > upper`(110.00000000000001 > 110)가 true가 되어 전량 거부됐습니다. F01의 주제(0으로 나눈 값)와 별개로, F17(부동소수점 금지)의 함정을 먼저 만난 것입니다.

## 3. 상한을 130으로 넓힌 뒤 (정상 케이스 분리)

정상 주문을 경계에서 떼어 놓기 위해 상한을 130으로 넓혔습니다. 이제 정상 100건은 접수되고, 0으로 나눈 주문의 행동만 남습니다.

```console
lab-f01-hanmac  | == 0으로 나눈 결과와 검증식 행동 ==
lab-f01-hanmac  |   Infinity 주문가 = Infinity | (px>upper)=true (px<lower)=false -> 거부됨
lab-f01-hanmac  |   NaN      주문가 = NaN | (px>upper)=false (px<lower)=false -> 둘 다 false라 안 걸림
lab-f01-hanmac  |
lab-f01-hanmac  | == 버그 검증 결과 (총 120건) ==
lab-f01-hanmac  |   접수: 정상 100건, 비정상(NaN/Inf) 10건  <- 비정상이 시장에 나간다
lab-f01-hanmac  |
lab-f01-hanmac  |   [킬스위치] 비정상 주문 3건 감지 -> 103/120건 처리 지점에서 접수 중단
lab-f01-hanmac  | == 해소 검증(유한성 가드 + 킬스위치) 결과 ==
lab-f01-hanmac  |   접수: 정상 100건, 비정상 0건 | 비정상 거부 3건, 킬스위치 발동=true
```

> 위 출력은 실행 원문 그대로입니다. 다만 "비정상 0건"은 유한성 가드의 성과가 아닙니다. 드라이버 루프가 `!Double.isFinite(px)`로 먼저 걸러 내고 3건째에 `break`하므로 `acceptFixed`의 유한성 검사는 이 실행에서 한 번도 실행되지 않았고, 걸러 낸 3건은 전부 Infinity이며 뒤에 있던 NaN 10건은 평가조차 되지 않았습니다. 게다가 이 자리에 출력되는 `fixBad` 변수는 코드 어디에서도 증가하지 않아 무엇을 넣고 돌리든 0으로 찍힙니다. 0건은 킬스위치가 만든 결과이고, 가드가 NaN을 막는지는 아직 확인하지 못했습니다. 정상 100건이 전부 접수된 것도 정상 주문을 배치 앞에 몰아넣은 순서 덕이라, 섞인 배치에서의 부수 피해는 측정하지 않았습니다.

## 4. 정리

```console
$ docker compose down
 Container lab-f01-hanmac  Removed
 Network f01-hanmac-divide-by-zero_default  Removed
```

## 측정값 요약

| 구분 | 정상 접수 | 비정상 접수 | 비고 |
|---|---|---|---|
| 버그 검증 | 100 | 10 (NaN) | Infinity 10건은 `>상한`에 걸려 거부, NaN 10건만 뚫림 |
| 해소(유한성 가드+킬스위치) | 100 | 0 | 비정상 3건(전부 Infinity) 감지 시점(103/120)에 접수 중단. 0건은 킬스위치의 결과이고 가드 단독 효과는 미검증 |

## 실제 스택(Spring Boot) 재현

최소 재현이 검증 로직만 떼어냈다면, 같은 버그가 실제 Spring Boot 주문접수 API를 통과하는지도 확인했습니다. 코드는 `spring/` 아래에 있고, `docker compose up --build`로 Spring Boot 3.3(내장 Tomcat)이 뜬 뒤 드라이버가 주문 120건을 세 엔드포인트에 실제 HTTP로 보냅니다. 환경은 gradle:8.10-jdk21로 빌드하고 eclipse-temurin:21-jre-alpine로 실행했습니다.

```console
$ cd spring && docker compose up --build
INFO 1 --- [main] o.s.b.w.embedded.tomcat.TomcatWebServer : Tomcat started on port 8080 (http) with context path '/'
INFO 1 --- [main] lab.OrderApp : Started OrderApp in 7.516 seconds (process running for 9.146)

== [Spring] 실제 주문접수 API 재현 (POST /orders, 내장 Tomcat + Jackson + @Valid) ==
  /orders/buggy      : 201 접수 110건 (정상 100 + NaN 10), 422 거부 10건 (Infinity는 상한 초과)
  /orders/bigdecimal : 201 접수 100건, 500 서버오류 20건 (BigDecimal.valueOf(NaN/Inf) 예외)
  /orders/fixed      : 201 접수 100건, 422 거부 3건, 503 킬스위치 17건 (비정상 3건에서 발동)
  입력 @Valid 검증은 전부 통과했다. 문제는 입력이 아니라 서버가 계산한 파생값이다.
```

`/orders/bigdecimal`이 500을 낸 원인은 `BigDecimal`이 NaN과 Infinity를 표현하지 못해서입니다. `BigDecimal.valueOf(double)`은 내부에서 `Double.toString`의 결과를 파싱하므로 "Infinity"의 첫 글자 `I`에서 예외가 납니다. 실제 예외 원문 발췌는 [results/spring-run.txt](results/spring-run.txt)에 남겼습니다.

```console
java.lang.NumberFormatException: Character I is neither a decimal digit number, decimal point, nor "e" notation exponential mark.
    at java.base/java.math.BigDecimal.<init>(Unknown Source)
    at java.base/java.math.BigDecimal.valueOf(Unknown Source)
    at lab.OrderController.bigdecimal(OrderController.java)
```

### Spring 측정값 요약

| 엔드포인트 | 201 접수 | 422 거부 | 500 오류 | 503 킬스위치 |
|---|---|---|---|---|
| `/orders/buggy` | 110 (정상 100 + NaN 10) | 10 (Inf) | 0 | 0 |
| `/orders/bigdecimal` | 100 | 0 | 20 | 0 |
| `/orders/fixed` | 100 | 3 | 0 | 17 |

`/orders/fixed`의 422 3건은 전부 Infinity이고, 503 17건은 Infinity 7건과 NaN 10건입니다. 배치가 정상 100건, Infinity 10건, NaN 10건 순서라 Infinity 세 건에서 킬스위치가 발동했고, 그 뒤로는 컨트롤러가 가격을 계산하기도 전에 503을 돌려줍니다. 유한성 가드가 실제로 판정한 값은 Infinity 세 건이 전부이고, 버그 경로를 뚫었던 NaN은 가드 앞까지 오지 않았습니다.

입력 `@Valid`가 전부 통과한 것은 발견이 아닙니다. `OrderRequest`의 제약은 `@NotNull` 세 개가 전부라, 검증이 도는 것을 보이려고 넣은 구성입니다. 여기서 확인되는 것은 입력 검증이 보는 자리와 위험한 값이 만들어지는 자리가 다르다는 배치입니다.

버그 경로의 수치(정상 100 접수, NaN 10 통과, 킬스위치 3건째 발동)는 최소 재현과 맞물립니다.
