# 재현 기록

실행한 명령과 출력을 원문 그대로 남깁니다. 요약하지 않습니다.

## 환경

- 호스트: Rocky Linux 9.6 (aarch64), 2 vCPU, Docker 29.4.2, Docker Compose v5.1.3
- 이미지: postgres:16-alpine (저장 계층), eclipse-temurin:21-jdk-alpine (파싱·증거금 계층, JDK 21.0.11)
- 일시: 2026-07-28
- 데이터: 코드로 만든 하강 틱 10건(20.00 / 10.00 / 5.00 / 1.00 / 0.10 / 0.01 / 0.00 / -1.00 / -10.00 / -37.63). 마지막 -37.63만 CFTC Docket No. 21-19의 수치이고 나머지 9건은 합성값입니다.
- 증거금 파라미터: 계약승수 1,000배럴, 하우스 증거금 8,000달러/계약, 계좌 자본 100,000달러, 유지증거금은 요구증거금의 75%. 전부 이 세션에서 고른 값이고 CFTC 문서의 수치가 아닙니다.
- 이 세션은 부하 측정이 아니라 로직 재현이라 난수도 동시성도 없습니다. 아래 명령을 두 번 실행해 프로그램 출력이 한 글자도 다르지 않은 것을 확인했고, 이 기록에는 1회분을 그대로 씁니다.

## 1. 저장 계층 기동

```console
$ docker compose up -d db
 Network f09-negative-price_default Creating
 Network f09-negative-price_default Created
 Container lab-f09-pg Creating
 Container lab-f09-pg Created
 Container lab-f09-pg Starting
 Container lab-f09-pg Started
```

## 2. 저장 계층: CHECK (price > 0) 위반과 해소

`app/sql/01-storage.sql`이 버그 스키마에 틱 10건을 넣고, `app/sql/02-fixed.sql`이 제약을 도메인 하한·상한으로 바꾼 뒤 같은 틱을 다시 넣습니다. 제약 위반 메시지는 손대지 않은 psql 원문입니다.

