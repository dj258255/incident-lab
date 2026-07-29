# B52 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| 앱 | Spring Boot 3.4.1, Java 21, Spring Data JPA (Hibernate 6) |
| MySQL | 8.4.3 (컨테이너, cpus 4 / mem 2g, 버퍼 풀 1GB) |
| 데이터 | live 20만, sponsor 200만 (방송당 평균 10.4건) |
| 일시 | 2026-07-29 |

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

## 1. N+1 (results/bench.csv)

```console
N+1 지연로딩                   25ms  쿼리 21개
fetch join(EntityGraph)         7ms  쿼리 1개
집계 프로젝션                   4ms  쿼리 1개
```

쿼리 수는 `SHOW GLOBAL STATUS LIKE 'Com_select'`의 요청 전후 차이입니다.
(`performance_schema.global_status`에는 `Com_*` 카운터가 없어 이 방법을 씁니다.)

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
