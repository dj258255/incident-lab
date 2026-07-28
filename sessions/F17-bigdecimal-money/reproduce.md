# 재현 기록

실행한 명령과 출력을 원문 그대로 남깁니다. 요약하지 않습니다.

## 환경

- 호스트: Rocky Linux 9 (aarch64), Docker 29.4.2, Docker Compose v5.1.3
- 이미지: eclipse-temurin:21-jdk-alpine (JDK 21로 컨테이너에서 컴파일·실행)
- 일시: 2026-07-28
- 데이터: 코드가 고정 시드로 생성(실험 2는 시드 42, 실험 3은 시드 7). 시간 측정이 없고 산술이 전부 결정적이라, 몇 번을 돌려도 같은 수치가 나옵니다. 출력 형식을 다듬는 사이 같은 날 4회 실행했고 측정 수치는 매번 같았습니다. 최종 코드로는 2회 실행해 출력이 바이트까지 동일함을 diff로 확인했습니다.

## 1. 기동과 실행

```console
$ docker compose up --abort-on-container-exit
 Network f17-bigdecimal-money_default Created
 Container lab-f17-money Started
```

## 2. 최초 실행에서 관측한 것 (%.9f 표시 문제)

처음에는 double 합계를 `String.format("%.9f", dSum)`으로 찍었습니다.

```console
lab-f17-money  |   double     합계 = 110099999.998313720 원
lab-f17-money  |   double 오차 = -0.001686275005340576171875 원  <- 대사가 안 맞는다
```

끝자리가 이상했습니다. 오차가 `-0.001686275…`원이면 합계는 `…998313724994…`여야 하는데 `…998313720`으로 찍혔습니다. 자바 Formatter의 `%f`는 이진값의 정확한 십진 전개를 계산하는 대신 `Double.toString`이 주는 17유효자리 최단 표현(`…99831372`)에 0을 채워 넣기 때문입니다. 오차를 보고하는 출력 자체가 표시 단계에서 한 번 더 왜곡된 셈이라, 합계 출력을 `new BigDecimal(dSum).toPlainString()`(이진값의 정확한 십진 전개)으로 바꾸고 오차 분해 라인을 추가했습니다. 합계와 오차 수치 자체는 바꾸기 전후가 동일했습니다.

## 3. 최종 실행 출력 (전문)

출력 전체가 짧아 그대로 싣습니다. 같은 내용이 [results/run-output.txt](results/run-output.txt)에 있습니다.

```console
$ docker compose up --abort-on-container-exit
lab-f17-money  | == F17 부동소수점 금지 재현 (JDK 21) ==
lab-f17-money  |
lab-f17-money  | [실험 1] 수수료 110.1원 x 1,000,000건 누적 합계 (정확값 110,100,000원)
lab-f17-money  |   double     합계 = 110099999.998313724994659423828125 원 (이진값의 정확한 십진 전개)
lab-f17-money  |   BigDecimal 합계 = 110100000.0 원
lab-f17-money  |   double 오차 = -0.001686275005340576171875 원  <- 대사가 안 맞는다
lab-f17-money  |   오차 분해: 110.1 표현 오차 몫  = -0.000000005684341886080801486968994140625 원
lab-f17-money  |              덧셈 반올림 누적 몫 = -0.001686269320998690091073513031005859375 원 (오차의 99.9997%)
lab-f17-money  |   (0.1 + 0.2) = 0.30000000000000004 | (0.1+0.2 == 0.3) = false
lab-f17-money  |
lab-f17-money  | [실험 2] 밴쿠버 방식: 지수 1000.000에서 무작위 갱신 60,000회 (고정 시드 42, 소수 3자리)
lab-f17-money  |   절삭(DOWN)        = 956.917
lab-f17-money  |   반올림(HALF_EVEN) = 986.817
lab-f17-money  |   무반올림 정밀값    = 986.836802
lab-f17-money  |   정밀값 대비 절삭 오차   = -29.919802 포인트 (버린 잔여 적산 29.919802와 크기 일치)
lab-f17-money  |   정밀값 대비 반올림 오차 = -0.019802 포인트
lab-f17-money  |
lab-f17-money  | [실험 3] 0.5원 경계 수수료 100,000건을 원 단위 반올림 (요율 0.15%, 고정 시드 7)
lab-f17-money  |   정확 합계      = 75,313,323 원
lab-f17-money  |   HALF_UP 합계   = 75,363,323 원 (정확 대비 +50,000 원)
lab-f17-money  |   HALF_EVEN 합계 = 75,313,422 원 (정확 대비 +99 원, 내림 49,901건/올림 50,099건)
lab-f17-money  |
lab-f17-money  | [실험 4] BigDecimal equals 함정: 같은 2,500원이 scale만 다르게 두 번 들어온다
lab-f17-money  |   a = new BigDecimal("2500.0"), b = new BigDecimal("2500.00")
lab-f17-money  |   a.equals(b) = false | a.compareTo(b) = 0
lab-f17-money  |   a.hashCode() = 775001 | b.hashCode() = 7750002
lab-f17-money  |   HashSet에 둘 다 넣으면 size = 2  <- 중복 제거 실패, 같은 돈이 두 번 산다
lab-f17-money  |
lab-f17-money  | == 해소 재계측 (scale·RoundingMode 명시, 최소 화폐단위 long) ==
lab-f17-money  | [해소 1] BigDecimal("110.1") 누적 오차 = 0.0 원 | long(0.1원 단위) 누적 오차 = 0 (합계 110,100,000.0 원)
lab-f17-money  |   주의: new BigDecimal(0.1) = 0.1000000000000000055511151231257827021181583404541015625
lab-f17-money  |         BigDecimal.valueOf(0.1) = 0.1  <- 문자열/valueOf로 만들어야 한다
lab-f17-money  | [해소 2] HALF_EVEN 지수 오차 = 0.019802 포인트 (절삭 29.919802의 1/1511)
lab-f17-money  | [해소 3] HALF_EVEN 편향 +99 원 vs HALF_UP 편향 +50,000 원 (100,000건)
lab-f17-money  | [해소 4] setScale(2) 통일 HashSet.size() = 1 | TreeSet(compareTo).size() = 1
lab-f17-money  |   주의: stripTrailingZeros().toString() = "2.5E+3" (지수 표기가 된다, 출력은 toPlainString 사용)
lab-f17-money exited with code 0
```

## 4. 정리

```console
$ docker compose down
 Container lab-f17-money Removed
 Network f17-bigdecimal-money_default Removed
```

## 측정값 요약

| 실험 | 조건 | 문제 방식 | 해소 방식 |
|---|---|---|---|
| 1 누적 합계 | 수수료 110.1원 x 100만 건 | double 오차 -0.001686275005340576171875원 | BigDecimal 오차 0.0원, long(0.1원 단위) 오차 0 |
| 2 지수 갱신 | 1000.000 시작, ±0.1 무작위 60,000회(시드 42), 소수 3자리 | 절삭 오차 -29.919802포인트 | HALF_EVEN 오차 -0.019802포인트 (1/1,511) |
| 3 반올림 편향 | 0.5원 경계 수수료 10만 건(시드 7), 원 단위 반올림 | HALF_UP +50,000원 | HALF_EVEN +99원 |
| 4 중복 제거 | "2500.0" vs "2500.00" | equals=false, HashSet size 2 | setScale(2) 통일·TreeSet 모두 size 1 |

실험 2의 절삭 오차는 매 갱신에서 버린 잔여를 적산한 값(29.919802)과 자리까지 일치합니다. 절삭 경로의 손실이 전부 절삭 자체에서 왔다는 내부 검산입니다.
