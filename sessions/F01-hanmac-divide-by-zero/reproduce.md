# 재현 기록

실행한 명령과 출력을 원문 그대로 남깁니다. 요약하지 않습니다.

## 환경

- 호스트: Rocky Linux 9 (aarch64), Docker 29.4.2, Docker Compose v5.1.3
- 호스트 사양: `uname -srm` = `Linux 5.14.0-570.33.2.el9_6.aarch64 aarch64`, `nproc` = 2, `free -g` 총 메모리 11GiB (스왑 7GiB)
- 이미지: eclipse-temurin:21-jdk-alpine (JDK 21로 컨테이너에서 컴파일·실행)
- 컨테이너 자원 한도: 지정하지 않았습니다. `cpus`, `mem_limit`, `-Xmx` 모두 기본값입니다
- 일시: 최초 측정 2026-07-22, 재측정 2026-07-29
- 데이터: 코드로 생성한 주문 120건(정상 100 + 잔존일수 0으로 Infinity 유발 10 + 잔존일수 0·분자 0으로 NaN 유발 10)

이 세션은 결정적 산술이라 실행 시간이나 처리량을 재지 않습니다. 호스트 사양은 재현 조건을 밝히기 위해 적었고, 아래 수치는 호스트 성능에 좌우되지 않습니다. 배치를 섞을 때 쓴 시드는 20131212(사건 발생일)로 코드에 박아 두었으므로 몇 번 돌려도 같은 순서가 나옵니다.

