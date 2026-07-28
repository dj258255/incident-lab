# 재현 기록

실행한 명령과 출력을 원문 그대로 남깁니다. 요약하지 않습니다. 아래 발췌는 전부 한 번의
`docker compose up` 출력에서 가져왔고, 전체 로그 원문은 [results/full-run.txt](results/full-run.txt)에 있습니다.
같은 로그는 언제든 `docker compose up --abort-on-container-exit`로 다시 만들 수 있습니다.

`lab-b43-runner` 접두어가 psql 클라이언트 출력이고 `lab-b43-pg` 접두어가 서버 로그입니다.
서버 쪽은 `log_lock_waits=on`을 켜 두어서 락 대기가 `deadlock_timeout`(1초)을 넘기면 누가 누구를 기다리는지
서버가 직접 기록합니다. 클라이언트가 잰 시간과 서버가 기록한 대기 시간을 대조할 수 있습니다.

## 환경

- 호스트: Rocky Linux 9.6 (aarch64), 2 vCPU / 11.3 GB RAM, Docker 29.4.2, Docker Compose v5.1.3
- DB: postgres:16-alpine (PostgreSQL 16.14 on aarch64-unknown-linux-musl). 호스트 포트는 게시하지 않습니다
- 서버 설정: 이미지 기본값(shared_buffers 128MB, max_wal_size 기본)에 `log_lock_waits=on`과 `log_line_prefix`만 추가
- 러너: 같은 이미지의 psql이 `scripts/run.sh`를 실행하며 여러 세션을 sleep 간격으로 띄웁니다
- 데이터: `generate_series(1, 3000000)`에서 파생한 결정적 시드. 난수를 쓰지 않아 두 테이블(`orders_v1`, `orders_v2`)이 같습니다. 힙 195 MB, 인덱스 포함 260 MB
- 시간 측정: psql `\timing`. 문장 하나가 자기 트랜잭션에서 실행되므로 문장 소요 시간이 곧 락 보유 시간의 상한입니다
- 일시: 2026-07-28. 300만 행으로 5회 실행했고 아래는 5회차 원문입니다. 회차별 차이와 스크립트를 고친 이유는 맨 끝에 표로 적었습니다

## 1. 기동과 환경 확인

```console
$ docker compose up --abort-on-container-exit
 Container lab-b43-pg Created
 Container lab-b43-runner Created
 Container lab-b43-pg Healthy
 Container lab-b43-runner Starting

lab-b43-runner  | [0] 환경
lab-b43-runner  | ==================================================================
 Container lab-b43-runner Started 
lab-b43-runner  |                                             version                                             
lab-b43-runner  | ------------------------------------------------------------------------------------------------
lab-b43-runner  |  PostgreSQL 16.14 on aarch64-unknown-linux-musl, compiled by gcc (Alpine 15.2.0) 15.2.0, 64-bit
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  |  lock_timeout 
lab-b43-runner  | --------------
lab-b43-runner  |  0
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  |  deadlock_timeout 
lab-b43-runner  | ------------------
lab-b43-runner  |  1s
lab-b43-runner  | (1 row)
lab-b43-runner  | 
```

`lock_timeout`이 `0`입니다. 락 대기에 상한이 없다는 뜻입니다.

## 2. 시드

```console
lab-b43-runner  | [1] 시드: 3000000행 주문 테이블 두 벌 (orders_v1 = 문제 방식, orders_v2 = 해소 방식)
lab-b43-runner  | ==================================================================
lab-b43-runner  | Timing is on.
lab-b43-runner  | DROP TABLE
lab-b43-runner  | Time: 1.063 ms
lab-b43-runner  | psql:/scripts/seed.sql:7: NOTICE:  table "orders_v1" does not exist, skipping
lab-b43-runner  | DROP TABLE
lab-b43-runner  | Time: 0.260 ms
lab-b43-runner  | psql:/scripts/seed.sql:8: NOTICE:  table "orders_v2" does not exist, skipping
lab-b43-runner  | CREATE TABLE
lab-b43-runner  | Time: 8.496 ms
lab-b43-runner  | INSERT 0 3000000
lab-b43-runner  | Time: 10519.063 ms (00:10.519)
lab-b43-runner  | ALTER TABLE
lab-b43-runner  | Time: 3839.664 ms (00:03.840)
lab-b43-runner  | CREATE TABLE
lab-b43-runner  | Time: 8.272 ms
lab-b43-pg      | 2026-07-28 22:43:14.612 UTC [55] LOG:  checkpoints are occurring too frequently (24 seconds apart)
lab-b43-pg      | 2026-07-28 22:43:14.612 UTC [55] HINT:  Consider increasing the configuration parameter "max_wal_size".
lab-b43-pg      | 2026-07-28 22:43:14.613 UTC [55] LOG:  checkpoint starting: wal
lab-b43-runner  | INSERT 0 3000000
lab-b43-runner  | Time: 24123.917 ms (00:24.124)
lab-b43-pg      | 2026-07-28 22:43:31.654 UTC [69] psqlLOG:  process 69 still waiting for ShareUpdateExclusiveLock on relation 16385 of database 16384 after 1000.080 ms
lab-b43-pg      | 2026-07-28 22:43:31.654 UTC [69] psqlDETAIL:  Process holding the lock: 160. Wait queue: 69.
lab-b43-pg      | 2026-07-28 22:43:31.654 UTC [69] psqlSTATEMENT:  VACUUM ANALYZE orders_v1;
lab-b43-pg      | 2026-07-28 22:43:31.654 UTC [160] ERROR:  canceling autovacuum task
lab-b43-pg      | 2026-07-28 22:43:31.654 UTC [160] CONTEXT:  while scanning block 11733 of relation "public.orders_v1"
lab-b43-pg      | 	automatic vacuum of table "lab.public.orders_v1"
lab-b43-pg      | 2026-07-28 22:43:31.655 UTC [69] psqlLOG:  process 69 acquired ShareUpdateExclusiveLock on relation 16385 of database 16384 after 1001.143 ms
lab-b43-pg      | 2026-07-28 22:43:31.655 UTC [69] psqlSTATEMENT:  VACUUM ANALYZE orders_v1;
lab-b43-runner  | VACUUM
lab-b43-runner  | Time: 1417.099 ms (00:01.417)
lab-b43-runner  | VACUUM
lab-b43-runner  | Time: 523.892 ms
lab-b43-pg      | 2026-07-28 22:43:39.332 UTC [55] LOG:  checkpoint complete: wrote 48 buffers (0.3%); 0 WAL file(s) added, 0 removed, 33 recycled; write=17.979 s, sync=6.700 s, total=24.720 s; sync files=47, longest=3.260 s, average=0.143 s; distance=534664 kB, estimate=534664 kB; lsn=0/33B71FF0, redo lsn=0/22348058
lab-b43-pg      | 2026-07-28 22:43:39.332 UTC [55] LOG:  checkpoint starting: immediate force wait
lab-b43-pg      | 2026-07-28 22:43:41.764 UTC [55] LOG:  checkpoint complete: wrote 14845 buffers (90.6%); 0 WAL file(s) added, 0 removed, 17 recycled; write=2.176 s, sync=0.236 s, total=2.433 s; sync files=15, longest=0.214 s, average=0.016 s; distance=286888 kB, estimate=509887 kB; lsn=0/33B9FB78, redo lsn=0/33B72080
lab-b43-runner  | CHECKPOINT
lab-b43-runner  | Time: 9171.254 ms (00:09.171)
lab-b43-runner  | Timing is off.
lab-b43-runner  |   테이블   |  행 수  | 힙 크기 | 인덱스 포함 | relfilenode 
```