```console
$ docker compose up sql
 Container lab-f09-pg Running
 Container lab-f09-sql Creating
 Container lab-f09-sql Created
Attaching to lab-f09-sql
 Container lab-f09-pg Waiting
 Container lab-f09-pg Healthy
 Container lab-f09-sql Starting
 Container lab-f09-sql Started
lab-f09-sql  |
lab-f09-sql  | == [버그 1] 저장 계층: CHECK (price > 0) 테이블에 하강 틱 10건을 넣는다 ==
lab-f09-sql  |
lab-f09-sql  | psql:/sql/01-storage.sql:14: NOTICE:  table "tick" does not exist, skipping
lab-f09-sql  | DROP TABLE
lab-f09-sql  | CREATE TABLE
lab-f09-sql  | INSERT 0 1
lab-f09-sql  | INSERT 0 1
lab-f09-sql  | INSERT 0 1
lab-f09-sql  | INSERT 0 1
lab-f09-sql  | INSERT 0 1
lab-f09-sql  | INSERT 0 1
lab-f09-sql  | psql:/sql/01-storage.sql:28: ERROR:  new row for relation "tick" violates check constraint "tick_price_check"
lab-f09-sql  | DETAIL:  Failing row contains (7, WTI, 0.00).
lab-f09-sql  | psql:/sql/01-storage.sql:29: ERROR:  new row for relation "tick" violates check constraint "tick_price_check"
lab-f09-sql  | DETAIL:  Failing row contains (8, WTI, -1.00).
lab-f09-sql  | psql:/sql/01-storage.sql:30: ERROR:  new row for relation "tick" violates check constraint "tick_price_check"
lab-f09-sql  | DETAIL:  Failing row contains (9, WTI, -10.00).
lab-f09-sql  | psql:/sql/01-storage.sql:31: ERROR:  new row for relation "tick" violates check constraint "tick_price_check"
lab-f09-sql  | DETAIL:  Failing row contains (10, WTI, -37.63).
lab-f09-sql  |
lab-f09-sql  | -- 보낸 틱 10건 중 몇 건이 저장됐는가
lab-f09-sql  |  stored | rejected
lab-f09-sql  | --------+----------
lab-f09-sql  |       6 |        4
lab-f09-sql  | (1 row)
lab-f09-sql  |
lab-f09-sql  |
lab-f09-sql  | -- 시세 화면과 증거금 엔진이 읽어 가는 최종가
lab-f09-sql  |  seq | last_price_system_sees
lab-f09-sql  | -----+------------------------
lab-f09-sql  |    6 |                   0.01
lab-f09-sql  | (1 row)
lab-f09-sql  |
lab-f09-sql  |
lab-f09-sql  | == [해소 1] 제약을 도메인 하한·상한으로 바꾸고 같은 틱을 다시 넣는다 ==
lab-f09-sql  |
lab-f09-sql  | ALTER TABLE
lab-f09-sql  | ALTER TABLE
lab-f09-sql  | INSERT 0 1
lab-f09-sql  | INSERT 0 1
lab-f09-sql  | INSERT 0 1
lab-f09-sql  | INSERT 0 1
lab-f09-sql  |
lab-f09-sql  | -- 바꾼 제약이 진짜 이상치는 여전히 막는가 (단위를 100배 틀린 틱)
lab-f09-sql  | psql:/sql/02-fixed.sql:23: ERROR:  new row for relation "tick" violates check constraint "tick_price_domain"
lab-f09-sql  | DETAIL:  Failing row contains (99, WTI, -3763.00).
lab-f09-sql  |
lab-f09-sql  | -- 다시 센 저장 결과
lab-f09-sql  |  stored | rejected
lab-f09-sql  | --------+----------
lab-f09-sql  |      10 |        0
lab-f09-sql  | (1 row)
lab-f09-sql  |
lab-f09-sql  |
lab-f09-sql  | -- 시세 화면과 증거금 엔진이 읽어 가는 최종가
lab-f09-sql  |  seq | last_price_system_sees
lab-f09-sql  | -----+------------------------
lab-f09-sql  |   10 |                 -37.63
lab-f09-sql  | (1 row)
lab-f09-sql  |
lab-f09-sql exited with code 0
```

## 3. 파싱·표시 계층과 증거금 계층