```console
$ uname -srm
Linux 5.14.0-570.33.2.el9_6.aarch64 aarch64
$ nproc
2
$ free -g
               total        used        free      shared  buff/cache   available
Mem:              11           2           1           0           6           8
Swap:              7           0           7
```

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
```

## 4. 해소 검증 조건별 재측정 (2026-07-29)

2026-07-22 실행의 해소 검증은 성과를 가르지 못했습니다. 드라이버 루프가 `!Double.isFinite(px)`로 먼저 걸러 내고 3건째에 `break`했기 때문에 `acceptFixed`의 유한성 검사가 한 번도 실행되지 않았고, 뒤에 있던 NaN 10건은 평가조차 되지 않았습니다. 게다가 출력의 "비정상 0건" 자리에 들어가는 `fixBad` 변수는 증가 경로가 코드에 없어 무엇을 넣고 돌리든 0으로 찍히는 값이었습니다.

재측정에서는 셋을 고쳤습니다.

1. 루프의 사전 필터를 걷어내 화이트리스트(`acceptFixed`)가 120건 전부를 판정하게 했습니다.
2. 접수된 값을 종류로 갈라 세는 경로를 넣어 `fixBad`가 실제로 증가할 수 있게 했습니다. 같은 카운터를 버그 검증에도 통과시켜 10을 찍는 것으로 이 경로가 동작함을 확인합니다.
3. `acceptFixed` 안에 계측 카운터를 두어, 유한성 검사가 몇 번 참이 됐는지를 Infinity와 NaN으로 나눠 셉니다.

그 위에 킬스위치 켬/끔과 정렬/섞은 배치를 조합한 네 조건을 돌렸습니다. 아래는 실행 출력 원문입니다. 전문은 [results/minimal-run.txt](results/minimal-run.txt)에 있습니다.

```console
$ docker compose up --abort-on-container-exit
lab-f01-hanmac  | == 해소 검증 조건별 결과 (임계값 3건, 섞음 시드 20131212) ==
lab-f01-hanmac  |
lab-f01-hanmac  | [조건 A] 유한성 가드 + 킬스위치 · 정렬 배치
lab-f01-hanmac  |   처리 103/120건, 킬스위치 발동=true (103건째에서 중단)
lab-f01-hanmac  |   접수: 정상 100건, 비정상 0건
lab-f01-hanmac  |   유한성 가드가 거부: Infinity 3건, NaN 0건
lab-f01-hanmac  |   평가되지 않고 남은 주문: 17건 (그중 정상 0건 = 킬스위치 부수 피해)
lab-f01-hanmac  |
lab-f01-hanmac  | [조건 B] 유한성 가드 단독(킬스위치 끔) · 정렬 배치
lab-f01-hanmac  |   처리 120/120건, 킬스위치 발동=false
lab-f01-hanmac  |   접수: 정상 100건, 비정상 0건
lab-f01-hanmac  |   유한성 가드가 거부: Infinity 10건, NaN 10건
lab-f01-hanmac  |   평가되지 않고 남은 주문: 0건 (그중 정상 0건 = 킬스위치 부수 피해)
lab-f01-hanmac  |
lab-f01-hanmac  | [조건 C] 유한성 가드 + 킬스위치 · 섞은 배치
lab-f01-hanmac  |   처리 19/120건, 킬스위치 발동=true (19건째에서 중단)
lab-f01-hanmac  |   접수: 정상 16건, 비정상 0건
lab-f01-hanmac  |   유한성 가드가 거부: Infinity 2건, NaN 1건
lab-f01-hanmac  |   평가되지 않고 남은 주문: 101건 (그중 정상 84건 = 킬스위치 부수 피해)
lab-f01-hanmac  |
lab-f01-hanmac  | [조건 D] 유한성 가드 단독(킬스위치 끔) · 섞은 배치
lab-f01-hanmac  |   처리 120/120건, 킬스위치 발동=false
lab-f01-hanmac  |   접수: 정상 100건, 비정상 0건
lab-f01-hanmac  |   유한성 가드가 거부: Infinity 10건, NaN 10건
lab-f01-hanmac  |   평가되지 않고 남은 주문: 0건 (그중 정상 0건 = 킬스위치 부수 피해)
lab-f01-hanmac  |
lab-f01-hanmac  | == 요약 (비정상 접수 / 가드가 거부한 Inf + NaN / 정상 접수 / 정상 부수 차단) ==
lab-f01-hanmac  |   10 /   -  +  -  / 100 /   0   버그 검증 · 정렬 배치
lab-f01-hanmac  |    0 /   3  +  0  / 100 /   0   조건 A 가드 + 킬스위치 · 정렬 배치
lab-f01-hanmac  |    0 /  10  + 10  / 100 /   0   조건 B 가드 단독 · 정렬 배치
lab-f01-hanmac  |    0 /   2  +  1  /  16 /  84   조건 C 가드 + 킬스위치 · 섞은 배치
lab-f01-hanmac  |    0 /  10  + 10  / 100 /   0   조건 D 가드 단독 · 섞은 배치
```

조건 A는 2026-07-22 실행과 같은 조건입니다. 킬스위치 발동 지점(103/120)과 거부 3건이 그대로 재현됐고, 가드가 판정한 값이 Infinity 3건뿐이었다는 것이 이번에는 출력으로 확인됩니다.

조건 B가 이 재측정의 목적입니다. 킬스위치를 끄면 120건 전부가 화이트리스트를 지나고, 가드가 Infinity 10건과 NaN 10건을 모두 거부합니다. 비정상 접수는 0건입니다. 이 0은 카운터가 없어서 나온 0이 아니라 증가 경로가 있는데도 증가하지 않은 0입니다. 같은 카운터가 버그 검증에서는 10을 찍습니다.

조건 C가 킬스위치의 부수 피해입니다. 배치를 섞으면 비정상 주문이 앞쪽에도 섞여 들어와 19건째에서 임계값 3건에 닿습니다. 그 시점까지 접수된 정상 주문은 16건이고, 뒤에 남은 정상 84건은 평가되지 않았습니다. 정상 100건 중 84건이 킬스위치에 함께 막힌 것입니다. 조건 D와 비교하면 이 84건이 가드가 아니라 킬스위치의 결과임이 갈립니다. 가드 단독은 배치 순서를 바꿔도 정상 100건 접수, 비정상 0건 접수로 같습니다.

## 5. 정리

```console
$ docker compose down
 Container lab-f01-hanmac  Removed
 Network f01-hanmac-divide-by-zero_default  Removed
