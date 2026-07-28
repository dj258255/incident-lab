# R13 재현 기록

실행한 명령과 출력을 원문 그대로 남깁니다. 출력이 긴 것은 원문 파일 경로를 함께 적습니다.

## 환경

| 항목 | 값 |
|---|---|
| 호스트 | macOS 26.3.1 (25D771280a), Apple M2 Pro, 12코어, 32GB |
| Docker | 27.4.0 |
| MySQL | 8.4.3 (컨테이너, cpus 4 / mem 2g) |
| Redis | 7.4.9 (컨테이너) |
| Java | OpenJDK 21.0.9 |
| k6 | v1.6.1 |
| 일시 | 2026-07-28 |

호스트에 미리 있어야 하는 것은 Docker, Java 21, Gradle, k6입니다. MySQL과 Redis는 `compose.yml`이 띄웁니다.

## 1. 기동과 빌드

```console
$ docker compose up -d
$ ./scripts/build.sh

$ docker compose ps
NAME        IMAGE              STATUS                   PORTS
r13-mysql   mysql:8.4.3        Up 3 hours (healthy)     0.0.0.0:13306->3306/tcp
r13-redis   redis:7.4-alpine   Up (healthy)             0.0.0.0:16379->6379/tcp

$ docker exec r13-mysql mysql -uroot -plab -t -e \
    "SELECT VERSION() version, @@innodb_buffer_pool_size buffer_pool,
            @@transaction_isolation isolation, @@innodb_flush_log_at_trx_commit flush_at_commit;"
+---------+-------------+-----------------+-----------------+
| version | buffer_pool | isolation       | flush_at_commit |
+---------+-------------+-----------------+-----------------+
| 8.4.3   |  1207959552 | REPEATABLE-READ |               1 |
+---------+-------------+-----------------+-----------------+
```

## 2. 갱신 유실을 SQL 세션 2개로 확인

애플리케이션 없이도 같은 일이 벌어집니다. 두 세션이 같은 값을 읽고 각자 더해서 쓰도록, 읽기와 쓰기 사이를 `SLEEP(2)`로 겹치게 했습니다. 실행 스크립트는 `scripts/capture.sh`, 출력 원문은 `results/capture/lost-update-sql.txt`입니다.

```console
$ # 준비: 카운터 한 행, 시작값 5000
$ # 세션 A(+3000)와 세션 B(+2000)를 동시에 실행
세션이 읽은 값 5000, 쓴 값 8000
세션이 읽은 값 5000, 쓴 값 7000

$ # 결과
+--------+--------------+-------------+
| 최종값 | 있어야 할 값 | 사라진 금액 |
+--------+--------------+-------------+
|   7000 |        10000 |        3000 |
+--------+--------------+-------------+
```

두 UPDATE 모두 성공했고 에러는 없습니다. B가 A의 8000을 7000으로 덮어써서 3,000원이 사라졌습니다.

## 3. 변형별 측정

한 변형을 재는 명령입니다. 앱 기동, 초기화, 워밍업 20초, 락 지표 스냅샷, 본 측정 60초, 락 지표 스냅샷, 정합성 검증 순서로 돕니다.

```console
$ ./scripts/run.sh <mode> <slots> <scenario> <label>
$ ./scripts/run.sh jpa-naive 0 zipf jpa-naive-r1
```

세션 전체(9변형 3회 + hotspot 7변형 2회 + 읽기 + 다중 인스턴스 + 장애 복구)를 한 번에 다시 재려면:

```console
$ ./scripts/run-full.sh          # 약 75분
```

jpa-naive 측정 직후의 정합성 검증 원문(`results/zipf/jpa-naive-r1.verify.json`):

```console
$ curl -s localhost:8080/verify
{"mode":"jpa-naive","slots":0,"ledger_amount":202470600,"ledger_count":89053,
 "counter_amount":142164200,"counter_count":61552,
 "lost_amount":60306400,"lost_count":27501,"match":false,
 "optimistic_retries":0,"optimistic_giveups":0}
```

k6는 같은 구간을 실패 0%로 보고했습니다(`results/zipf/jpa-naive-r1.k6.txt`):

```console
    http_req_failed................: 0.00%  0 out of 89053
    http_reqs......................: 89053  1482.152616/s
```

