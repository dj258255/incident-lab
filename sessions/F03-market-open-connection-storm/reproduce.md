# 재현 기록

실행한 명령과 출력을 원문 그대로 남깁니다. k6 요약 전문은 [results/buggy-k6.txt](results/buggy-k6.txt),
[results/fixed-k6.txt](results/fixed-k6.txt)에, 앱 로그의 풀 고갈 증거는 [results/hikari-timeout.txt](results/hikari-timeout.txt)에 있습니다.

## 환경

- 호스트: Rocky Linux 9 (aarch64), Docker
- 앱: Spring Boot 3.3.5 / Java 21, 내장 Tomcat. gradle:8.10-jdk21로 빌드, eclipse-temurin:21-jre-alpine로 실행
- DB: postgres:16-alpine
- HikariCP: 풀 10, connection-timeout 2000ms. Tomcat accept-count 1000
- 부하: grafana/k6, 도착률 모델(ramping-arrival-rate) 초당 400건, 5s 램프 + 20s 유지 + 5s 감소
- 일시: 2026-07-28

## 1. 기동

```console
$ docker compose up -d --build
 Container lab-f03-db   Healthy
 Container lab-f03-app  Started
$ docker logs lab-f03-app | grep -E "HikariPool|Tomcat started|Started MtsApp"
 quote-pool - Added connection org.postgresql.jdbc.PgConnection@...
 Tomcat started on port 8080 (http) with context path '/'
 Started MtsApp in 7.364 seconds
```

부하는 같은 compose 네트워크에 k6 컨테이너를 붙여 준다. 앱은 호스트 포트를 게시하지 않는다.

## 2. 버그 경로 부하 (/quote/buggy, 부하 차단 없음)

```console
$ docker run --rm --network f03-market-open-connection-storm_default \
    -e TARGET=http://app:8080/quote/buggy -v "$PWD/scripts":/scripts \
    grafana/k6 run /scripts/spike.js

  http_req_duration..............: avg=3.16s min=51.36ms med=3.38s max=5.49s p(90)=5.25s p(95)=5.36s
  http_req_failed................: 8.19%  541 out of 6598
  http_reqs......................: 6598   200.63/s
```

부하 중 앱 로그. 풀 열 개가 모두 사용 중이고 획득 대기 큐에 188건이 쌓여 있다.

```console
$ docker logs lab-f03-app | grep "Connection is not available" | head -1
java.sql.SQLTransientConnectionException: quote-pool - Connection is not available,
    request timed out after 2000ms (total=10, active=10, idle=0, waiting=188)
$ docker logs lab-f03-app | grep -c "Connection is not available"
541
```

응답 중앙값 3.38초, p95 5.36초, 커넥션 타임아웃 500이 541건이다. 처리량은 풀 한계인 초당 약 200건에 정체됐다.

## 3. 해소 경로 부하 (/quote/fixed, 부하 차단 permits=10)

```console
$ docker compose restart app          # 상태 초기화
$ docker run --rm --network f03-market-open-connection-storm_default \
    -e TARGET=http://app:8080/quote/fixed -v "$PWD/scripts":/scripts \
    grafana/k6 run /scripts/spike.js

  http_req_duration..............: avg=113ms med=51.07ms max=1.15s p(90)=390.81ms p(95)=518.97ms
    { expected_response:true }...: med=52.16ms p(95)=542.32ms
  http_reqs......................: 9959   331.95/s
  ✓ 200 정상 응답 : 3759
  ✓ 503 부하 차단 : 4876
  ✓ 500 서버오류  : 0
$ docker logs lab-f03-app | grep -c "Connection is not available"   # 해소 구간
0
```

응답 중앙값 51ms, p95 519ms. 커넥션 타임아웃 500은 0건이고, 풀 여력을 넘은 4,876건은 503으로 흘려보냈다.
램프업 첫 6초에 connection refused 경고가 몰렸는데, 이는 k6가 연결을 세우는 워밍업 구간의 것이고 정상 구간에는 없다.

## 4. 정리

```console
$ docker compose down
 Container lab-f03-app  Removed
 Container lab-f03-db   Removed
 Network f03-market-open-connection-storm_default  Removed
```

## 측정값 요약

| 구분 | 응답 중앙값 | p95 | 커넥션 타임아웃(500) | 처리 |
|---|---|---|---|---|
| 버그 (부하 차단 없음) | 3.38s | 5.36s | 541건 | 풀 고갈, 대기 큐 188 |
| 해소 (부하 차단 permits=10) | 51ms | 519ms | 0건 | 정상 3,759 · 503 흘려보냄 4,876 |

같은 400건 스파이크, 같은 풀 설정에서 부하 차단 유무만 다릅니다. 평상시 시세 조회는 약 50ms입니다.
