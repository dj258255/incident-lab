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
| 해소(유한성 가드+킬스위치) | 100 | 0 | 비정상 3건 감지 시점(103/120)에 접수 중단 |