## 4. 적재 데이터 감사

부하가 의도한 분포로 들어갔는지 원장 전건을 집계해 확인합니다.

```console
$ ./scripts/data-audit.sh
$ python3 scripts/data-audit.py

[데이터 감사] 원장 233,929건 · 방송 1,000개 · 후원자 186,557명 · 총액 528,260,300원

1. 방송 쏠림 (실측 vs Zipf 1.2 이론값)
1위 방송        23.2%     23.1%
상위 10개       56.9%     56.9%
하위 50%         4.2%      4.3%

2. 금액 구성 (의도: 건수 기준 소액 95% / 고액 5%)
소액 100~1,000원      222,177  95.0%   122,197,300  23.1%
고액 10,000원 이상     11,752   5.0%   406,063,000  76.9%

3. 유입 안정성 (부분 초 제외)
초당 평균 3,931건 · 표준편차 414 · 변동계수 10.5% · 구간 58초
```

## 5. 결과 집계

```console
$ python3 scripts/report.py zipf        # 표 + chart-zipf.png + chart-lock-zipf.png
$ python3 scripts/report.py hotspot
$ python3 scripts/report-extra.py all   # 읽기·다중 인스턴스·장애 복구
$ python3 scripts/figures.py zipf       # 터미널 증거 카드 6장
```

zipf 요약 원문:

```console
[zipf] 변형별 요약 (반복 측정 중앙값)
변형                  n     req/s          범위   p95(ms)   p99(ms)   실패%    락대기  평균대기ms      유실  정합
JPA 조회 후 증가       3      1181     1178~1482     253.9     284.1    0.00    22,594     144.6    27,501     X
                     └ 유실률 30.9% · 유실 금액 60,306,400원
JVM 락 + 조회 후 증가   3       758      726~967      855.7    1060.9    0.00         0       0.0         0    OK
낙관적 락 + 재시도      3       140      139~165     4022.2    4532.7   10.12    69,781      50.5         0    OK
                     └ 낙관적 락 재시도 79,506회
비관적 락             3      1054      988~1260      286.4     328.1    0.00    19,972     169.1         0    OK
원자적 UPDATE         3      1338     1253~1525      235.5     270.2    0.00    25,367     131.4         0    OK
슬롯 16               3      3272     2894~3921       47.9      62.5    0.00    28,318       8.1         0    OK
슬롯 64               3      4051     3415~4179       37.4      51.0    0.00     8,822       4.8         0    OK
Redis 카운터          3      4000     3416~4021       37.8      55.5    0.00         0       0.0         0    OK
Redis 파이프라인       3      4294     3356~4439       34.1      43.3    0.00         0       0.0         0    OK
```

## 6. 다중 인스턴스와 장애 복구

```console
$ ./scripts/run-multi.sh jvm-lock 0 1 jvm-lock-x1     # 유실 0, match true
$ ./scripts/run-multi.sh jvm-lock 0 2 jvm-lock-x2
{"ledger_count":81122,"counter_count":69598,"lost_count":11524,
 "lost_amount":26128100,"match":false}

$ ./scripts/run-redis-failure.sh                       # 부하 중 docker kill r13-redis
복구 전  {"lost_count":74792,"lost_amount":166705900,"match":false}
$ curl -s -X POST localhost:8080/rebuild
{"rebuilt_table":"live_counter","elapsed_ms":331}
복구 후  {"lost_count":0,"lost_amount":0,"match":true}
```

타임라인 원문은 `results/failure/redis-kill.timeline.txt`에 있습니다.

## 원문 파일 위치

| 내용 | 경로 |
|---|---|
| 변형별 k6 요약·정합성 검증 | `results/zipf/`, `results/hotspot/` (라벨별 `.k6.txt`, `.verify.json`) |
| 행 락 지표 스냅샷 | 라벨별 `.lock.before.txt` / `.lock.after.txt` |
| 커넥션 풀 없는 파이프라인의 BindException 발췌 | `results/zipf/redis-pipe-nopool.errors.txt` |
| 읽기·다중 인스턴스·장애 복구 | `results/read/`, `results/multi/`, `results/failure/` |
| 적재 데이터 감사 덤프 | `results/data-audit/` |
| 환경·SQL 데모 캡처 | `results/capture/` |
