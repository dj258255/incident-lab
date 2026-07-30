# 재현 기록

실행한 명령과 출력을 남깁니다. 이 문서의 콘솔 블록은 옮겨 적은 것이므로 원문은 결과 파일 쪽입니다.
k6 요약 전문은 [results/buggy-k6.txt](results/buggy-k6.txt), [results/fixed-k6.txt](results/fixed-k6.txt)에,
앱이 잰 계층별 시간과 큐 길이는 `results/raw/<라벨>-stats.txt`에, 앱 로그 원문은
`results/raw/<라벨>-app.log.gz`에 통째로 있습니다. 수치가 갈리면 결과 파일을 기준으로 봐야 합니다.

**2026-07-29 재측정본입니다.** 2026-07-28 1차 측정에는 세 가지 문제가 있었고 이번에 고쳤습니다.

| 1차(2026-07-28)에 있던 문제 | 이번 회차 |
|---|---|
| 버그 경로에서 `dropped_iterations 3401`. 앱에 도달한 요청이 6,598건과 9,959건으로 51% 달랐다 | VU를 5,000으로 올려 양쪽 다 0건, 도달 요청 9,999건으로 같음 |
| 앱 로그 집계가 저장소 안에서 541과 27로 갈렸다 | 로그를 통째로 저장해 다시 셈. 일곱 실행 전부 앱 예외 수 = k6가 받은 500 수 |
| 503 응답 지연과 계층별 몫을 재지 않았다 | 상태코드별 지연과 계층별 시간을 계측해 잼 |

1차 측정 파일은 git 이력에 남아 있습니다.

## 환경

- 호스트: `uname -srm`은 `Linux 5.14.0-570.33.2.el9_6.aarch64`, `nproc` 2, `free -g`의 total 11(GiB). Rocky Linux 9.6 한 대에 Docker
- 자원 배치: Postgres와 앱과 부하 생성기 k6가 모두 이 한 대에서 돌았고 compose에 컨테이너 CPU 제한을 걸지 않았습니다
- **측정 직전 부하**: 이 호스트에는 모니터링 스택(Prometheus·Loki·Grafana·cadvisor)과 다른 서비스가 상주합니다. 그리고 2026-07-26부터 `dockerd`가 계속 코어 하나를 통째로 쓰고 있습니다(20초 동안 2,080틱 = 논리 코어 하나의 104%). 재는 동안 이 조건을 바꾸지 못했으므로 아래 지연 수치에는 그만큼의 경합이 섞여 있습니다. 실행마다 `uptime`을 찍어 `results/raw/<라벨>-load.txt`에 남겼습니다
  - 헤드라인 두 실행의 직전 load average: 버그 4.87, 해소 3.87
  - 반복 실행은 앞 실행의 부하가 아직 가라앉기 전이라 9.25와 11.50이었습니다. 그런데도 결과가 크게 다르지 않아, 아래 "반복 실행" 절의 범위로 적었습니다
- 앱: Spring Boot 3.3.5 / Java 21, 내장 Tomcat. gradle:8.10-jdk21로 빌드, eclipse-temurin:21-jre-alpine로 실행
- DB: postgres:16-alpine
- HikariCP: 풀 10, connection-timeout 2000ms. Tomcat accept-count 1000, threads.max 200(Spring Boot 기본값과 같음)
- 부하: grafana/k6, 도착률 모델(ramping-arrival-rate) 초당 400건, 5s 램프 + 20s 유지 + 5s 감소, `preAllocatedVUs = maxVUs = 5000`
- 일시: 2026-07-29

## 0. 실행 방법

조건 하나를 재는 일을 스크립트로 묶었습니다. 컨테이너를 새로 띄우고, `/health`가 응답할 때까지
기다리고, `uptime`을 찍고, k6를 돌리고, `/stats`와 앱 로그 전문을 받아 저장한 뒤 내립니다.