```console
$ docker compose up app
 Container lab-f09-app Creating
 Container lab-f09-app Created
Attaching to lab-f09-app
 Container lab-f09-app Starting
 Container lab-f09-app Started
lab-f09-app  | == F09 음수 유가 재현: 가격이 양수라는 가정이 계층마다 다르게 깨진다 (JDK 21.0.11) ==
lab-f09-app  | 틱 10건은 코드로 만든 하강 경로다. 마지막 -37.63 만 CFTC Docket 21-19 의 수치이고 나머지는 합성값이다.
lab-f09-app  | 저장 계층(CHECK 제약)은 app/sql 에서 Postgres 로 따로 잰다. 여기서는 파싱·표시 계층과 증거금 계층만 본다.
lab-f09-app  |
lab-f09-app  | [버그 2] 파싱·표시 계층: 부호를 상정하지 않은 파서 3종에 같은 틱을 넣는다
lab-f09-app  |   P1 부호 없는 정수 파서 | P2 숫자만 남기는 방어적 파서 | P3 32비트 무부호 확장 디코더
lab-f09-app  |
lab-f09-app  |   실제 틱   전문 필드   P1          P2          P3
lab-f09-app  |   --------------------------------------------------------------
lab-f09-app  |   20.00     2000        $20.00      $20.00      $20.00
lab-f09-app  |   0.01      1           $0.01       $0.01       $0.01
lab-f09-app  |   0.00      0           $0.00       $0.00       $0.00
lab-f09-app  |   -1.00     -100        예외 발생   $1.00       $42,949,671.96
lab-f09-app  |   -37.63    -3763       예외 발생   $37.63      $42,949,635.33
lab-f09-app  |
lab-f09-app  |   P1 틱 10건 중 일치 7건, 예외 3건, 예외 없이 값이 틀린 것 0건
lab-f09-app  |   P2 틱 10건 중 일치 7건, 예외 0건, 예외 없이 값이 틀린 것 3건 (-37.63 -> $37.63)
lab-f09-app  |   P3 틱 10건 중 일치 7건, 예외 0건, 예외 없이 값이 틀린 것 3건 (-37.63 -> $42,949,635.33)
lab-f09-app  |   P1 예외 원문: java.lang.NumberFormatException: Illegal leading minus sign on unsigned string -3763.
lab-f09-app  |
lab-f09-app  | [버그 3] 증거금 계층: 요구증거금 = min(계약 명목가치, 하우스 증거금)
lab-f09-app  |   파라미터(우리가 고른 값): 계약승수 1,000배럴, 하우스 증거금 $8,000.00/계약, 계좌 자본 $100,000.00
lab-f09-app  |   기준은 가격 60.00달러에서의 개설가능 12계약이다.
lab-f09-app  |
lab-f09-app  |   가격            명목가치    요구증거금   개설가능 계약수   기준 대비
lab-f09-app  |   --------------------------------------------------------------------
lab-f09-app  |   60.00          60,000.00      8,000.00                12      1.00배
lab-f09-app  |   20.00          20,000.00      8,000.00                12      1.00배
lab-f09-app  |   10.00          10,000.00      8,000.00                12      1.00배
lab-f09-app  |   8.00            8,000.00      8,000.00                12      1.00배
lab-f09-app  |   5.00            5,000.00      5,000.00                20      1.67배
lab-f09-app  |   2.70            2,700.00      2,700.00                37      3.08배
lab-f09-app  |   1.00            1,000.00      1,000.00               100      8.33배
lab-f09-app  |   0.10              100.00        100.00             1,000     83.33배
lab-f09-app  |   0.01               10.00         10.00            10,000    833.33배
lab-f09-app  |   0.00                0.00          0.00          제한없음           -
lab-f09-app  |   -37.63        -37,630.00    -37,630.00          제한없음           -
lab-f09-app  |
lab-f09-app  |   명목가치가 하우스 증거금 아래로 내려가는 분기점은 가격 8.00달러다. 그 아래부터 요구증거금이 가격을 따라 붕괴한다.
lab-f09-app  |   가격 2.70달러에서 개설가능 계약수가 기준의 3배를 넘고, 0.01달러에서는 10,000계약까지 열린다.
lab-f09-app  |   가격 0.00달러에서는 요구증거금이 0이라 계약 수 제한 자체가 사라진다.
lab-f09-app  |   맨 아랫줄은 음수 틱이 증거금 엔진까지 도달했을 때 우리 모델이 내는 값이다. CFTC 문서가 말한 경로는 아니다.
lab-f09-app  |   원문이 말한 경로는 음수 틱이 애초에 거부되는 쪽이고, 그것은 [버그 4] 에서 잰다.
lab-f09-app  |
lab-f09-app  | [버그 4] 음수 틱이 거부되면 평가액이 과대계상되어 자동 청산이 걸리지 않는다
lab-f09-app  |   계좌: 가격 0.10달러에서 1,000계약 매수(요구증거금이 계약당 $100.00까지 내려가 자본 전액으로 열린 수량이다)
lab-f09-app  |   유지증거금 = 요구증거금의 75% = $7,500.00 (두 경우 모두 같은 값을 쓴다)
lab-f09-app  |
lab-f09-app  |   시스템이 보는 가격 0.01달러 (음수 틱이 거부되고 남은 마지막 양수 틱)
lab-f09-app  |     계좌 순자산 $10,000.00 > 유지증거금 $7,500.00 -> 자동 청산 발동=false
lab-f09-app  |   실제 가격 -37.63달러
lab-f09-app  |     계좌 순자산 -$37,630,000.00 < 유지증거금 $7,500.00 -> 자동 청산 발동=true
lab-f09-app  |   평가액 과대계상 폭 $37,640,000.00
lab-f09-app  |
lab-f09-app  | [해소 2] 파싱: 부호를 명시적으로 허용하고 재직렬화 왕복으로 대조한다
lab-f09-app  |
lab-f09-app  |   실제 틱   전문 필드   해소 파서
lab-f09-app  |   --------------------------------------
lab-f09-app  |   20.00     2000        $20.00
lab-f09-app  |   0.01      1           $0.01
lab-f09-app  |   0.00      0           $0.00
lab-f09-app  |   -1.00     -100        -$1.00
lab-f09-app  |   -37.63    -3763       -$37.63
lab-f09-app  |
lab-f09-app  |   해소 파서 틱 10건 중 일치 10건, 예외 0건, 예외 없이 값이 틀린 것 0건
lab-f09-app  |   참고: 단위를 100배 틀린 전문 -376300 은 왕복 검증을 통과하므로 저장 계층의 도메인 하한이 따로 막아야 한다 -> -$3,763.00
lab-f09-app  |
lab-f09-app  | [해소 3] 증거금: 명목가치 연동을 끊는다
lab-f09-app  |
lab-f09-app  |   해소 A: 요구증거금 = 하우스 증거금 고정(명목가치 비연동)
lab-f09-app  |   가격            명목가치    요구증거금   개설가능 계약수   기준 대비
lab-f09-app  |   --------------------------------------------------------------------
lab-f09-app  |   60.00          60,000.00      8,000.00                12      1.00배
lab-f09-app  |   20.00          20,000.00      8,000.00                12      1.00배
lab-f09-app  |   10.00          10,000.00      8,000.00                12      1.00배
lab-f09-app  |   8.00            8,000.00      8,000.00                12      1.00배
lab-f09-app  |   5.00            5,000.00      8,000.00                12      1.00배
lab-f09-app  |   2.70            2,700.00      8,000.00                12      1.00배
lab-f09-app  |   1.00            1,000.00      8,000.00                12      1.00배
lab-f09-app  |   0.10              100.00      8,000.00                12      1.00배
lab-f09-app  |   0.01               10.00      8,000.00                12      1.00배
lab-f09-app  |   0.00                0.00      8,000.00                12      1.00배
lab-f09-app  |   -37.63        -37,630.00      8,000.00                12      1.00배
lab-f09-app  |
lab-f09-app  |   해소 B: 요구증거금 = max(하우스 증거금, 관측 변동폭 57.63 x 계약승수 1,000배럴)
lab-f09-app  |     가격 사다리 전 구간에서 요구증거금 57,630.00, 개설가능 1계약으로 고정된다. 가격 수준을 아예 보지 않는다.
lab-f09-app  |
lab-f09-app  | [해소 4] 같은 시나리오를 해소 규칙으로 다시 연다
lab-f09-app  |   규칙                                    가격 0.10에서 개설가능    -37.63 마감 시 계좌 순자산
lab-f09-app  |   --------------------------------------------------------------------------------------------
lab-f09-app  |   버그: min(명목가치, 하우스 증거금)                   1,000계약               -$37,630,000.00
lab-f09-app  |   해소 A: 하우스 증거금 고정                              12계약                  -$352,760.00
lab-f09-app  |   해소 B: 변동폭 연동                                      1계약                    $62,270.00
lab-f09-app  |
lab-f09-app  |   해소 뒤에는 -37.63 이 저장·파싱되므로 평가액이 실제와 같아진다.
lab-f09-app  |     해소 A 기준: 순자산 -$352,760.00 < 유지증거금 $72,000.00 -> 자동 청산 발동=true
lab-f09-app exited with code 0
```