마지막 `CHECKPOINT`는 측정 준비입니다. 시드가 만든 WAL 때문에 체크포인트가 계속 돌고 있는데,
그 상태로 밀리초짜리 DDL을 재면 커밋 fsync가 체크포인트 뒤에 줄을 서서 수백 ms로 부풀어 오릅니다.
이걸 넣기 전 실행에서 상수 기본값 ALTER가 496.510 / 265.306 / 287.599 ms로 나왔고, 넣은 뒤에는 한 자릿수 ms로 떨어졌습니다.
맨 끝 회차별 표의 3회차와 4회차가 그 차이입니다.

## 3. 실험 1: 상수 기본값 ADD COLUMN은 재현에 실패한다

같은 형태의 `ADD COLUMN ... NOT NULL DEFAULT <상수>`를 연달아 세 번 걸었습니다.

```console
lab-b43-runner  | [2] 실험 1: 상수 기본값 ADD COLUMN. 카탈로그대로 걸면 재현에 실패한다
lab-b43-runner  | ==================================================================
lab-b43-runner  | Timing is off.
lab-b43-runner  |  ALTER 전 relfilenode | 힙 크기 
lab-b43-runner  | ----------------------+---------
lab-b43-runner  |                 16385 | 195 MB
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | Timing is on.
lab-b43-runner  | ALTER TABLE
lab-b43-runner  | Time: 3.614 ms
lab-b43-runner  | ALTER TABLE
lab-b43-runner  | Time: 1.245 ms
lab-b43-runner  | ALTER TABLE
lab-b43-runner  | Time: 3.728 ms
lab-b43-runner  | Timing is off.
lab-b43-runner  |  ALTER 후 relfilenode | 힙 크기 
lab-b43-runner  | ----------------------+---------
lab-b43-runner  |                 16385 | 195 MB
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  |      컬럼     | 힙에 없는 값을 카탈로그로 대신하나 | 카탈로그에 저장된 기본값 
lab-b43-runner  | --------------+------------------------------------+--------------------------
lab-b43-runner  |  status_code  | t                                  | {0}
lab-b43-runner  |  retry_count  | t                                  | {0}
lab-b43-runner  |  is_cancelled | t                                  | {f}
lab-b43-runner  | (3 rows)
lab-b43-runner  | 
lab-b43-runner  | Timing is on.
lab-b43-runner  |  status_code = 0 인 행 수 
lab-b43-runner  | --------------------------
lab-b43-runner  |                   3000000
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | Time: 359.498 ms
```

`relfilenode`가 16385로 그대로이고 힙 크기도 195 MB 그대로입니다. 300만 행 중 한 행도 다시 쓰지 않았습니다.
`pg_attribute.atthasmissing = t`와 `attmissingval = {0}`이 값이 어디 있는지 알려 줍니다.

기본값 없이 NOT NULL만 붙이면 이렇게 됩니다.

```console
lab-b43-runner  | 기본값 없이 NOT NULL만 붙이면 어떻게 되나:
lab-b43-runner  | Timing is on.
lab-b43-pg      | 2026-07-28 22:43:42.467 UTC [246] psqlERROR:  column "must_fail" of relation "orders_v1" contains null values
lab-b43-pg      | 2026-07-28 22:43:42.467 UTC [246] psqlSTATEMENT:  ALTER TABLE orders_v1 ADD COLUMN must_fail integer NOT NULL;
lab-b43-runner  | psql:/scripts/exp1b-no-default.sql:4: ERROR:  column "must_fail" of relation "orders_v1" contains null values
lab-b43-runner  | Time: 1.792 ms
lab-b43-runner  | 
```

## 4. 실험 2와 3: volatile 기본값은 테이블을 다시 쓰고 그동안 SELECT를 막는다

