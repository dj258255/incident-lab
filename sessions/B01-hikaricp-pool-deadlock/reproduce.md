# B01 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| 호스트 | Darwin 25.3.0 arm64, 12코어, 32GB |
| MySQL | 8.4.3 공식 Docker 이미지, `--max-connections=500` |
| 애플리케이션 | Spring Boot 3.4.1, Hibernate 6(spring-boot-starter-data-jpa), JDK 25 |
| 컨테이너 | `eclipse-temurin:21-jre`, 브리지 네트워크 `b01-lab` |
| 동시 요청 | 16 (원 사례의 소비자 스레드 16개와 맞춤) |
| 조건당 시간 | 40초 |
| `connectionTimeout` | 30000ms (HikariCP 기본값, 원 사례와 동일) |
| 일시 | 2026-07-29 (1회차), 2026-07-30 (2~4회차) |
| 반복 | 4회. `tools/repeat-runs.sh`로 3회 추가. 회차별 원문은 `results/run0-*`~`run3-*` |
| 호스트 기록 | `results/host.txt`, 회차별 `results/host-run*.txt` |
| 자원 한도 | 걸지 않았습니다. 1회차와 조건을 맞추려고 그대로 두었습니다 |

호스트가 12코어라 원 사례의 4코어보다 넉넉합니다. 절대 TPS를 원 사례와 비교하면 안 되고, 조건 간 상대 비교만 유효합니다.

`--network host`는 macOS Docker Desktop에서 기대대로 동작하지 않습니다. 앱을 DB와 같은 브리지 네트워크에 넣고 컨테이너 이름(`b01-mysql`)으로 붙였습니다.

## 실행

```console
$ docker compose up -d
$ docker exec -i b01-mysql mysql -uroot -plab spoon < schema.sql
$ cd app && gradle bootJar && cd ..
$ ./scripts/run-all.sh        # 기본 4개 조건, 약 4분
$ DURATION=40 CONCURRENCY=16 ./scripts/run.sh seq1-10 seq1 10   # allocationSize=1
$ DURATION=40 CONCURRENCY=16 ./scripts/run.sh idn-10  idn  10   # IDENTITY
$ ./scripts/capture.sh                        # 시퀀스 관측과 HikariCP 로그 발췌
$ ./scripts/multi-instance.sh 3 24             # 인스턴스 3대, 풀 24
$ python3 scripts/report-remedies.py           # 해소책 비교 차트
```

조건별 원문은 `results/<라벨>-{req.csv,pool.jsonl,app.log,final.json}`에 남습니다.

## 1. 시퀀스 채번이 별도 커넥션을 쓰는지 (allocationSize 확인)

풀 10, 순차 요청. 시퀀스 테이블을 매 INSERT마다 관측했습니다.

```console
기동 직후  next_val=1
INSERT #1 → next_val=51   max(id)=1   {"status":"ok","ms":40}
INSERT #2 → next_val=101  max(id)=2   {"status":"ok","ms":7}
INSERT #3 → next_val=101  max(id)=3   {"status":"ok","ms":4}
INSERT #4 → next_val=101  max(id)=4   {"status":"ok","ms":4}
INSERT #5 → next_val=101  max(id)=5   {"status":"ok","ms":4}
INSERT #6 → next_val=101  max(id)=6   {"status":"ok","ms":3}
```

원문은 `results/evidence-sequence.txt`입니다. `scripts/capture.sh`가 만듭니다.

`next_val`이 50씩 뜁니다. Hibernate 6 pooled 옵티마이저, `allocationSize=50`입니다. 테이블 이름은 엔티티별 `sponsor_jpa_seq`입니다.

첫 요청만 40ms이고 이후 3~7ms인 것도 같은 이유입니다. 첫 요청이 채번 커넥션을 여는 비용을 냅니다.

한 번 헛짚었습니다. 확인하려고 `DELETE FROM sponsor_jpa_seq`로 행을 지웠더니 이후 INSERT가 전부 조용히 실패했습니다(`max(id)=0`). Hibernate 테이블 생성기는 행이 있어야 동작합니다. `INSERT INTO sponsor_jpa_seq(next_val) VALUES(1)`로 시드를 넣고 다시 쟀습니다.

