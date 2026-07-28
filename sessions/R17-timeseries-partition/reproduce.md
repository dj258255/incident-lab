# R17 재현 기록

실행한 명령과 출력을 원문 그대로 남깁니다.

## 환경

| 항목 | 값 |
|---|---|
| 호스트 | macOS 26.3.1, Apple M2 Pro, 12코어(논리), 32GB |
| MySQL | 8.4.3 (컨테이너, cpus 4 / mem 2g, 버퍼 풀 1GB) |
| Python | 3.14 + PyMySQL (부하·관측용) |
| 일시 | 2026-07-28 ~ 29 |

호스트에 Docker와 Python(PyMySQL)이 필요합니다.

## 1. 기동과 적재

```console
$ docker compose up -d
$ python3 scripts/seed.py --rows-per-day 500000     # 14일 x 50만 행 x 2테이블, 약 3분

$ docker exec r17-mysql mysql -uroot -plab spoon -t -e \
    "SELECT @@innodb_purge_threads, @@version;"
+------------------------+-----------+
| @@innodb_purge_threads | @@version |
+------------------------+-----------+
|                      1 | 8.4.3     |
+------------------------+-----------+
```

적재 후 크기: `watch_log_plain` 648MB / `watch_log_part` 667MB (각 700만 행, 동일 데이터).

## 2. 본 실험

```console
$ ./scripts/run-experiments.sh      # 실험 1~5 일괄, 약 15분
$ ./scripts/exp-chunked.sh          # 실험 6 (청크 삭제), 약 5분
```

### 실험 1: DELETE 7일치 (results/delete-elapsed.txt)

```console
$ mysql> DELETE FROM watch_log_plain WHERE created_at < '2026-07-21';
DELETE 소요: 20.457초
```

### 실험 2: DROP PARTITION 7일치 (results/drop-elapsed.txt)

```console
$ mysql> ALTER TABLE watch_log_part DROP PARTITION p20260714, ..., p20260720;
DROP PARTITION 소요: 0.122초
```

행 수를 보고하지 않는다는 공식 문서 서술대로, 350만 행이 사라졌는데 영향 행 수는 0으로 나옵니다.

### 실험 3: MDL 대기 행렬 (results/mdl-locks.txt)

세션 A가 `START TRANSACTION; SELECT ...`만 하고 커밋하지 않은 상태에서:

```console
| OBJECT_NAME    | LOCK_TYPE           | LOCK_STATUS |
| watch_log_part | SHARED_READ         | GRANTED     |  ← A의 열린 트랜잭션
| watch_log_part | EXCLUSIVE           | PENDING     |  ← B의 DROP PARTITION
| watch_log_part | SHARED_READ         | PENDING     |  ← C의 평범한 SELECT

$ SHOW PROCESSLIST
| 661 | Waiting for table metadata lock | ALTER TABLE watch_log_part DROP PARTITION p20260721 |
| 663 | Waiting for table metadata lock | SELECT COUNT(*) FROM watch_log_part WHERE ...       |

DROP PARTITION: 23.7초 대기
일반 SELECT:   20.7초 대기
```

### 실험 4: 프루닝 (results/pruning-explain.txt)

```console
WHERE created_at >= '2026-07-27'       → partitions: p20260722,p20260727,pmax
WHERE DATE(created_at) = '2026-07-27'  → partitions: 남은 7개 전부 (프루닝 없음)
```

### 실험 5: 파티션 키 제약 (results/error-1503.txt)

```console
$ mysql> CREATE TABLE bad_part (id BIGINT AUTO_INCREMENT PRIMARY KEY, created_at DATETIME NOT NULL)
         PARTITION BY RANGE (TO_DAYS(created_at)) (PARTITION p0 VALUES LESS THAN MAXVALUE);
ERROR 1503 (HY000): A PRIMARY KEY must include all columns in the table's
partitioning function (prefixed columns are not considered).
```

### 실험 6: 청크 삭제 (results/chunked-*)

1만 행 `DELETE ... LIMIT`을 350회 반복, INSERT 병행. 46.1초 소요.
히스토리 리스트 길이 최대 46 (한 방 DELETE에서는 최대 3).

## 3. 집계

```console
$ python3 scripts/report.py

[DELETE] 삭제 소요 20.47초
  INSERT p95  삭제 전 5.2ms → 삭제 중 10.8ms → 삭제 후 5.3ms
[DROP] 삭제 소요 0.13초
  INSERT p95  삭제 전 4.9ms → 삭제 중 5.7ms → 삭제 후 8.8ms

파일 크기  plain 0.70 → 0.70GB, part 0.77 → 0.42GB
```

## 원문 파일 위치

| 내용 | 경로 |
|---|---|
| 건별 INSERT 지연 | `results/delete-oltp.csv`, `results/drop-oltp.csv`, `results/chunked-oltp.csv` |
| 히스토리 리스트·파일 크기 1초 시계열 | `results/*-poll.csv` |
| MDL 대기 행렬 스냅샷 | `results/mdl-locks.txt` |
| 프루닝 EXPLAIN 원문 | `results/pruning-explain.txt` |
| 실험 로그 전체 | `results/experiments.log` |