```console
lab-b43-runner  | [3] 실험 2·3: volatile 기본값 ADD COLUMN. 재작성이 일어나고 그동안 SELECT가 막힌다
lab-b43-runner  | ==================================================================
lab-b43-runner  | 기준선(락 없음): SELECT count(*) 3회
lab-b43-runner  |   기준선 1회차: 3000000 Time: 285.646 ms 
lab-b43-runner  |   기준선 2회차: 3000000 Time: 245.235 ms 
lab-b43-runner  |   기준선 3회차: 3000000 Time: 311.744 ms 
lab-b43-runner  | 
lab-b43-runner  | volatile ALTER를 걸고 1초 뒤 다른 세션에서 SELECT count(*)를 실행한다.
lab-b43-pg      | 2026-07-28 22:43:47.402 UTC [271] readerLOG:  process 271 still waiting for AccessShareLock on relation 16385 of database 16384 after 1001.819 ms at character 22
lab-b43-pg      | 2026-07-28 22:43:47.402 UTC [271] readerDETAIL:  Process holding the lock: 263. Wait queue: 271.
lab-b43-pg      | 2026-07-28 22:43:47.402 UTC [271] readerSTATEMENT:  SELECT count(*) FROM orders_v1;
lab-b43-pg      | 2026-07-28 22:43:56.623 UTC [271] readerLOG:  process 271 acquired AccessShareLock on relation 16385 of database 16384 after 10222.584 ms at character 22
lab-b43-pg      | 2026-07-28 22:43:56.623 UTC [271] readerSTATEMENT:  SELECT count(*) FROM orders_v1;
```

```console
lab-b43-runner  | --- volatile ALTER 세션 (application_name=ddl) ---
lab-b43-runner  | Timing is off.
lab-b43-runner  |  ALTER 전 relfilenode | 힙 크기 
lab-b43-runner  | ----------------------+---------
lab-b43-runner  |                 16385 | 195 MB
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | Timing is on.
lab-b43-runner  | ALTER TABLE
lab-b43-runner  | Time: 11316.601 ms (00:11.317)
lab-b43-runner  | Timing is off.
lab-b43-runner  |  ALTER 후 relfilenode | 힙 크기 
lab-b43-runner  | ----------------------+---------
lab-b43-runner  |                 16407 | 290 MB
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  |    컬럼   | 힙에 없는 값을 카탈로그로 대신하나 | 카탈로그에 저장된 기본값 
lab-b43-runner  | ----------+------------------------------------+--------------------------
lab-b43-runner  |  trace_id | f                                  | 
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | --- ALTER가 도는 동안의 락 상태 ---
lab-b43-runner  |  pid |  세션  |      요청한 락      | 상태 |  대기 이벤트  | 막고 있는 pid | 경과(초) |                      질의                      
lab-b43-runner  | -----+--------+---------------------+------+---------------+---------------+----------+------------------------------------------------
lab-b43-runner  |  263 | ddl    | AccessExclusiveLock | 획득 | -             | {}            |      2.0 | ALTER TABLE orders_v1 ADD COLUMN trace_id uuid
lab-b43-runner  |  271 | reader | AccessShareLock     | 대기 | Lock:relation | {263}         |      1.0 | SELECT count(*) FROM orders_v1;
lab-b43-runner  | (2 rows)
lab-b43-runner  | --- 그동안 대기하던 SELECT 세션 (application_name=reader) ---
lab-b43-runner  | Timing is on.
lab-b43-runner  |   count  
lab-b43-runner  | ---------
lab-b43-runner  |  3000000
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | Time: 10936.495 ms (00:10.936)
```

`relfilenode`가 16385에서 16407로 바뀌었습니다. 파일이 새로 만들어졌으니 재작성입니다.
`atthasmissing = f`이고 저장된 기본값도 없습니다. 힙은 195 MB에서 290 MB로 늘었습니다.
서버 로그의 `acquired AccessShareLock ... after 10222.584 ms`와 클라이언트가 잰 10,936.495 ms가 맞물립니다.
차이 약 0.7초가 락을 얻은 뒤 실제로 300만 행을 센 시간이고, 락 없을 때 기준선 245~312 ms와 같은 자리입니다.

## 5. 실험 4: 락 큐잉

장기 실행 트랜잭션이 ACCESS SHARE를 쥔 상태에서 실험 1과 같은 종류의 빠른 ALTER를 걸고,
그 뒤에 평범한 `SELECT count(*)` 세 건을 1초 간격으로 넣었습니다.

```console
lab-b43-runner  | [4] 실험 4: 락 큐잉. 빠른 ALTER가 장기 트랜잭션 뒤에 서면 뒤따르는 SELECT까지 전부 줄을 선다
lab-b43-runner  | ==================================================================
lab-b43-runner  | 재작성 뒤 기준선을 다시 잰다(테이블이 커졌다).
lab-b43-runner  |   기준선 1회차: 3000000 Time: 284.154 ms 
lab-b43-runner  |   기준선 2회차: 3000000 Time: 276.798 ms 
lab-b43-runner  | 
lab-b43-runner  | 타임라인: 0초 장기 트랜잭션(12초 유지) / 2초 ALTER / 4·5·6초 평범한 SELECT 3건
```

서버가 대기 큐를 직접 기록합니다. `Wait queue`가 `325`(ALTER) 뒤에 `333, 341, 342`(SELECT 3건)로 자라납니다.