## 2. 조건별 결과 (1회차, results/run0-*-final.json)

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
two-10   n=4 tps중앙=    0.3 (범위 0.3~0.5)  실패 19~21  1초초과=32건  워커시간 99.9~100.0%  풀=10
jpa-10   n=4 tps중앙=   37.2 (범위 34.2~40.1)  실패 7~7    1초초과=16건  워커시간 88.4~89.1%  풀=10
jpa-24   n=4 tps중앙=  141.1 (범위 136.6~164.3)  실패 0~0  1초초과=0건   워커시간 0.0~0.0%    풀=24
one-10   n=4 tps중앙=  151.2 (범위 126.5~152.8)  실패 0~0  1초초과=0건   워커시간 0.0~0.0%    풀=10
```

## 4. 워커 시간 분해 (1회차)

```console
조건        전체   >1s건  >1s비율   >1s가쓴 워커시간   전체워커시간대비
jpa-10     1440      16    1.1%             482s            89.1%
jpa-24     5526       0    0.0%               0s             0.0%
two-10       32      32  100.0%             963s           100.0%
one-10     5058       0    0.0%               0s             0.0%
```

워커 16개 × 40초 = 640초가 이론상 한도인데 1회차에서 `jpa-10`의 482초가 16건에 묶였습니다. 네 회차 범위는 88.4~89.1%입니다. `two-10`의 963초가 640초를 넘는 이유는 타임아웃 30초짜리 요청이 측정 종료 시각을 넘겨 끝났기 때문입니다.

## 5. HikariCP 로그 원문 (results/evidence-hikari-timeout.txt)

```console
HikariPool-1 - Connection is not available, request timed out after 30000ms (total=10, active=10, idle=0, waiting=10)
HikariPool-1 - Connection is not available, request timed out after 30000ms (total=10, active=10, idle=0, waiting=9)
HikariPool-1 - Connection is not available, request timed out after 30001ms (total=10, active=10, idle=0, waiting=12)
```

원 사례의 `Timeout failure stats (total=10, active=10, idle=0, waiting=16)`와 `total`, `active`, `idle`이 일치합니다.

## 6. 실패 예외 분포 (1회차)

```console
jpa-10:  1433 ok   6 err:CannotCreateTransactionException   1 err:DataAccessResourceFailureException
two-10:    11 ok  21 err:SQLTransientConnectionException
```

## 7. 채번 방식과 해소책 (2026-07-30 추가)

`scripts/report-remedies.py` 출력입니다.

```console
  two-10    tps=    0.3 실패   21/   32 ( 65.6%) p50= 30098ms
  seq1-10   tps=    0.5 실패   19/   38 ( 50.0%) p50= 30062ms
  jpa-10    tps=   38.5 실패    7/ 1546 (  0.5%) p50=    39ms
  jpa-24    tps=  164.3 실패    0/ 6572 (  0.0%) p50=    37ms
  one-10    tps=  151.2 실패    0/ 6047 (  0.0%) p50=    78ms
  idn-10    tps=  180.9 실패    0/ 7237 (  0.0%) p50=    44ms
  배치: 1000-auto=62 1000-identity=110 5000-auto=180 5000-identity=370
        10000-auto=295 10000-identity=752
```

`allocationSize=1`(`seq1-10`)이 커넥션을 직접 두 개 잡는 `two-10`과 사실상 같습니다.
시퀀스 테이블 확인은 이렇습니다.

```console
t	next_val
seq1	20        ← 19행에 20. 1씩 오른다
jpa	1
seq1_rows  19
idn_rows   7237
```

## 8. 인스턴스 여러 대 (2026-07-30 추가)

`results/evidence-multi-instance.txt` 원문입니다.

```console
앱 없을 때 기준 접속 = 1
  인스턴스 1대 → 접속 25 (기준 제외 24)  풀 24 x 1 = 24 기대
  인스턴스 2대 → 접속 49 (기준 제외 48)  풀 24 x 2 = 48 기대
  인스턴스 3대 → 접속 73 (기준 제외 72)  풀 24 x 3 = 72 기대