```console
$ RATE=400 VUS=5000 RAMP=5s HOLD=20s DOWN=5s bash scripts/one-run.sh buggy buggy
$ RATE=400 VUS=5000 RAMP=5s HOLD=20s DOWN=5s bash scripts/one-run.sh fixed fixed
$ TOMCAT_MAX_THREADS=10   RATE=400 VUS=5000 bash scripts/one-run.sh buggy-t10   buggy
$ TOMCAT_MAX_THREADS=50   RATE=400 VUS=5000 bash scripts/one-run.sh buggy-t50   buggy
$ TOMCAT_MAX_THREADS=1000 RATE=400 VUS=5000 bash scripts/one-run.sh buggy-t1000 buggy
```

`/health`와 `/stats`는 호스트 포트 18083으로 받습니다. 부하 경로가 아니라 관측용입니다.
부하(k6)는 1차와 같이 compose 네트워크 안에서 `app:8080`으로 붙습니다.

**계측을 넣다가 앱을 두 번 망가뜨렸습니다.** 재현에 걸림돌이 됐으므로 적어 둡니다.

- `PoolSampler`가 Tomcat 스레드 풀을 찾으려고 `Tomcat.getConnector()`를 불렀습니다. 이 메서드는
  서비스에 커넥터가 하나도 없으면 8080짜리를 새로 만들어 붙입니다. Spring Boot는 기동 도중
  커넥터를 잠시 떼어 두었다가 `start()`에서 되돌리는데, 샘플러 스레드가 하필 그 창에서 부르면
  커넥터가 둘이 되어 진짜 커넥터가 바인드에 실패합니다. `Port 8080 was already in use`로 죽었고,
  하필 새로 생긴 쪽이 `/health`에 응답해서 기동에 성공한 것처럼 보였습니다. `findConnectors()`로
  읽기만 하도록 고쳤습니다.
- 같은 샘플러가 `java.util.concurrent.ThreadPoolExecutor`로 형 검사를 해서 Tomcat 스레드 수가
  계속 -1로 찍혔습니다. 내장 Tomcat의 작업 스레드 풀은 `org.apache.tomcat.util.threads.ThreadPoolExecutor`입니다.

## 1. 기동

```console
$ docker compose up -d --build
 Container lab-f03-db   Healthy
 Container lab-f03-app  Started
$ docker logs lab-f03-app | grep -E "HikariPool|Tomcat started|Started MtsApp"
 quote-pool - Added connection org.postgresql.jdbc.PgConnection@...
 Tomcat started on port 8080 (http) with context path '/'
 Started MtsApp in 8.193 seconds
```

## 2. 버그 경로 부하 (/quote/buggy, 부하 차단 없음)

```console
$ uptime
 15:53:07 up 103 days,  3:07,  0 users,  load average: 4.87, 4.91, 3.75

  http_req_duration..: avg=11.15s min=52.22ms med=11.42s max=22.32s p(90)=20.15s p(95)=20.96s
  http_req_failed....: 7.61%  761 out of 9999
  http_reqs..........: 9999   200.167992/s
  dropped_iterations.: (0건이라 k6가 줄을 내지 않는다)
  cnt_200 9238   cnt_500 761   cnt_503 0   cnt_noresp 0
```

목표 도착률의 10,000회 가운데 9,999회가 발사됐습니다. 1차의 `dropped_iterations 3401`이 0이 됐고,
앱에 도달한 요청이 6,598건에서 9,999건으로 늘었습니다. 열린 모델이 이번에는 유지됐습니다.

대신 지연이 1차보다 훨씬 나빠졌습니다. 중앙값이 3.38초에서 11.42초입니다. 1차가 덜 나빠 보였던
것은 VU가 모자라 도착률이 절반으로 눌렸기 때문이고, 진짜 초당 400건을 부으면 이렇게 됩니다.

부하 중 앱 로그입니다. 풀 열 개가 모두 사용 중이고 획득 대기 큐에 186건이 쌓여 있습니다.

```console
$ zcat results/raw/buggy-app.log.gz | grep "Connection is not available" | head -1
java.sql.SQLTransientConnectionException: quote-pool - Connection is not available,
    request timed out after 2000ms (total=10, active=10, idle=0, waiting=186)
$ zcat results/raw/buggy-app.log.gz | grep -c "Connection is not available"
761
```