```console
lab-b43-pg      | 2026-07-28 22:44:01.965 UTC [325] ddlLOG:  process 325 still waiting for AccessExclusiveLock on relation 16385 of database 16384 after 1000.068 ms
lab-b43-pg      | 2026-07-28 22:44:01.965 UTC [325] ddlDETAIL:  Process holding the lock: 316. Wait queue: 325.
lab-b43-pg      | 2026-07-28 22:44:01.965 UTC [325] ddlSTATEMENT:  ALTER TABLE orders_v1 ADD COLUMN is_test boolean NOT NULL DEFAULT false;
lab-b43-pg      | 2026-07-28 22:44:03.958 UTC [333] reader-1LOG:  process 333 still waiting for AccessShareLock on relation 16385 of database 16384 after 1000.095 ms at character 22
lab-b43-pg      | 2026-07-28 22:44:03.958 UTC [333] reader-1DETAIL:  Process holding the lock: 316. Wait queue: 325, 333.
lab-b43-pg      | 2026-07-28 22:44:03.958 UTC [333] reader-1STATEMENT:  SELECT count(*) FROM orders_v1;
lab-b43-pg      | 2026-07-28 22:44:04.961 UTC [341] reader-2LOG:  process 341 still waiting for AccessShareLock on relation 16385 of database 16384 after 1000.079 ms at character 22
lab-b43-pg      | 2026-07-28 22:44:04.961 UTC [341] reader-2DETAIL:  Process holding the lock: 316. Wait queue: 325, 333, 341, 342.
lab-b43-pg      | 2026-07-28 22:44:04.961 UTC [341] reader-2STATEMENT:  SELECT count(*) FROM orders_v1;
lab-b43-pg      | 2026-07-28 22:44:05.960 UTC [342] reader-3LOG:  process 342 still waiting for AccessShareLock on relation 16385 of database 16384 after 1000.058 ms at character 22
lab-b43-pg      | 2026-07-28 22:44:05.960 UTC [342] reader-3DETAIL:  Process holding the lock: 316. Wait queue: 325, 333, 341, 342.
lab-b43-pg      | 2026-07-28 22:44:05.960 UTC [342] reader-3STATEMENT:  SELECT count(*) FROM orders_v1;
lab-b43-pg      | 2026-07-28 22:44:10.959 UTC [325] ddlLOG:  process 325 still waiting for AccessExclusiveLock on relation 16385 of database 16384 after 9994.135 ms
lab-b43-pg      | 2026-07-28 22:44:10.959 UTC [325] ddlDETAIL:  Process holding the lock: 316. Wait queue: 325, 333, 341, 342.
lab-b43-pg      | 2026-07-28 22:44:10.959 UTC [325] ddlSTATEMENT:  ALTER TABLE orders_v1 ADD COLUMN is_test boolean NOT NULL DEFAULT false;
lab-b43-pg      | 2026-07-28 22:44:10.974 UTC [325] ddlLOG:  process 325 acquired AccessExclusiveLock on relation 16385 of database 16384 after 10009.453 ms
lab-b43-pg      | 2026-07-28 22:44:10.974 UTC [325] ddlSTATEMENT:  ALTER TABLE orders_v1 ADD COLUMN is_test boolean NOT NULL DEFAULT false;
lab-b43-pg      | 2026-07-28 22:44:10.980 UTC [341] reader-2LOG:  process 341 acquired AccessShareLock on relation 16385 of database 16384 after 7018.984 ms at character 22
lab-b43-pg      | 2026-07-28 22:44:10.980 UTC [341] reader-2STATEMENT:  SELECT count(*) FROM orders_v1;
lab-b43-pg      | 2026-07-28 22:44:10.984 UTC [342] reader-3LOG:  process 342 acquired AccessShareLock on relation 16385 of database 16384 after 6019.961 ms at character 22
lab-b43-pg      | 2026-07-28 22:44:10.984 UTC [342] reader-3STATEMENT:  SELECT count(*) FROM orders_v1;
lab-b43-pg      | 2026-07-28 22:44:10.984 UTC [333] reader-1LOG:  process 333 acquired AccessShareLock on relation 16385 of database 16384 after 8022.182 ms at character 22
lab-b43-pg      | 2026-07-28 22:44:10.984 UTC [333] reader-1STATEMENT:  SELECT count(*) FROM orders_v1;
```

`pg_blocking_pids()`는 SELECT 세 건을 막는 것이 장기 트랜잭션(316)이 아니라 그 앞에 끼어든 ALTER(325)라고 답합니다.

```console
lab-b43-runner  | --- 대기 사슬 (장기 트랜잭션 시작 7초 시점) ---
lab-b43-runner  |  pid |   세션   |      요청한 락      | 상태 |   대기 이벤트   | 막고 있는 pid | 경과(초) |                      질의                      
lab-b43-runner  | -----+----------+---------------------+------+-----------------+---------------+----------+------------------------------------------------
lab-b43-runner  |  316 | long-txn | AccessShareLock     | 획득 | Timeout:PgSleep | {}            |      7.0 | SELECT pg_sleep(12);
lab-b43-runner  |  325 | ddl      | AccessExclusiveLock | 대기 | Lock:relation   | {316}         |      5.0 | ALTER TABLE orders_v1 ADD COLUMN is_test boole
lab-b43-runner  |  333 | reader-1 | AccessShareLock     | 대기 | Lock:relation   | {325}         |      3.0 | SELECT count(*) FROM orders_v1;
lab-b43-runner  |  341 | reader-2 | AccessShareLock     | 대기 | Lock:relation   | {325}         |      2.0 | SELECT count(*) FROM orders_v1;
lab-b43-runner  |  342 | reader-3 | AccessShareLock     | 대기 | Lock:relation   | {325}         |      1.0 | SELECT count(*) FROM orders_v1;
lab-b43-runner  | (5 rows)
```

클라이언트가 잰 시간입니다. ALTER는 `lock_timeout`이 0이라 12초짜리 트랜잭션이 끝날 때까지 그대로 기다렸습니다.

```console
lab-b43-runner  | --- ALTER 세션: 실험 1에서 밀리초에 끝났던 것과 같은 종류의 문장이다 ---
lab-b43-runner  | Timing is on.
lab-b43-runner  |  lock_timeout 
lab-b43-runner  | --------------
lab-b43-runner  |  0
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | Time: 0.337 ms
lab-b43-runner  | ALTER TABLE
lab-b43-runner  | Time: 10028.718 ms (00:10.029)
lab-b43-runner  | --- 뒤에 줄 선 평범한 SELECT 3건 ---
lab-b43-runner  | Timing is on.
lab-b43-runner  |   count  
lab-b43-runner  | ---------
lab-b43-runner  |  3000000
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | Time: 9014.036 ms (00:09.014)
lab-b43-runner  | Timing is on.
lab-b43-runner  |   count  
lab-b43-runner  | ---------
lab-b43-runner  |  3000000
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | Time: 7981.576 ms (00:07.982)
lab-b43-runner  | Timing is on.
lab-b43-runner  |   count  
lab-b43-runner  | ---------
lab-b43-runner  |  3000000
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | Time: 6998.568 ms (00:06.999)
```

