# R03 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| 호스트 | macOS 26.3.1, Apple M2 Pro, 12코어(논리), 32GB |
| DB | MySQL 8.4.3 × 3 (172.32.0.11/12/13, server_id 1/2/3) |
| 리더 엔드포인트 | CoreDNS 1.11.3, hosts 플러그인 + `loadbalance round_robin`, TTL 1초 |
| 앱 | Spring Boot 3.4.1 + HikariCP, eclipse-temurin:21-jre 컨테이너 |
| 일시 | 2026-07-29 |

## 실행

```console
$ docker compose up -d
$ cd app && gradle bootJar && cd ..
$ ./scripts/run.sh cached POOL=12 MAXLIFE=30000
$ ./scripts/run.sh ttl0   POOL=12 MAXLIFE=30000 JAVA_TOOL_OPTIONS=-Dsun.net.inetaddr.ttl=0
$ python3 scripts/report.py
```

## DNS가 실제로 도는지 먼저 확인

```console
$ for i in 1..6; do nslookup reader.internal | grep -m1 "^Address: 172"; done
Address: 172.32.0.13
Address: 172.32.0.13
Address: 172.32.0.12
Address: 172.32.0.11
Address: 172.32.0.11
Address: 172.32.0.11
```

dnsmasq(`address=` 항목)에서는 5회 모두 `.12 .13 .11` 고정 순서였습니다. CoreDNS로 바꾼 뒤 순서가 돕니다.

## 측정 (results/*.jsonl)

`/distribution`은 풀의 `maximumPoolSize`만큼 커넥션을 동시에 잡고 각각 `SELECT @@server_id`를 확인합니다.

```console
조건                              최대점유 평균              범위            마지막 분포
JVM 캐시 기본값                        83.5%     58.3~100.0%         {'2': 12}
sun.net.inetaddr.ttl=0            47.9%      33.3~66.7%  {'1': 3, '2': 6, '3': 3}
```

표본 각 40회(3초 간격, 120초).

## 쿼리 단위가 아님을 확인

```console
$ for i in 1..20; do curl -s /one; done | sort | uniq -c
  20  server_id=1
```

풀에서 빌려 쓰고 반납하는 패턴이라 같은 커넥션이 계속 나오고, 그 커넥션은 한 인스턴스에 고정돼 있습니다.

## 원문 파일 위치

| 내용 | 경로 |
|---|---|
| 3초 간격 분포 원본 | `results/cached.jsonl`, `results/ttl0.jsonl` |
| 앱 로그 | `results/*-app.log` (gitignore) |
| 차트 | `results/chart-skew.png` |
