# R02 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| DB | MySQL 8.4.3 x 2 (172.31.0.11 = A / server_id 1, 172.31.0.12 = B / server_id 2) |
| DNS | dnsmasq 2.91, `address=/db.internal/<IP>`, `local-ttl=5` |
| 앱 | Spring Boot 3.4.1 + HikariCP, eclipse-temurin:21-jre 컨테이너, `--dns 172.31.0.53` |
| 일시 | 2026-07-29 |

## 실행

```console
$ docker compose up -d
$ cd app && gradle bootJar && cd ..
$ ./scripts/failover.sh default
$ ./scripts/failover.sh ttl0 -Dsun.net.inetaddr.ttl=0
$ ./scripts/failover.sh ttl0-life MAX_LIFETIME=10000 KEEPALIVE=5000 -Dsun.net.inetaddr.ttl=0
$ python3 scripts/report.py
```

페일오버는 `docker stop r02-db-a` + dnsmasq.conf의 주소를 B로 바꾸고 dns 컨테이너 재시작으로 만듭니다.

## 앱 기동 시 JVM 캐시 정책 (results/*-jvm.txt)

```console
networkaddress.cache.ttl = null           <- 미설정. JVM 내부 기본값 30초가 적용된다
networkaddress.cache.negative.ttl = 10
```

## 기본값 조건 타임라인 (results/default.jsonl)

`/probe`가 한 번에 세 가지를 돌려줍니다. JVM이 해석한 IP, 실제 붙은 server_id, DB 상태.

```console
 -10.1s  resolved=172.31.0.11  server_id=1     db=OK
  +1.1s  resolved=172.31.0.11  server_id=None  db=ERR:RecoverableDataAccessException
  +3.0s  resolved=?            server_id=None  db=NO-RESPONSE
 +34.8s  resolved=172.31.0.11  server_id=None  db=ERR:CannotGetJdbcConnectionException
 +45.8s  resolved=172.31.0.12  server_id=None  db=ERR:CannotGetJdbcConnectionException
 +49.5s  resolved=172.31.0.12  server_id=2     db=OK
```

DNS는 페일오버 직후 B(172.31.0.12)를 가리켰지만, JVM은 +34.8초까지 A(172.31.0.11)를 반환했습니다.

## 세 조건 비교 (scripts/report.py)

```console
조건                              복구까지
기본값 (JVM 캐시 30초)               49.5초
sun.net.inetaddr.ttl=0            5.9초
ttl=0 + maxLifetime 10초           5.9초
```

## 원문 파일 위치

| 내용 | 경로 |
|---|---|
| 0.5초 간격 프로브 원본 | `results/{default,ttl0,ttl0-life}.jsonl` |
| 페일오버 시각 | `results/*-failover-ts.txt` |
| JVM 캐시 정책 출력 | `results/*-jvm.txt` |
| 앱 로그 | `results/*-app.log` (gitignore) |
| 차트 | `results/chart-failover.png` |