## 4. 정리

```console
$ docker compose down
 Container lab-f09-app Stopping
 Container lab-f09-sql Stopping
 Container lab-f09-sql Stopped
 Container lab-f09-sql Removing
 Container lab-f09-app Stopped
 Container lab-f09-app Removing
 Container lab-f09-sql Removed
 Container lab-f09-pg Stopping
 Container lab-f09-app Removed
 Container lab-f09-pg Stopped
 Container lab-f09-pg Removing
 Container lab-f09-pg Removed
 Network f09-negative-price_default Removing
 Network f09-negative-price_default Removed
```

## 측정값 요약

### 저장 계층 (Postgres 16, 틱 10건)

| 제약 | 저장 | 거부 | 시스템이 보는 최종가 |
|---|---|---|---|
| `CHECK (price > 0)` | 6건 | 4건 (0.00 / -1.00 / -10.00 / -37.63) | 0.01 |
| `CHECK (price >= -1000.00 AND price <= 100000.00)` | 10건 | 0건 | -37.63 |

바꾼 제약도 단위를 100배 틀린 -3763.00은 `tick_price_domain` 위반으로 계속 거부합니다.

### 파싱·표시 계층 (틱 10건, 음수 3건 포함)

| 파서 | 일치 | 예외 | 예외 없이 값이 틀림 | -37.63을 무엇으로 읽는가 |
|---|---|---|---|---|
| P1 부호 없는 정수 파서 | 7건 | 3건 | 0건 | 읽지 못하고 중단 |
| P2 숫자만 남기는 방어적 파서 | 7건 | 0건 | 3건 | $37.63 |
| P3 32비트 무부호 확장 디코더 | 7건 | 0건 | 3건 | $42,949,635.33 |
| 해소: 부호 명시 + 왕복 검증 | 10건 | 0건 | 0건 | -$37.63 |