## 6. 해소 1: lock_timeout

같은 타임라인에서 ALTER 세션만 `SET lock_timeout = '2s'`로 바꿨습니다.

```console
lab-b43-runner  | [5] 해소 1: lock_timeout으로 대기를 끊는다 (기본값 0 = 무제한)
lab-b43-runner  | ==================================================================
lab-b43-runner  | 같은 타임라인에 ALTER 세션만 lock_timeout = 2s 로 바꾼다.
lab-b43-pg      | 2026-07-28 22:44:14.994 UTC [387] ddlLOG:  process 387 still waiting for AccessExclusiveLock on relation 16385 of database 16384 after 1000.043 ms
lab-b43-pg      | 2026-07-28 22:44:14.994 UTC [387] ddlDETAIL:  Process holding the lock: 378. Wait queue: 387.
lab-b43-pg      | 2026-07-28 22:44:14.994 UTC [387] ddlSTATEMENT:  ALTER TABLE orders_v1 ADD COLUMN is_test2 boolean NOT NULL DEFAULT false;
lab-b43-pg      | 2026-07-28 22:44:15.994 UTC [387] ddlERROR:  canceling statement due to lock timeout
lab-b43-pg      | 2026-07-28 22:44:15.994 UTC [387] ddlSTATEMENT:  ALTER TABLE orders_v1 ADD COLUMN is_test2 boolean NOT NULL DEFAULT false;
lab-b43-runner  | 
lab-b43-runner  | --- ALTER 세션 (lock_timeout = 2s) ---
lab-b43-runner  | Timing is on.
lab-b43-runner  | SET
lab-b43-runner  | Time: 0.210 ms
lab-b43-runner  |  lock_timeout 
lab-b43-runner  | --------------
lab-b43-runner  |  2s
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | Time: 0.272 ms
lab-b43-runner  | psql:/scripts/fast-alter-timeout.sql:6: ERROR:  canceling statement due to lock timeout
lab-b43-runner  | Time: 2001.193 ms (00:02.001)
lab-b43-runner  | --- ALTER 뒤에 줄 섰던 SELECT (3초 시점 시작) ---
lab-b43-runner  | Timing is on.
lab-b43-runner  |   count  
lab-b43-runner  | ---------
lab-b43-runner  |  3000000
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | Time: 1196.543 ms (00:01.197)
lab-b43-runner  | --- ALTER가 물러난 뒤 들어온 SELECT (7초 시점 시작) ---
lab-b43-runner  | Timing is on.
lab-b43-runner  |   count  
lab-b43-runner  | ---------
lab-b43-runner  |  3000000
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | Time: 470.685 ms
lab-b43-runner  | --- 장기 트랜잭션이 끝난 뒤 같은 ALTER를 다시 건다 ---
lab-b43-runner  | Timing is on.
lab-b43-runner  | SET
lab-b43-runner  | Time: 0.169 ms
lab-b43-runner  | ALTER TABLE
lab-b43-runner  | Time: 2.889 ms
```

## 7. 해소 2: 3단계 expand-contract

손대지 않은 `orders_v2`(300만 행, 195 MB)에서 실험 2와 같은 목표를 여러 단계로 나눠 수행했습니다.

### 1단계: nullable 컬럼 추가

```console
lab-b43-runner  | [6] 해소 2: 3단계 expand-contract (orders_v2, 손대지 않은 3000000행)
lab-b43-runner  | ==================================================================
lab-b43-runner  | 목표는 실험 2와 같다. 모든 행에 uuid 값이 든 NOT NULL 컬럼을 만든다.
lab-b43-runner  | 
lab-b43-runner  | 기준선(락 없음): SELECT count(*) 2회
lab-b43-runner  |   기준선 1회차: 3000000 Time: 172.575 ms 
lab-b43-runner  |   기준선 2회차: 3000000 Time: 158.454 ms 
lab-b43-runner  | 
lab-b43-runner  | --- 1단계(expand): nullable 컬럼 추가 ---
lab-b43-runner  | Timing is off.
lab-b43-runner  |  1단계 전 relfilenode | 힙 크기 
lab-b43-runner  | ----------------------+---------
lab-b43-runner  |                 16392 | 195 MB
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | Timing is on.
lab-b43-runner  | ALTER TABLE
lab-b43-runner  | Time: 1.495 ms
lab-b43-runner  | Timing is off.
lab-b43-runner  |  1단계 후 relfilenode | 힙 크기 
lab-b43-runner  | ----------------------+---------
lab-b43-runner  |                 16392 | 195 MB
lab-b43-runner  | (1 row)
lab-b43-runner  | 
```

### 2단계: 10만 행씩 30청크 백필