**앱 로그 집계와 k6 집계가 맞습니다.** 1차에서 541과 27로 갈렸던 자리입니다. 이번에는 로그를
통째로 저장해 두 계층을 같이 셌고, 일곱 실행 전부에서 앱이 던진 예외 수와 k6가 받은 500 응답 수가
같았습니다.

| 실행 | 앱 로그 예외 | k6가 받은 500 | http_reqs |
|---|---|---|---|
| buggy | 761 | 761 | 9,999 |
| buggy-r2 | 1,268 | 1,268 | 9,998 |
| buggy-t10 | 0 | 0 | 9,999 |
| buggy-t50 | 26 | 26 | 9,999 |
| buggy-t1000 | 3,945 | 3,945 | 9,999 |
| fixed | 0 | 0 | 9,999 |
| fixed-r2 | 0 | 0 | 9,998 |

따라서 버그 경로의 500 응답은 전부 HikariCP 커넥션 획득 타임아웃입니다. 1차의 27이 무엇이었는지는
여전히 모르지만, 이제 이 세션이 그 값에 기대지 않습니다.

## 3. 중앙값 11.42초의 계층별 몫

앱에 계측을 넣어 갈랐습니다. 서블릿 필터가 진입부터 응답 완료까지를 재고(`inapp_<상태코드>`),
그 안에서 HikariCP 커넥션 획득에 걸린 시간을 따로 잽니다(`pool_acquire_ok`). 필터에 닿았다는 것은
이미 Tomcat 작업 스레드를 잡았다는 뜻이므로, k6가 잰 시간에서 필터 시간을 빼면 스레드를 기다린
시간이 남습니다.

```console
$ curl -s http://127.0.0.1:18083/stats
# 설정  pool=10 connection-timeout=2000ms tomcat.threads.max=200 accept-count=1000 shed.permits=10

inapp_200            count=9238  min=50.46ms   p50=1014.66ms p95=2017.37ms max=2127.07ms
inapp_500            count=761   min=2000.20ms p50=2000.70ms p95=2013.42ms max=2271.47ms
pool_acquire_ok      count=9238  min=0.00ms    p50=962.97ms  p95=1964.18ms max=2001.94ms
pool_acquire_timeout count=761   min=2000.06ms p50=2000.29ms p95=2009.25ms max=2152.99ms
query_after_acquire  count=9238  min=50.25ms   p50=50.61ms   p95=55.68ms   max=171.54ms

최댓값  hikari_active=10 hikari_waiting=191 tomcat_busy=200 tomcat_queue=4335 tomcat_conn=4995
```

중앙값 11.42초 가운데 앱 안에서 쓴 시간은 1.01초입니다. 그 1.01초의 대부분인 0.96초가 풀 획득
대기이고 쿼리가 0.05초입니다. 나머지 약 10.4초는 서블릿 필터에 닿기도 전에 쌓인 것, 즉 Tomcat
작업 스레드를 기다린 시간입니다. 중앙값의 약 9%가 풀 계층, 약 91%가 스레드 계층입니다.

중앙값끼리 뺀 값이라 엄밀하게는 근사입니다. 근사에 기대지 않는 하한은 이렇게 나옵니다. 앱 안에서
잰 시간의 최댓값이 2.13초이므로, 중앙값 11.42초짜리 요청은 적어도 9.3초를 앱 밖에서 기다렸습니다.

`max-threads`를 바꿔 가며 확인했습니다. 전문은 [results/thread-sweep.txt](results/thread-sweep.txt)에 있습니다.

| max-threads | k6 중앙값 | 앱 안 p50 | 풀 획득 p50 | 500 응답 | hikari_waiting 최대 |
|---|---|---|---|---|---|
| 10 | 13.54s | 51.28ms | 0.00ms | 0 | 0 |
| 50 | 13.38s | 59.66ms | 0.04ms | 26 | 41 |
| 200 (기본값) | 11.42s | 1,014.66ms | 962.97ms | 761 | 191 |
| 1000 | 11.17s | 1,701.09ms | 1,589.14ms | 3,945 | 901 |