### 증거금 계층 (계약승수 1,000배럴, 하우스 증거금 8,000달러, 자본 100,000달러)

| 가격 | 버그 요구증거금 | 버그 개설가능 | 해소 A 요구증거금 | 해소 A 개설가능 |
|---|---|---|---|---|
| 60.00 | 8,000.00 | 12계약 | 8,000.00 | 12계약 |
| 8.00 | 8,000.00 | 12계약 | 8,000.00 | 12계약 |
| 5.00 | 5,000.00 | 20계약 | 8,000.00 | 12계약 |
| 2.70 | 2,700.00 | 37계약 (기준의 3.08배) | 8,000.00 | 12계약 |
| 1.00 | 1,000.00 | 100계약 | 8,000.00 | 12계약 |
| 0.10 | 100.00 | 1,000계약 | 8,000.00 | 12계약 |
| 0.01 | 10.00 | 10,000계약 (기준의 833.33배) | 8,000.00 | 12계약 |
| 0.00 | 0.00 | 제한없음 | 8,000.00 | 12계약 |

해소 B(변동폭 연동)는 가격 사다리 전 구간에서 요구증거금 57,630.00, 개설가능 1계약입니다.

### 평가액과 자동 청산 (가격 0.10에서 진입, 유지증거금은 요구증거금의 75%)

| 규칙 | 개설 수량 | -37.63 마감 시 계좌 순자산 | 자동 청산 |
|---|---|---|---|
| 버그, 시스템이 보는 가격 0.01 | 1,000계약 | $10,000.00 | 발동 안 함 |
| 버그, 실제 가격 -37.63 | 1,000계약 | -$37,630,000.00 | 발동해야 함 |
| 해소 A | 12계약 | -$352,760.00 | 발동 |
| 해소 B | 1계약 | $62,270.00 | 불필요 |

버그 상태의 평가액 과대계상 폭은 $37,640,000.00입니다.