```console
lab-b43-runner  | --- 2단계(backfill): 100000행씩 나눠 UPDATE. 청크마다 커밋한다 ---
lab-b43-pg      | 2026-07-28 22:44:29.084 UTC [55] LOG:  checkpoint starting: wal
lab-b43-pg      | 2026-07-28 22:44:50.833 UTC [55] LOG:  checkpoint complete: wrote 3509 buffers (21.4%); 0 WAL file(s) added, 0 removed, 33 recycled; write=16.644 s, sync=4.952 s, total=21.749 s; sync files=42, longest=3.441 s, average=0.118 s; distance=531399 kB, estimate=531399 kB; lsn=0/72F89720, redo lsn=0/54264030
lab-b43-pg      | 2026-07-28 22:44:52.018 UTC [55] LOG:  checkpoints are occurring too frequently (23 seconds apart)
lab-b43-pg      | 2026-07-28 22:44:52.018 UTC [55] HINT:  Consider increasing the configuration parameter "max_wal_size".
lab-b43-pg      | 2026-07-28 22:44:52.018 UTC [55] LOG:  checkpoint starting: wal
lab-b43-runner  |   백필 전체 소요 = 39.522 초 (100000행 x 30청크)
lab-b43-runner  |     백필 중 SELECT 1회차: 3000000 Time: 283.134 ms 
lab-b43-runner  |     백필 중 SELECT 2회차: 3000000 Time: 407.592 ms 
lab-b43-runner  |     백필 중 SELECT 3회차: 3000000 Time: 498.715 ms 
lab-b43-runner  |     백필 중 SELECT 4회차: 3000000 Time: 520.042 ms 
lab-b43-runner  |     백필 중 SELECT 5회차: 3000000 Time: 2422.325 ms (00:02.422) 
lab-b43-runner  |     백필 중 SELECT 6회차: 3000000 Time: 542.811 ms 
lab-b43-runner  |     백필 중 SELECT 7회차: 3000000 Time: 637.064 ms 
lab-b43-runner  |     백필 중 SELECT 8회차: 3000000 Time: 446.039 ms 
lab-b43-runner  |  trace_id 채워진 행 | 아직 NULL 
lab-b43-runner  | --------------------+-----------
lab-b43-runner  |             3000000 |         0
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  |  백필 후 힙 크기 | 산 튜플 | 죽은 튜플 | 마지막 autovacuum 
lab-b43-runner  | -----------------+---------+-----------+-------------------
lab-b43-runner  |  437 MB          | 3000000 |   2999730 | 아직 없음
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | 
```

### 3단계 앞: CHECK ... NOT VALID

```console
lab-b43-runner  | --- 3단계(contract) 앞: CHECK ... NOT VALID ---
lab-b43-runner  | Timing is on.
lab-b43-runner  | BEGIN
lab-b43-runner  | Time: 0.288 ms
lab-b43-runner  | ALTER TABLE
lab-b43-runner  | Time: 3.436 ms
lab-b43-runner  | Timing is off.
lab-b43-runner  |  이 문장이 orders_v2에 잡은 락 | 획득 
lab-b43-runner  | -------------------------------+------
lab-b43-runner  |  AccessExclusiveLock           | t
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | COMMIT
lab-b43-runner  |             제약             | 검증됨 
lab-b43-runner  | -----------------------------+--------
lab-b43-runner  |  orders_v2_trace_id_not_null | f
lab-b43-runner  | (1 row)
lab-b43-runner  | 
```

`NOT VALID`는 기존 300만 행을 검사하지 않으므로 3.436 ms에 끝났습니다. 락은 `pg_locks`가 직접 답한 대로
`AccessExclusiveLock`이지만 쥐고 있는 시간이 밀리초입니다.

이 문장이 항상 밀리초인 것은 아닙니다. 2회차에서는 같은 문장이 1010.226 ms 걸렸는데
그중 1002.736 ms는 락을 기다린 시간이었습니다. 백필이 남긴 죽은 튜플 299만 개를 autovacuum이 청소하던 중이었고,
서버가 그 autovacuum을 취소한 뒤에야 락을 줬습니다. 락을 쥐고 한 일 자체는 이번에도 밀리초입니다.
그 회차 로그를 [results/other-runs-excerpt.txt](results/other-runs-excerpt.txt)에 남겼습니다.
마지막 회차 로그에는 이 장면이 없습니다. autovacuum이 언제 붙느냐는 실행마다 다릅니다.

### 3단계 뒤: VALIDATE CONSTRAINT

`VALIDATE CONSTRAINT`를 명시 트랜잭션 안에서 실행하고 커밋 전에 5초를 붙들었습니다.
락 수준을 추측하지 않고 `pg_locks`로 직접 확인하기 위해서이고, 그 사이 다른 세션이 읽기를 세 번 돌립니다.
실제 배포에서 이렇게 붙들 이유는 없습니다. 관측을 위해 일부러 늘린 구간입니다.

```console
lab-b43-runner  | --- 3단계(contract) 뒤: VALIDATE CONSTRAINT. 락을 쥔 채로 SELECT를 같이 돌린다 ---
lab-b43-runner  | --- VALIDATE 세션이 락을 쥐고 있는 동안의 락 상태 ---
lab-b43-runner  |  pid |  세션  |        요청한 락         | 상태 |   대기 이벤트   | 막고 있는 pid | 경과(초) |              질의               
lab-b43-runner  | -----+--------+--------------------------+------+-----------------+---------------+----------+---------------------------------
lab-b43-runner  |  637 | ddl    | ShareUpdateExclusiveLock | 획득 | Timeout:PgSleep | {}            |      0.6 | SELECT pg_sleep(5);
lab-b43-runner  |  639 | reader | AccessShareLock          | 획득 | IO:DataFileRead | {}            |      0.0 | SELECT count(*) FROM orders_v2;
lab-b43-runner  |  641 | reader | AccessShareLock          | 획득 | IO:DataFileRead | {}            |      0.0 | SELECT count(*) FROM orders_v2;
lab-b43-runner  |  642 | reader | AccessShareLock          | 획득 | IO:DataFileRead | {}            |      0.0 | SELECT count(*) FROM orders_v2;
lab-b43-runner  | (4 rows)
lab-b43-runner  | --- VALIDATE 세션 ---
lab-b43-runner  | Timing is on.
lab-b43-runner  | BEGIN
lab-b43-runner  | Time: 0.914 ms
lab-b43-runner  | ALTER TABLE
lab-b43-runner  | Time: 402.312 ms
lab-b43-runner  | Timing is off.
lab-b43-runner  |  이 문장이 orders_v2에 잡은 락 | 획득 
lab-b43-runner  | -------------------------------+------
lab-b43-runner  |  ShareUpdateExclusiveLock      | t
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  |  pg_sleep 
lab-b43-runner  | ----------
lab-b43-runner  |  
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | COMMIT
lab-b43-runner  |             제약             | 검증됨 
lab-b43-runner  | -----------------------------+--------
lab-b43-runner  |  orders_v2_trace_id_not_null | t
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | --- 같은 시각에 돌린 SELECT ---
lab-b43-runner  | Timing is on.
lab-b43-runner  |   count  
lab-b43-runner  | ---------
lab-b43-runner  |  3000000
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | Time: 318.703 ms
lab-b43-runner  |   count  
lab-b43-runner  | ---------
lab-b43-runner  |  3000000
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | Time: 228.833 ms
lab-b43-runner  |   count  
lab-b43-runner  | ---------
lab-b43-runner  |  3000000
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | Time: 188.721 ms
```