획득 대기 큐의 최대치가 `max-threads`에서 풀 크기 10을 뺀 값과 거의 같습니다(0 / 41 / 191 / 901).
커넥션을 기다릴 수 있는 요청 수는 작업 스레드 수가 정합니다. 스레드를 늘리면 대기가 없어지는 것이
아니라 스레드 계층에서 풀 계층으로 옮겨 가고, 풀 대기가 2초 상한을 넘기는 순간 500이 됩니다.
네 조건 모두 처리량은 초당 180~224건에 머뭅니다.

`accept-count 1000`에 대해 한 가지 바로잡습니다. 이 값은 커널 listen 백로그일 뿐이고, 앱이 동시에
붙들 수 있는 요청 수를 정하지 않습니다. 실제로 소켓을 붙들고 있는 것은 Tomcat의 `max-connections`
(기본 8192)이고, 계측에서 열린 소켓이 4,995개까지 올라갔습니다.

## 4. 해소 경로 부하 (/quote/fixed, 부하 차단 permits=10)

버그 경로와 **완전히 같은 설정**입니다. 초당 400건, 같은 램프, `preAllocatedVUs = maxVUs = 5000`.

```console
$ uptime
 15:54:40 up 103 days,  3:09,  0 users,  load average: 3.87, 4.68, 3.78

  http_req_duration..: avg=48.82ms min=370.8µs med=51.04ms max=755.9ms p(95)=188.86ms
  http_reqs..........: 9999   333.082171/s
  dur_200_ok.........: avg=70ms    min=50.75ms med=51.94ms p(90)=95.87ms  p(95)=188.46ms
  dur_503_shed.......: avg=29.63ms min=370.8µs med=1ms     p(90)=123.09ms p(95)=189ms
  cnt_200 4754   cnt_503 5245   cnt_500 0   cnt_noresp 0
$ zcat results/raw/fixed-app.log.gz | grep -c "Connection is not available"
0
```

앱에 도달한 요청이 9,999건으로 버그 경로와 같습니다. `dropped_iterations`도 양쪽 0입니다.
따라서 이번 회차에서는 두 경로가 같은 부하를 받았다고 말할 수 있습니다.

**503 응답 지연을 상태코드별로 태깅해 쟀습니다.** 1차에서 근거 없이 "1ms 만에 돌려보낸다"고 적었다가
지운 자리입니다. 클라이언트 기준 503의 중앙값은 1ms, p90 123ms, p95 189ms입니다. 앱 안에서 잰 값은
중앙값 0.57ms입니다. 중앙값은 실제로 1ms 남짓이 맞지만 꼬리는 훨씬 깁니다.

```console
inapp_200            count=4754  min=50.53ms p50=51.42ms p95=75.13ms  max=442.85ms
inapp_503            count=5245  min=0.15ms  p50=0.57ms  p95=29.92ms  max=266.48ms
pool_acquire_ok      count=4754  min=0.00ms  p50=0.01ms  p95=0.02ms   max=389.48ms
pool_acquire_timeout count=0     (표본 없음)

최댓값  hikari_active=10 hikari_waiting=1 tomcat_busy=44 tomcat_queue=76 tomcat_conn=2535
```

획득 대기 큐가 최대 1이고 작업 스레드는 200개 중 최대 44개만 썼습니다. 부하 차단이 앞에서
막아 주니 두 계층 모두 쌓이지 않았습니다.

## 5. 1차의 connection refused 1,324건은 무엇이었나

1차 해소 경로에는 200도 503도 아닌 실패가 1,324건 있었고, 세션 기록은 그것을 "램프업 첫 6초에 몰린
워밍업"이라고 적어 두었습니다. 이번에는 0건입니다. 원인을 가르려고 두 가지를 따로 확인했습니다.

먼저 VU를 미리 잡아 두지 않은 것이 원인인지 봤습니다. 1차와 같은 `preAllocatedVUs 200 / maxVUs 900`으로
해소 경로를 다시 돌렸습니다.

