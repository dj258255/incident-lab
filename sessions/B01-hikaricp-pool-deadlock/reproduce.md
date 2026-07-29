# B01 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| 호스트 | Darwin 25.3.0 arm64, 12코어, 32GB |
| MySQL | 8.4.3 공식 Docker 이미지, `--max-connections=500` |
| 애플리케이션 | Spring Boot 3.4.1, Hibernate 6(spring-boot-starter-data-jpa), JDK 25 |
| 컨테이너 | `eclipse-temurin:21-jre`, 브리지 네트워크 `b01-lab` |
| 자원 상한 | 걸지 않았습니다 |
| 동시 요청 | 16 (원 사례의 소비자 스레드 16개와 맞춤) |
| 조건당 시간 | 40초 |
| `connectionTimeout` | 30000ms (HikariCP 기본값, 원 사례와 동일) |
| 일시 | 2026-07-29 |

호스트가 12코어라 원 사례의 4코어보다 넉넉합니다. 절대 TPS를 원 사례와 비교하면 안 되고, 조건 간 상대 비교만 유효합니다.

`--network host`는 macOS Docker Desktop에서 기대대로 동작하지 않습니다. 앱을 DB와 같은 브리지 네트워크에 넣고 컨테이너 이름(`b01-mysql`)으로 붙였습니다.

## 실행

```console
$ docker compose up -d
$ docker exec -i b01-mysql mysql -uroot -plab spoon < schema.sql
$ cd app && gradle bootJar && cd ..
$ ./scripts/run-all.sh        # 4개 조건, 약 4분
```

조건별 원문은 `results/<라벨>-{req.csv,pool.jsonl,app.log,final.json}`에 남습니다.

## 1. 시퀀스 채번이 별도 커넥션을 쓰는지 (allocationSize 확인)

풀 10, 순차 요청. 시퀀스 테이블을 매 INSERT마다 관측했습니다.

```console
기동 직후  next_val=1
INSERT #1 → next_val=51   max(id)=1   {"status":"ok","ms":41}
INSERT #2 → next_val=101  max(id)=2   {"status":"ok","ms":8}
INSERT #3 → next_val=101  max(id)=3   {"status":"ok","ms":4}
INSERT #4 → next_val=101  max(id)=4   {"status":"ok","ms":4}
INSERT #5 → next_val=101  max(id)=5   {"status":"ok","ms":5}
INSERT #6 → next_val=101  max(id)=6   {"status":"ok","ms":3}
```

`next_val`이 50씩 뜁니다. Hibernate 6 pooled 옵티마이저, `allocationSize=50`입니다. 테이블 이름은 엔티티별 `sponsor_jpa_seq`입니다.

첫 요청만 41ms이고 이후 3~8ms인 것도 같은 이유입니다. 첫 요청이 채번 커넥션을 여는 비용을 냅니다.

한 번 헛짚었습니다. 확인하려고 `DELETE FROM sponsor_jpa_seq`로 행을 지웠더니 이후 INSERT가 전부 조용히 실패했습니다(`max(id)=0`). Hibernate 테이블 생성기는 행이 있어야 동작합니다. `INSERT INTO sponsor_jpa_seq(next_val) VALUES(1)`로 시드를 넣고 다시 쟀습니다.

## 2. 조건별 결과 (results/*-final.json)

```console
jpa-10: {"total":10,"active":0,"idle":10,"awaiting":0,"ok":1433,"fail":7,"db_threads_connected":10}
jpa-24: {"total":24,"active":0,"idle":24,"awaiting":0,"ok":5526,"fail":0,"db_threads_connected":24}
two-10: {"total":10,"active":0,"idle":10,"awaiting":0,"ok":11,"fail":21,"db_threads_connected":10}
one-10: {"total":10,"active":0,"idle":10,"awaiting":0,"ok":5058,"fail":0,"db_threads_connected":10}
```

측정 종료 후 값이라 `active=0, awaiting=0`입니다. 측정 중 값은 `results/<라벨>-pool.jsonl`에 0.5초 간격으로 있습니다.

`db_threads_connected`가 풀 크기와 정확히 같습니다. DB는 풀이 준 만큼만 물고 있었고, `max-connections=500` 중 10개만 쓰는 상태에서 애플리케이션이 멈췄습니다.

## 3. 지연·처리량

```console
jpa-10   성공  1433  실패   7 (  0.5%)  TPS   35.8  p50     39ms  p95     61ms  최대 30141ms
jpa-24   성공  5526  실패   0 (  0.0%)  TPS  138.2  p50     42ms  p95     60ms  최대   131ms
two-10   성공    11  실패  21 ( 65.6%)  TPS    0.3  p50  30092ms  p95  30125ms  최대 30125ms
one-10   성공  5058  실패   0 (  0.0%)  TPS  126.5  p50     85ms  p95    101ms  최대   224ms
```

## 4. 워커 시간 분해

```console
조건        전체   >1s건  >1s비율   >1s가쓴 워커시간   전체워커시간대비
jpa-10     1440      16    1.1%             482s            89.1%
jpa-24     5526       0    0.0%               0s             0.0%
two-10       32      32  100.0%             963s           100.0%
one-10     5058       0    0.0%               0s             0.0%
```

워커 16개 × 40초 = 640초가 이론상 한도인데 `jpa-10`의 482초가 16건에 묶였습니다. `two-10`의 963초가 640초를 넘는 이유는 타임아웃 30초짜리 요청이 측정 종료 시각을 넘겨 끝났기 때문입니다.

## 5. HikariCP 로그 원문 (results/jpa-10-app.log)

```console
HikariPool-1 - Connection is not available, request timed out after 30000ms (total=10, active=10, idle=0, waiting=10)
HikariPool-1 - Connection is not available, request timed out after 30000ms (total=10, active=10, idle=0, waiting=9)
HikariPool-1 - Connection is not available, request timed out after 30001ms (total=10, active=10, idle=0, waiting=12)
```

원 사례의 `Timeout failure stats (total=10, active=10, idle=0, waiting=16)`와 `total`, `active`, `idle`이 일치합니다.

## 6. 실패 예외 분포

```console
jpa-10:  1433 ok   6 err:CannotCreateTransactionException   1 err:DataAccessResourceFailureException
two-10:    11 ok  21 err:SQLTransientConnectionException
```

## 밟은 함정

1. **Spring 프록시 필드 접근.** `SponsorService`에 `@Transactional`을 붙이자 컨트롤러의 `svc.ok` 필드 읽기가 NPE를 냈습니다. 프록시의 필드는 초기화되지 않습니다. 접근자 메서드로 고쳤습니다. R13에서 겪고 적어 둔 함정을 그대로 다시 밟았습니다.
2. **시퀀스 테이블 행 삭제.** 위 1절에 적었습니다. 에러 없이 INSERT만 조용히 실패합니다.
3. **`--network host`.** macOS Docker Desktop에서 동작하지 않아 브리지 네트워크 + 컨테이너 이름으로 우회했습니다.