`ddl` 세션이 `ShareUpdateExclusiveLock`을 획득한 채로 있고 읽기 세 건도 `AccessShareLock`을 획득한 상태입니다.
`막고 있는 pid`가 전부 `{}`입니다. 아무도 아무를 기다리지 않습니다.

이어서 같은 컬럼에 `SET NOT NULL`을 걸었고, 검증된 CHECK를 떼고 한 번 더 걸어 대조군을 만들었습니다.

### 마지막: SET NOT NULL, 대조군, 두 방식이 남긴 테이블 크기

```console
lab-b43-runner  | --- 마지막: 검증된 CHECK가 있는 상태에서 SET NOT NULL ---
lab-b43-runner  | Timing is on.
lab-b43-runner  | ALTER TABLE
lab-b43-runner  | Time: 2.354 ms
lab-b43-runner  | Timing is off.
lab-b43-runner  |    컬럼   | NOT NULL 
lab-b43-runner  | ----------+----------
lab-b43-runner  |  trace_id | t
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | 
lab-b43-runner  | --- 대조군: 검증된 CHECK를 떼고 같은 SET NOT NULL을 다시 건다 ---
lab-b43-runner  | Timing is off.
lab-b43-runner  | ALTER TABLE
lab-b43-runner  | ALTER TABLE
lab-b43-runner  |  NULL인 행(그대로 0이어야 한다) 
lab-b43-runner  | --------------------------------
lab-b43-runner  |                               0
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  |  orders_v2에 남은 CHECK 제약 수 
lab-b43-runner  | --------------------------------
lab-b43-runner  |                               0
lab-b43-runner  | (1 row)
lab-b43-runner  | 
lab-b43-runner  | Timing is on.
lab-b43-runner  | ALTER TABLE
lab-b43-runner  | Time: 474.538 ms
lab-b43-runner  | Timing is off.
lab-b43-runner  | 
lab-b43-runner  | --- 두 방식이 남긴 테이블 크기 ---
lab-b43-runner  |   테이블   | 힙 크기 | 인덱스 포함 
lab-b43-runner  | -----------+---------+-------------
lab-b43-runner  |  orders_v1 | 290 MB  | 354 MB
lab-b43-runner  |  orders_v2 | 437 MB  | 566 MB
lab-b43-runner  | (2 rows)
lab-b43-runner  | 
lab-b43-runner  | 
```

## 8. 재계측 요약 (러너가 출력한 원문)

```console
lab-b43-runner  | [7] 재계측 요약
lab-b43-runner  | ==================================================================
lab-b43-runner  | 조건: PostgreSQL 16.14, 3000000행, 같은 시드로 만든 두 테이블. 시간 단위는 ms.
lab-b43-runner  | 문장 하나가 자기 트랜잭션에서 실행되므로 문장 소요 시간이 곧 락 보유 시간의 상한이다.
lab-b43-runner  | 
lab-b43-runner  | [문제 A] volatile 기본값 한 방 ALTER (orders_v1)
lab-b43-runner  |   ALTER 소요 = ACCESS EXCLUSIVE 보유 : 11316.601 ms
lab-b43-runner  |   그동안 다른 세션 SELECT count(*)   : 10936.495 ms
lab-b43-runner  |   락 없을 때 같은 SELECT (기준선)    : 311.744 ms
lab-b43-runner  | 
lab-b43-runner  | [문제 B] 장기 트랜잭션 뒤에 선 빠른 ALTER (락 큐잉)
lab-b43-runner  |   상수 기본값 ALTER 단독 실행 3회    : 3.614 / 1.245 / 3.728 ms
lab-b43-runner  |   같은 ALTER가 대기 뒤에 섰을 때     : 10028.718 ms
lab-b43-runner  |   그 뒤에 줄 선 평범한 SELECT 3건    : 9014.036 / 7981.576 / 6998.568 ms
lab-b43-runner  |   락 없을 때 같은 SELECT (기준선)    : 284.154 ms
lab-b43-runner  | 
lab-b43-runner  | [해소 1] lock_timeout = 2s
lab-b43-runner  |   ALTER                              : 1 건 취소, 대기 2001.193 ms 만에 포기
lab-b43-runner  |   그 뒤에 줄 섰던 SELECT             : 1196.543 ms
lab-b43-runner  |   ALTER가 물러난 뒤 들어온 SELECT    : 470.685 ms
lab-b43-runner  |   장기 트랜잭션 종료 후 재시도       : 2.889 ms
lab-b43-runner  | 
lab-b43-runner  | [해소 2] 3단계 expand-contract (orders_v2)
lab-b43-runner  |   1단계 ADD COLUMN (nullable)        : 1.495 ms   <- ACCESS EXCLUSIVE 최대 보유
lab-b43-runner  |   2단계 백필 100000행 x 30청크 전체    : 39.522 초 (SELECT는 아래 표에)
lab-b43-runner  |   3단계 CHECK ... NOT VALID          : 3.436 ms
lab-b43-runner  |   4단계 VALIDATE CONSTRAINT          : 402.312 ms (SHARE UPDATE EXCLUSIVE)
lab-b43-runner  |   4단계와 동시에 돌린 SELECT         : 318.703 ms
lab-b43-runner  |   5단계 SET NOT NULL                 : 2.354 ms
lab-b43-runner  |   (대조군) CHECK 없이 SET NOT NULL   : 474.538 ms
lab-b43-runner  |   락 없을 때 같은 SELECT (기준선)    : 172.575 ms
lab-b43-runner  |   1~5단계 전체 소요                  : 39.9 초 (한 방 ALTER보다 길다. 이게 정직한 결과다)
lab-b43-runner  | 
lab-b43-runner  | 백필이 도는 동안 잰 SELECT count(*):
lab-b43-runner  |     백필 중 SELECT 1회차: 3000000 Time: 283.134 ms 
lab-b43-runner  |     백필 중 SELECT 2회차: 3000000 Time: 407.592 ms 
lab-b43-runner  |     백필 중 SELECT 3회차: 3000000 Time: 498.715 ms 
lab-b43-runner  |     백필 중 SELECT 4회차: 3000000 Time: 520.042 ms 
lab-b43-runner  |     백필 중 SELECT 5회차: 3000000 Time: 2422.325 ms (00:02.422) 
lab-b43-runner  |     백필 중 SELECT 6회차: 3000000 Time: 542.811 ms 
lab-b43-runner  |     백필 중 SELECT 7회차: 3000000 Time: 637.064 ms 
lab-b43-runner  |     백필 중 SELECT 8회차: 3000000 Time: 446.039 ms 
lab-b43-runner  | 
lab-b43-runner  | ==================================================================
```