```console
$ RATE=400 VUS=900 PREVUS=200 bash scripts/one-run.sh diag-fixed-prealloc200 fixed
  cnt_200 4294   cnt_503 5705   cnt_noresp 0   http_reqs 9999
```

0건입니다. VU 할당 방식은 원인이 아닙니다.

다음으로 앱이 아직 듣기 전에 부하를 시작한 것인지 봤습니다. 1차 기록은 `docker compose restart app`
바로 뒤에 k6를 띄웠는데, 앱이 기동을 마치는 데 8초에서 15초가 걸립니다. 기동 대기를 빼고 똑같이 해 봤습니다.

```console
$ (기동 대기 없이 곧바로 k6)
  cnt_noresp 5310   (전부 error_code=1212, dial: connection refused)
  NORESP 시각 분포(초):  0초 35건 · 1초 115 · 2초 196 · 3초 276 · 4초 355 · 5초 399 · 6~14초 각 400 · 15초 333
  앱 로그: Started MtsApp in 14.961 seconds
```

**램프업 곡선을 그대로 따라갑니다.** 0초 35건에서 시작해 5초에 399건이 되고 그 뒤로는 초당 400건입니다.
앱이 듣기 시작한 15초에 딱 멈춥니다. 실패 건수는 램프업 시간이 아니라 앱이 기동을 마칠 때까지의
시간이 정합니다. 1차의 1,324건은 이 곡선을 약 5초에서 자른 값(약 1,000 + 400)과 맞습니다.

따라서 1차의 connection refused는 램프업 자체가 만든 것이 아니라 **앱이 듣기 전에 부하를 시작한
것**입니다. 램프업을 늘려서 없애는 것이 아니라 `/health`를 기다린 뒤 시작해야 없어지고, 이번
회차의 스크립트는 그렇게 합니다. 램프업 길이는 1차와 같은 5초 그대로입니다.

원자료는 `results/raw/diag-nowait-k6.txt.gz`에 있습니다.

## 6. 반복 실행

같은 조건을 두 번씩 돌렸습니다. 두 번째 실행은 앞 실행의 부하가 남아 직전 load average가 9.25와
11.50이었습니다.

| 조건 | 실행 | 직전 load | http_reqs | 중앙값 | p95 | 500 응답 |
|---|---|---|---|---|---|---|
| 버그 | 1회 | 4.87 | 9,999 | 11.42s | 20.96s | 761 |
| 버그 | 2회 | 9.25 | 9,998 | 11.06s | 19.39s | 1,268 |
| 해소 | 1회 | 3.87 | 9,999 | 51.04ms | 188.86ms | 0 |
| 해소 | 2회 | 11.50 | 9,998 | 51.56ms | 275.13ms | 0 |

버그 경로 중앙값은 11.06~11.42초, 500 응답은 761~1,268건입니다. 500 건수가 1.7배 흔들립니다.
풀 대기가 2초 상한 근처에 몰려 있어서(획득 성공 p95가 1.96초) 경합이 조금만 달라져도 상한을
넘는 건수가 크게 바뀝니다. 해소 경로는 중앙값 51ms 안팎으로 안정적입니다.

## 7. 정리

```console
$ docker compose down -v
 Container lab-f03-app  Removed
 Container lab-f03-db   Removed
 Network f03-market-open-connection-storm_default  Removed
```

## 측정값 요약

| 구분 | 응답 중앙값 | p95 | 500 응답 | http_reqs | dropped_iterations | 처리 |
|---|---|---|---|---|---|---|
| 버그 (부하 차단 없음) | 11.42s | 20.96s | 761건 | 9,999 | 0 | 풀 고갈, 획득 대기 큐 191, 스레드 대기 큐 4,335 |
| 해소 (부하 차단 permits=10) | 51.04ms | 188.86ms | 0건 | 9,999 | 0 | 정상 4,754 · 503 흘려보냄 5,245(중앙값 1ms) |

풀 설정과 부하 설정이 양쪽 같고 부하 차단 유무만 다릅니다. 앱에 도달한 요청 수도 9,999건으로 같습니다.
평상시 시세 조회는 약 50ms입니다.
