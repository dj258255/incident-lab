# B52 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| 호스트 | 기록하지 않았습니다 (`uname -srm`, `nproc`, `free -g`를 찍지 않았습니다) |
| 앱 | Spring Boot 3.4.1, Java 21, Spring Data JPA (Hibernate 6) |
| MySQL | 8.4.3 (컨테이너, cpus 4 / mem 2g, 버퍼 풀 1GB) |
| 데이터 | live 20만, sponsor 200만 |
| 측정 (N+1, 페이지네이션) | `bench.sh`의 `bench()`, 워밍업 3회 후 5회의 중앙값 |
| 측정 (대량 삽입) | `bench.sh`의 `insert()`, 워밍업도 반복도 없이 POST 1회 |
| 일시 | 2026-07-29 |

호스트 사양을 남기지 않아 어느 장비였는지 확인되지 않습니다. 컨테이너 할당량만 알 수 있으므로
이 문서의 절대 시간을 다른 세션의 절대 시간과 비교하면 안 됩니다.

방송당 평균 후원 건수는 정의에 따라 갈립니다. 200만 ÷ 20만은 10.0건입니다.
`scripts/seed.py`가 마지막에 찍는 10.4건은 `SELECT AVG(c) FROM (SELECT COUNT(*) c FROM sponsor
GROUP BY live_id) t`로 잰 값이라 후원이 한 건 이상 붙은 방송만의 평균입니다. Zipf 쏠림 때문에
후원이 0건인 방송이 있고, 그 차이가 두 숫자를 가릅니다.

호스트에 Docker, Java 21, Gradle, Python(PyMySQL)이 필요합니다.

## 실행

```console
$ docker compose up -d
$ cd app && gradle bootJar && cd ..
$ python3 scripts/seed.py       # 약 30초
$ ./scripts/bench.sh            # 앱을 조건별로 3회 띄우며 측정, 약 3분
$ python3 scripts/report.py
```

`hibernate.jdbc.batch_size`는 기동 시 결정되므로 한 프로세스에서 켜고 끌 수 없습니다. 같은 jar에 환경변수만 바꿔 앱을 다시 띄웁니다.

`saveAllAssigned` 조건이 쓰는 `sponsor_assigned` 테이블이 측정 당시 `schema.sql`에 없었습니다.
앱은 `ddl-auto: none`이라 하이버네이트가 만들어 주지 않으므로, 위 순서를 그대로 따라가면 그
조건에서 실패했습니다. 발행 전 자기 검증에서 발견해 `schema.sql`에 정의를 채웠습니다. 그 정의는
엔티티 매핑에 맞춰 복원한 것이라 측정에 쓴 DDL과 글자까지 같다고 보장할 수 없습니다.

`bench.sh`는 조건을 순서대로 돌리면서 같은 테이블에 계속 넣습니다. `sponsor`는 200만 행에서
시작해 `saveAll`과 `jdbc` 조건마다 1만 행씩 늘고, `sponsor_assigned`는 빈 상태에서 시작해
`saveAllAssigned` 조건마다 1만 행씩 늡니다. 조건 간 소요 시간을 비교할 때 이 누적을 감안해야
합니다. 처음부터 다시 재려면 `docker compose down -v` 후 다시 올립니다.

## 1. N+1 (results/bench.csv)

```console
N+1 지연로딩                   25ms  쿼리 21개
fetch join(EntityGraph)         7ms  쿼리 1개
집계 프로젝션                   4ms  쿼리 1개
```

쿼리 수는 `SHOW GLOBAL STATUS LIKE 'Com_select'`의 요청 전후 차이입니다.
(`performance_schema.global_status`에는 `Com_*` 카운터가 없어 이 방법을 씁니다.)

측정 구간은 `bench.sh`가 `FROM=100000`으로 고정한 id 100000~100019입니다.
Zipf 꼬리 구간이라 후원이 적습니다. `seed.py`의 가중치로 계산하면 방송당 4건이 채 안 되고
20건을 합쳐도 80건에 못 미치는 것이 기댓값입니다. 이 구간의 실제 후원 건수는 세지 않았습니다.

## 2. 페이지네이션

```console
OFFSET 0            4ms      커서(행값) 0          3ms   커서(풀어씀) 0         3ms
OFFSET 10000        5ms      커서(행값) 10000      5ms   커서(풀어씀) 10000     4ms
OFFSET 100000      16ms      커서(행값) 100000    17ms   커서(풀어씀) 100000    4ms
OFFSET 199980      28ms      커서(행값) 199980    31ms   커서(풀어씀) 199980    3ms
```

실행계획 원문:

```console
$ EXPLAIN SELECT id FROM live
    WHERE (created_at, id) > ('2026-01-07 22:39:00.000', 199981)
    ORDER BY created_at, id LIMIT 20\G
         type: index          <- 전체 인덱스 스캔
          key: idx_created

$ EXPLAIN SELECT id FROM live
    WHERE created_at > '2026-01-07 22:39:00.000'
       OR (created_at = '2026-01-07 22:39:00.000' AND id > 199981)
    ORDER BY created_at, id LIMIT 20\G
         type: range          <- 인덱스 구간 탐색
          key: idx_created
```

사용자 변수(`@lts`)로 넣어도, 리터럴로 넣어도 결과는 같았습니다.

## 3. 대량 삽입 (results/insert-counters.txt)

```console
$ # hibernate.jdbc.batch_size=500, rewriteBatchedStatements=true
mode                 elapsed   SELECT      INSERT
saveAll(IDENTITY)     4620ms        2       10000    <- 배치가 전혀 안 됨
saveAll(직접ID)       4555ms    10022          20    <- 배치는 되나 merge가 행마다 SELECT
jdbc batchUpdate       141ms        3           1    <- multi-value INSERT 한 방

$ # rewriteBatchedStatements=false 로 바꾸면
saveAll 직접ID (배치 500 · rewrite 끔)   8544ms
```

## 원문 파일 위치

| 내용 | 경로 |
|---|---|
| 변형별 응답 시간·쿼리 수 | `results/bench.csv` |
| 삽입 방식별 SELECT·INSERT 카운터 | `results/insert-counters.txt` |
| 앱 로그 (조건별) | `results/app-b*-r*.log` (gitignore) |
| 차트·증거 카드 | `results/chart-jpa.png`, `results/fig-insert.png` |