```

## 측정값 요약

| 조건 | 킬스위치 | 배치 | 처리 | 정상 접수 | 비정상 접수 | 가드가 거부(Inf/NaN) | 정상 부수 차단 |
|---|---|---|---|---|---|---|---|
| 버그 검증 | 없음 | 정렬 | 120/120 | 100 | 10 (전부 NaN) | 해당 없음 | 0 |
| 조건 A | 켬(임계 3) | 정렬 | 103/120 | 100 | 0 | 3 / 0 | 0 |
| 조건 B | 끔 | 정렬 | 120/120 | 100 | 0 | 10 / 10 | 0 |
| 조건 C | 켬(임계 3) | 섞음 | 19/120 | 16 | 0 | 2 / 1 | 84 |
| 조건 D | 끔 | 섞음 | 120/120 | 100 | 0 | 10 / 10 | 0 |

버그 검증에서 Infinity 10건은 `px > upper`에 걸려 거부되고 NaN 10건만 뚫립니다. 조건 B와 D가 보이는 것은 유한성 화이트리스트만으로도 비정상 접수가 0건이 되고 NaN 10건이 실제로 가드에서 거부된다는 것입니다. 킬스위치가 없어도 0건이므로, 조건 A의 0건을 킬스위치의 성과로 읽을 근거는 없습니다. 반대로 킬스위치는 조건 C에서 정상 주문 84건을 함께 막았습니다.

## 실제 스택(Spring Boot) 재현

최소 재현이 검증 로직만 떼어냈다면, 같은 버그가 실제 Spring Boot 주문접수 API를 통과하는지도 확인했습니다. 코드는 `spring/` 아래에 있고, `docker compose up --build`로 Spring Boot 3.3(내장 Tomcat)이 뜬 뒤 드라이버가 주문 120건을 엔드포인트에 실제 HTTP로 보냅니다. 환경은 gradle:8.10-jdk21로 빌드하고 eclipse-temurin:21-jre-alpine로 실행했습니다. 호스트 8080이 다른 서비스에 점유돼 있어 컨테이너의 8080을 호스트 18080으로 내보냈습니다. 드라이버는 컨테이너 안에서 `localhost:8080`으로 호출하므로 이 매핑은 측정에 영향을 주지 않습니다.

엔드포인트는 넷입니다. `/orders/buggy`(원시 비교), `/orders/bigdecimal`(BigDecimal 강화 시도), `/orders/guard`(유한성 가드 단독), `/orders/fixed`(가드 + 킬스위치)입니다. `/orders/guard`는 재측정에서 추가한 것으로, `/orders/fixed`와 킬스위치 유무 한 변수만 다릅니다. 조건 사이에는 드라이버가 `Killswitch.reset()`으로 상태를 되돌립니다.

```console
$ cd spring && docker compose up --build
INFO 1 --- [main] o.s.b.w.embedded.tomcat.TomcatWebServer : Tomcat started on port 8080 (http) with context path '/'
INFO 1 --- [main] lab.OrderApp : Started OrderApp in 8.117 seconds (process running for 10.005)

== [Spring] 실제 주문접수 API 재현 (POST /orders, 내장 Tomcat + Jackson + @Valid) ==
  /orders/buggy      : 201 접수 110건 (정상 100 + NaN 10), 422 거부 10건 (Infinity는 상한 초과)
  /orders/bigdecimal : 201 접수 100건, 500 서버오류 20건 (BigDecimal.valueOf(NaN/Inf) 예외)
  /orders/fixed      : 201 접수 100건, 422 거부 3건, 503 킬스위치 17건 (비정상 3건에서 발동)
  입력 @Valid 검증은 전부 통과했다. 문제는 입력이 아니라 서버가 계산한 파생값이다.

== [Spring] 조건별 재측정 (가드 단독 / 킬스위치 · 정렬 / 섞은 배치, 섞음 시드 20131212) ==

[조건 A] /orders/fixed · 정렬 배치 · 유한성 가드 + 킬스위치
  201 접수     100건 (정상 100 / Inf 0 / NaN 0)
  422 거부       3건 (정상 0 / Inf 3 / NaN 0)
  503 킬스위치  17건 (정상 0 / Inf 7 / NaN 10)  <- 정상 0건이 부수 피해

[조건 B] /orders/guard · 정렬 배치 · 유한성 가드 단독
  201 접수     100건 (정상 100 / Inf 0 / NaN 0)
  422 거부      20건 (정상 0 / Inf 10 / NaN 10)
  503 킬스위치   0건 (정상 0 / Inf 0 / NaN 0)  <- 정상 0건이 부수 피해

