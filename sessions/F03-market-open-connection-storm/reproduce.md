# 재현 기록

실행한 명령과 출력을 남깁니다. 이 문서의 콘솔 블록은 옮겨 적은 것이므로 원문은 결과 파일 쪽입니다.
k6 요약 전문은 [results/buggy-k6.txt](results/buggy-k6.txt), [results/fixed-k6.txt](results/fixed-k6.txt)에,
앱 로그의 풀 고갈 증거는 [results/hikari-timeout.txt](results/hikari-timeout.txt)에 있습니다. 옮겨 적는
과정에서 어긋난 값이 실제로 있었습니다(2절의 `waiting`). 수치가 갈리면 결과 파일을 기준으로 봐야 합니다.

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

부하 중 앱 로그. 풀 열 개가 모두 사용 중이고 획득 대기 큐에 189건이 쌓여 있다.

```console
$ docker logs lab-f03-app | grep "Connection is not available" | head -1
java.sql.SQLTransientConnectionException: quote-pool - Connection is not available,
    request timed out after 2000ms (total=10, active=10, idle=0, waiting=189)
$ docker logs lab-f03-app | grep -c "Connection is not available"
541
```

주의: 위 `grep -c` 결과는 확정된 값이 아니다. 같은 실행의 로그를 발췌한
[results/hikari-timeout.txt](results/hikari-timeout.txt)는 "이 실행에서 위 예외로 처리된 500이 27건"이라고
적어 두었다. 앱 로그 쪽 집계가 이 저장소 안에서 541과 27 두 값으로 갈린다. 어느 쪽이 그 실행의 참값인지,
27이 무엇을 센 값인지는 남은 파일로 가려내지 못했다. 발췌 파일은 스택트레이스를 줄여 놓은 것이라
`docker logs` 원문 출력이 아니고, 위 `waiting` 값도 처음 이 문서에 188로 잘못 옮겼다가 로그 원문(189)에 맞춰
고친 것이다. 다른 시도의 기록이거나 발췌가 잘렸을 가능성이 있다.

확정된 것은 k6 쪽 집계다. 같은 실행의 응답 상태 분포가 200 6,057건, 500 541건, 503 0건이고 합이
`http_reqs` 6,598건과 정확히 맞는다. `http_req_failed 8.19% 541 out of 6598`도 같은 값이라, 실패로 잡힌
541건에 503이나 응답을 받지 못한 요청은 섞여 있지 않다. 즉 541은 버그 경로가 돌려준 HTTP 500의 개수이고,
그 가운데 몇 건이 HikariCP 커넥션 획득 타임아웃이었는지는 세지 못했다.

응답 중앙값 3.38초, p95 5.36초, 500 응답이 541건이다. 처리량은 풀 한계인 초당 약 200건에 정체됐다.

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
다만 위 세 상태의 합은 8,635건이라 `http_reqs` 9,959건에 1,324건이 모자란다. 그 1,324건은 200도 503도
아닌 실패다. 램프업 첫 6초에 connection refused 경고가 몰렸는데 이는 k6가 연결을 세우는 워밍업 구간의
것으로 보이고, 같은 요약의 `http_req_duration min=0s`가 그 0ms 실패가 지연 분포에 섞여 있음을 보여 준다.
따라서 위 중앙값 51ms는 그만큼 낮게 나온 값이고, 성공 응답만 본 `{ expected_response:true }` 쪽은
중앙값 52.16ms, p95 542.32ms다.

## 4. 정리

```console
$ docker compose down
 Container lab-f03-app  Removed
 Container lab-f03-db   Removed
 Network f03-market-open-connection-storm_default  Removed
```

## 측정값 요약

| 구분 | 응답 중앙값 | p95 | 500 응답(k6 집계) | 처리 |
|---|---|---|---|---|
| 버그 (부하 차단 없음) | 3.38s | 5.36s | 541건 | 풀 고갈, 대기 큐 189 |
| 해소 (부하 차단 permits=10) | 51ms | 519ms | 0건 | 정상 3,759 · 503 흘려보냄 4,876 · 그 밖 1,324 |

풀 설정은 양쪽이 같고 부하 차단 유무만 다릅니다. 다만 k6 목표 도착률만 초당 400건으로 같았을 뿐,
앱에 실제로 도달한 요청은 6,598건과 9,959건으로 51% 차이가 납니다. 버그 경로는 응답이 3~5초씩 걸려
VU가 모자랐고 목표 도착률의 3,401회분이 발사되지 못했습니다(`dropped_iterations 3401`). 그래서 두 경로의
처리량은 비교하지 않습니다. 비교가 성립하는 것은 각 경로가 실제로 받은 요청의 지연, 그리고 커넥션
타임아웃이 났는지 여부까지입니다. 평상시 시세 조회는 약 50ms입니다.