## 9. 정리

```console
$ docker compose down -v
 Container lab-b43-pg Stopped
 Container lab-b43-pg Removing
 Container lab-b43-pg Removed
 Network b43-expand-contract_default Removing
 Network b43-expand-contract_default Removed
```

## 다섯 번 실행한 결과 비교

같은 날 300만 행으로 5회 돌렸습니다. 회차마다 스크립트를 한 군데씩 고쳤고, 무엇을 왜 고쳤는지 함께 적습니다.

| 회차 | 고친 것 |
|---|---|
| 1 | 최초 판본 |
| 2 | 상수 기본값 ALTER를 1회에서 3회 연속 측정으로 바꿈 |
| 3 | `SET NOT NULL` 대조군(검증된 CHECK 제거 후 재실행) 추가 |
| 4 | 시드 끝에 `CHECKPOINT` 추가. 측정 구간에서 체크포인트 잡음 제거 |
| 5 | 락 스냅샷 채택 조건만 조임. 측정에는 영향 없음 |

| 항목 | 1회차 | 2회차 | 3회차 | 4회차 | 5회차(위 원문) |
|---|---|---|---|---|---|
| 상수 기본값 ALTER | 45.806(1회) | 9.264 / 1.569 / 1.463 | 496.510 / 265.306 / 287.599 | 4.373 / 1.446 / 1.276 | 3.614 / 1.245 / 3.728 |
| volatile 기본값 ALTER | 27,135.545 | 27,989.225 | 20,440.788 | 12,117.905 | 11,316.601 |
| 그동안 SELECT | 26,744.793 | 27,490.256 | 19,882.221 | 11,652.330 | 10,936.495 |
| 락 큐잉: ALTER | 10,034.929 | 10,035.339 | 10,030.842 | 10,054.062 | 10,028.718 |
| 락 큐잉: 뒤에 선 SELECT | 9,163 / 8,142 / 7,170 | 9,664 / 8,672 / 7,656 | 9,126 / 8,157 / 7,139 | 9,002 / 7,982 / 6,991 | 9,014 / 7,982 / 6,999 |
| lock_timeout 뒤 SELECT | 1,531.157 | 1,513.764 | 1,345.108 | 1,431.138 | 1,196.543 |
| 백필 30청크(초) | 57.858 | 42.316 | 42.851 | 39.030 | 39.522 |
| VALIDATE CONSTRAINT | 518.247 | 416.170 | 397.784 | 463.351 | 402.312 |
| CHECK 있는 SET NOT NULL | 측정 안 함 | 측정 안 함 | 2.501 | 7.295 | 2.354 |
| CHECK 없는 SET NOT NULL(대조군) | 측정 안 함 | 측정 안 함 | 535.725 | 530.267 | 474.538 |

단위는 표시가 없으면 ms입니다.

보관한 로그는 마지막 회차 전문([results/full-run.txt](results/full-run.txt))과 2회차 발췌([results/other-runs-excerpt.txt](results/other-runs-excerpt.txt))입니다.
1회차부터 4회차까지의 전문은 같은 파일을 덮어쓰며 진행해 남기지 못했고, 위 표의 값은 그 회차 실행 화면에서 옮겨 적은 것입니다.

락 대기에서 나오는 수치(락 큐잉, `lock_timeout`)는 sleep으로 짠 타임라인이 결정하므로 다섯 실행이 거의 같습니다.
락 큐잉의 ALTER는 다섯 번 모두 10,028~10,054 ms 안에 들어옵니다.

디스크를 실제로 쓰는 수치는 흔들립니다. 3회차의 상수 기본값 ALTER가 496 ms까지 튄 것이 대표적입니다.
그 시각 서버 로그에는 시드가 만든 체크포인트가 아직 flush 중이라는 기록이 있었습니다. 이 서버에서는
`max_wal_size` 기본값으로 300만 행을 두 번 넣으면 체크포인트가 20초대 간격으로 몰리고,
마지막 회차 로그에도 같은 경고가 두 번 남아 있습니다.

```console
lab-b43-pg      | 2026-07-28 22:43:14.612 UTC [55] LOG:  checkpoints are occurring too frequently (24 seconds apart)
lab-b43-pg      | 2026-07-28 22:43:14.612 UTC [55] HINT:  Consider increasing the configuration parameter "max_wal_size".
```

밀리초짜리 DDL도 커밋할 때 WAL fsync를 기다리므로, 디스크가 바쁘면 문장 시간이 수백 ms로 부풀어 오릅니다.
3회차에서 롤백으로 끝난 ALTER(기본값 없는 NOT NULL)는 같은 구간에서 1.386 ms였습니다. 커밋 fsync가 없었기 때문입니다.
4회차부터 시드 끝에 `CHECKPOINT`를 넣어 이 잡음을 걷어냈습니다.

본문의 절대 시간은 이 환경(2 vCPU 공유 서버)의 값입니다. 비교해야 할 것은 같은 실행 안에서의 배율입니다.