[조건 C] /orders/fixed · 섞은 배치 · 유한성 가드 + 킬스위치
  201 접수      16건 (정상 16 / Inf 0 / NaN 0)
  422 거부       3건 (정상 0 / Inf 2 / NaN 1)
  503 킬스위치 101건 (정상 84 / Inf 8 / NaN 9)  <- 정상 84건이 부수 피해

[조건 D] /orders/guard · 섞은 배치 · 유한성 가드 단독
  201 접수     100건 (정상 100 / Inf 0 / NaN 0)
  422 거부      20건 (정상 0 / Inf 10 / NaN 10)
  503 킬스위치   0건 (정상 0 / Inf 0 / NaN 0)  <- 정상 0건이 부수 피해
```

`/orders/bigdecimal`이 500을 낸 원인은 `BigDecimal`이 NaN과 Infinity를 표현하지 못해서입니다. `BigDecimal.valueOf(double)`은 내부에서 `Double.toString`의 결과를 파싱하므로 "Infinity"의 첫 글자 `I`에서 예외가 납니다. 실제 예외 원문 발췌는 [results/spring-run.txt](results/spring-run.txt)에 남겼습니다.

```console
java.lang.NumberFormatException: Character I is neither a decimal digit number, decimal point, nor "e" notation exponential mark.
    at java.base/java.math.BigDecimal.<init>(Unknown Source)
    at java.base/java.math.BigDecimal.valueOf(Unknown Source)
    at lab.OrderController.bigdecimal(OrderController.java:61)
```

### Spring 측정값 요약

| 조건 | 엔드포인트 | 배치 | 201 접수 | 422 거부 | 500 오류 | 503 킬스위치 |
|---|---|---|---|---|---|---|
| 버그 | `/orders/buggy` | 정렬 | 110 (정상 100 + NaN 10) | 10 (Inf) | 0 | 0 |
| BigDecimal 시도 | `/orders/bigdecimal` | 정렬 | 100 | 0 | 20 | 0 |
| 조건 A | `/orders/fixed` | 정렬 | 100 | 3 (Inf 3) | 0 | 17 (Inf 7 + NaN 10) |
| 조건 B | `/orders/guard` | 정렬 | 100 | 20 (Inf 10 + NaN 10) | 0 | 0 |
| 조건 C | `/orders/fixed` | 섞음 | 16 (정상 16) | 3 (Inf 2 + NaN 1) | 0 | 101 (정상 84 + Inf 8 + NaN 9) |
| 조건 D | `/orders/guard` | 섞음 | 100 | 20 (Inf 10 + NaN 10) | 0 | 0 |

조건 A의 422 3건은 전부 Infinity이고, 503 17건은 Infinity 7건과 NaN 10건입니다. 정렬 배치가 정상 100건, Infinity 10건, NaN 10건 순서라 Infinity 세 건에서 킬스위치가 발동했고, 그 뒤로는 컨트롤러가 가격을 계산하기도 전에 503을 돌려줍니다. 이 조건에서 유한성 가드가 실제로 판정한 값은 Infinity 세 건이 전부입니다.

조건 B에서 그 분포가 달라집니다. 킬스위치가 없으니 422가 20건이 되고, 그중 10건이 NaN입니다. 버그 경로를 뚫었던 NaN이 가드 앞까지 와서 실제로 거부된 것이 이 조건에서 확인됩니다.

조건 C는 킬스위치의 부수 피해입니다. 503 101건 중 84건이 정상 주문입니다. 최소 재현의 조건 C(19건째 발동, 정상 16건 접수, 정상 84건 미평가)와 건수가 그대로 맞물립니다.

입력 `@Valid`가 전부 통과한 것은 발견이 아닙니다. `OrderRequest`의 제약은 `@NotNull` 세 개가 전부라, 검증이 도는 것을 보이려고 넣은 구성입니다. 여기서 확인되는 것은 입력 검증이 보는 자리와 위험한 값이 만들어지는 자리가 다르다는 배치입니다.

버그 경로의 수치(정상 100 접수, NaN 10 통과, 킬스위치 3건째 발동)는 최소 재현과 맞물립니다.
