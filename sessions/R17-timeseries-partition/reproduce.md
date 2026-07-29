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

`plain 0.70 → 0.70GB`는 GB 단위 반올림입니다. `results/delete-poll.csv`의 원값은 746,586,112 → 754,974,720바이트로, 줄어든 게 아니라 **8MiB(4MiB 익스텐트 두 번) 늘었습니다.** 삭제 중에도 INSERT 8스레드가 돌고 있었기 때문입니다. 테이블별 .ibd가 따로 있는 것은 `innodb_file_per_table`이 켜져 있어서이고(8.4 기본값 ON, 이 세션에서 끄지 않음), 공간을 OS로 돌려받으려면 `OPTIMIZE TABLE`이 필요한데 이 세션에서는 돌리지 않았습니다.

관측 창이 두 실험에서 다릅니다. DELETE는 480초(삭제 후 450초), DROP은 120초(삭제 후 110초)입니다. "삭제 후" p95의 5.3ms와 8.8ms를 같은 조건의 평균으로 비교할 수 없습니다.

실험 1과 2 사이의 안정화 대기도 이 기록을 만든 판본에서는 무효였습니다. 임계값이 히스토리 리스트 길이 1000인데 실측 최대가 3이라 첫 판정에서 통과했고, 타임스탬프상 DELETE 쪽 관측 종료 3.1초 뒤에 DROP 쪽 관측이 시작됐습니다. 스크립트는 최소 대기 60초와 임계값 10으로 고쳤으나 그 뒤로 다시 돌리지 않았습니다.

실험 3의 세션 B는 `LOCK` 절 없이 `ALTER TABLE watch_log_part DROP PARTITION p20260721;`을 실행했습니다. `LOCK=NONE` 조건은 이 세션에서 재지 않았습니다. `results/fig-mdl.png`의 제목에 `LOCK=NONE`이 남아 있어 재생성이 필요합니다.

## 원문 파일 위치

| 내용 | 경로 |
|---|---|
| 건별 INSERT 지연 | `results/delete-oltp.csv`, `results/drop-oltp.csv`, `results/chunked-oltp.csv` |
| 히스토리 리스트·파일 크기 1초 시계열 | `results/*-poll.csv` |
| MDL 대기 행렬 스냅샷 | `results/mdl-locks.txt` |
| 프루닝 EXPLAIN 원문 | `results/pruning-explain.txt` |
| 소요 시간과 남은 행 수 | `results/delete-elapsed.txt`, `results/drop-elapsed.txt`, `results/chunked-elapsed.txt` |
| 파티션 키 제약 에러 원문 | `results/error-1503.txt` |
| 사후 .ibd 파일 목록 | `results/post-ibd.txt` |