max_connections=60 로 낮춘 뒤
    ERROR 1040 (HY000): Too many connections
    인스턴스 1: {"total":24,...}
    인스턴스 2: {"total":24,...}
    인스턴스 3: {"total":13,...}   ← 정상 기동인데 풀이 절반
```

인스턴스 3은 `/pool`이 200을 돌려주고 앱 로그에 `Too many connections`도 없습니다.
확보한 만큼만 들고 돕니다.

## 9. leakDetectionThreshold (2026-07-30 추가)

`results/evidence-leak-detection.txt` 원문입니다.

```
java.lang.Exception: Apparent connection leak detected
	at com.zaxxer.hikari.HikariDataSource.getConnection(HikariDataSource.java:127)
	at lab.b01.SponsorService.sponsorTwoConnections(B01Application.java:185)
```

30건 잡혔습니다. 185번 줄이 첫 커넥션을 쥔 채 두 번째를 요청하는 자리입니다.

## 반복 측정에서 드러난 것

질적 결론은 네 회차에서 전부 유지됐습니다. `jpa-10`의 실패가 정확히 7건, 1초 초과가
정확히 16건으로 회차마다 어긋나지 않았고, `two-10`은 매번 무너졌고 `one-10`은 매번
실패 0건이었습니다.

절대 처리량은 흔들립니다. 회차 간 1.2배 안쪽이고, `one-10`의 run0(126.5)만 나머지
세 회차(151~153)보다 낮습니다. 그래서 처리량은 중앙값과 범위로만 적습니다.

회차 2와 3은 앞 회차의 부하가 남은 상태에서 시작했습니다(load average 3.71 → 11.26 → 10.82).
회차 사이에 대기를 두지 않은 것이 이 측정의 결함입니다.

## 밟은 함정

0. **8080번대 포트 충돌.** 인스턴스 여러 대를 띄울 때 8082가 이미 다른 컨테이너에
   잡혀 있어 두 번째 인스턴스가 안 떴습니다. 스크립트가 기동을 확인하지 않았다면
   커넥션 수가 48이 아니라 35인 것을 편차로 착각했을 것입니다. 8090번대로 옮기고
   기동 확인을 넣었습니다.

1. **Spring 프록시 필드 접근.** `SponsorService`에 `@Transactional`을 붙이자 컨트롤러의 `svc.ok` 필드 읽기가 NPE를 냈습니다. 프록시의 필드는 초기화되지 않습니다. 접근자 메서드로 고쳤습니다. R13에서 겪고 적어 둔 함정을 그대로 다시 밟았습니다.
2. **시퀀스 테이블 행 삭제.** 위 1절에 적었습니다. 에러 없이 INSERT만 조용히 실패합니다.
3. **`--network host`.** macOS Docker Desktop에서 동작하지 않아 브리지 네트워크 + 컨테이너 이름으로 우회했습니다.
4. **`mysqladmin ping`을 준비 판정에 씀.** compose의 healthcheck와 캡처 스크립트가 이걸 썼는데, 초기화 중 임시 서버에도 인증 실패에도 성공을 반환합니다. 실제로 `Access denied`를 맞고서야 알았습니다. 대상 DB에 쿼리가 통하는지로 바꿨습니다.
5. **회차가 원본 파일을 덮어씀.** `run-all.sh`가 접두어 없는 이름에 쓰기 때문에 `tools/repeat-runs.sh`로 3회차를 돌리자 처음 측정이 사라졌습니다. 발행에 쓴 값의 근거가 없어진 상태였고 git 히스토리에서 되살려 `run0-*`으로 남겼습니다.
6. **스키마에 JPA 테이블이 없었음.** `sponsor_jpa`와 `sponsor_jpa_seq`를 손으로 만들고 `schema.sql`에 넣지 않았습니다. `ddl-auto: none`이라 문서대로 따라가면 JPA 조건이 "테이블 없음"으로 실패합니다. 시드 행까지 스키마에 넣어 고쳤습니다.
