# 재현 기록

실행한 명령과 출력을 원문 그대로 남깁니다. 요약하지 않습니다.

## 환경

- 호스트: Rocky Linux 9 (aarch64, 2코어), Docker 29.4.2, Docker Compose v5.1.3
- 이미지: postgres:16-alpine
- 일시: 2026-07-28
- 실행: 세션 디렉터리에서 `bash scripts/run.sh` 하나로 아래 전부가 순서대로 돕니다. 아래 출력은 그 실행의 원문입니다.
- 콘솔 로그: [results/99-run-log.txt](results/99-run-log.txt)입니다. 아래 2절(컬럼 하나만 낮추기)과 10절(ANALYZE 소요 시간)은 본 순서를 다 돌린 뒤 같은 컨테이너, 같은 데이터에서 이어서 잰 것이라 이 로그에는 없습니다. 두 단계 모두 그 뒤 `scripts/run.sh`에 제자리로 넣었으므로, 지금 새로 돌리면 아래 순서 그대로 나옵니다.
- 무작위성: ANALYZE의 표본 추출은 시드를 고정할 수 없습니다. 그래서 스크립트가 원하는 상태(null_frac이 1인 회차, 1이 아닌 회차)가 나올 때까지 ANALYZE를 다시 돌리고 몇 회째였는지를 기록합니다. 실행마다 이 횟수는 달라집니다.

```console
$ docker compose up -d
 Network a09-planner-stats-flip_default Creating
 Network a09-planner-stats-flip_default Created
 Container lab-a09-pg Creating
 Container lab-a09-pg Created
 Container lab-a09-pg Starting
 Container lab-a09-pg Started
```

```console
$ psql -c "SELECT version();" -c "SHOW default_statistics_target;" -c "SHOW shared_buffers;" \
       -c "SHOW max_parallel_workers_per_gather;" -c "SHOW autovacuum;" -c "SHOW jit;"
                                            version
------------------------------------------------------------------------------------------------
 PostgreSQL 16.14 on aarch64-unknown-linux-musl, compiled by gcc (Alpine 15.2.0) 15.2.0, 64-bit
(1 row)

 default_statistics_target
---------------------------
 100
(1 row)

 shared_buffers
----------------
 512MB
(1 row)

 max_parallel_workers_per_gather
---------------------------------
 0
(1 row)

 autovacuum
------------
 off
(1 row)

 jit
-----
 off
(1 row)
```

## 1. 데이터 적재

[scripts/00-seed.sql](scripts/00-seed.sql)입니다. 전체 출력은 [results/00-seed.txt](results/00-seed.txt)에 있고 여기에는 끝의 확인 부분만 옮깁니다.

```console
$ psql -f /scripts/00-seed.sql
       relname        |  heap   | pages
----------------------+---------+-------
 ip_rule              | 130 MB  | 16649
 org_plan             | 8656 kB |  1082
 payout_txn_clustered | 127 MB  | 16217
 payout_txn_shuffled  | 127 MB  | 16217
 req_log              | 507 MB  | 64868
(5 rows)

Time: 10.043 ms
 total_rows | non_null |  nulls   | null_pct
------------+----------+----------+----------
   12000000 |     2400 | 11997600 |  99.9800
(1 row)

Time: 1234.460 ms (00:01.234)
```

## 2. 문제 컬럼 하나만 target 1로 낮춰 본다

먼저 `blocked_until` 하나만 낮추고 나머지는 기본값(-1, 즉 100)으로 둡니다.

```console
$ psql -c "ALTER TABLE req_log ALTER COLUMN id SET STATISTICS -1, ALTER COLUMN org_id SET STATISTICS -1,
           ALTER COLUMN status_code SET STATISTICS -1, ALTER COLUMN blocked_until SET STATISTICS 1;" \
       -c "ANALYZE req_log;"
ALTER TABLE
ANALYZE
    attname    | attstattarget
---------------+---------------
 id            |            -1
 org_id        |            -1
 status_code   |            -1
 blocked_until |             1
(4 rows)

    attname    | null_frac |   n_distinct
---------------+-----------+----------------
 blocked_until |    0.9998 | -0.00019997358
(1 row)

                                         QUERY PLAN
---------------------------------------------------------------------------------------------
 Index Scan using req_log_blocked_until_idx on req_log  (cost=0.43..70.44 rows=2400 width=8)
   Index Cond: (blocked_until IS NOT NULL)
(2 rows)
```

아무 일도 일어나지 않습니다. null_frac 0.9998, 추정 2,400행으로 정확합니다. 표본 크기는 컬럼별이 아니라 ANALYZE 한 번 단위로 정해지고, 남아 있는 기본값 100이 표본을 30,000행으로 유지하기 때문입니다. 그래서 아래부터는 네 컬럼을 함께 낮춥니다.

## 3. statistics target 1에서 ANALYZE

이 실행에서는 첫 ANALYZE가 곧바로 null_frac 1을 냈습니다.

```console
$ ALTER TABLE req_log ALTER COLUMN ... SET STATISTICS 1;   -- 샘플 300행
$ ANALYZE req_log;                                          -- 1회째에 아래 상태
    attname    | null_frac | n_distinct | hist
---------------+-----------+------------+------
 blocked_until |         1 |          0 |
 id            |         0 |         -1 |    2
 org_id        |         0 |         98 |    2
 status_code   |         0 |          1 |
(4 rows)

-- 실제 분포
  total   | non_null |     real_null_frac
----------+----------+------------------------
 12000000 |     2400 | 0.99980000000000000000
(1 row)

-- 플래너가 잡은 추정 행수
                                       QUERY PLAN
-----------------------------------------------------------------------------------------
 Index Scan using req_log_blocked_until_idx on req_log  (cost=0.43..8.45 rows=1 width=8)
   Index Cond: (blocked_until IS NOT NULL)
(2 rows)
```

`null_frac`이 1입니다. 300행 샘플이 NULL만 봤으므로 플래너는 이 컬럼에 값이 있는 행이 하나도 없다고 판단했습니다. `n_distinct`도 0, 히스토그램도 비었습니다. 실제 null_frac은 0.9998이고 non-null은 2,400행입니다.

## 4. 오추정 상태에서 조인 쿼리 계측

```console
$ EXPLAIN (ANALYZE, BUFFERS)
  SELECT count(*) FROM req_log r
    JOIN ip_rule i ON i.org_id = r.org_id AND i.rule_kind = 'burst'
   WHERE r.blocked_until IS NOT NULL;
                                                                     QUERY PLAN
----------------------------------------------------------------------------------------------------------------------------------------------------
 Aggregate  (cost=646.89..646.90 rows=1 width=8) (actual time=7734.102..7734.103 rows=1 loops=1)
   Buffers: shared hit=449402
   ->  Nested Loop  (cost=0.86..646.89 rows=1 width=0) (actual time=0.077..7733.237 rows=2400 loops=1)
         Buffers: shared hit=449402
         ->  Index Scan using req_log_blocked_until_idx on req_log r  (cost=0.43..8.45 rows=1 width=4) (actual time=0.053..1.509 rows=2400 loops=1)
               Index Cond: (blocked_until IS NOT NULL)
               Buffers: shared hit=26
         ->  Index Scan using ip_rule_org_id_idx on ip_rule i  (cost=0.43..638.43 rows=1 width=4) (actual time=0.007..3.218 rows=1 loops=2400)
               Index Cond: (org_id = r.org_id)
               Filter: (rule_kind = 'burst'::text)
               Rows Removed by Filter: 19999
               Buffers: shared hit=449376
 Planning:
   Buffers: shared hit=202
 Planning Time: 1.474 ms
 Execution Time: 7734.195 ms
(16 rows)
```

5회 실행 시간(ms)입니다. 중앙값은 7734.195입니다.

```
1 7609.396
2 7735.290
3 8253.634
4 7734.195
5 7434.809
```

## 5. 같은 target 1에서 표본이 non-null을 잡은 회차

같은 설정으로 ANALYZE만 다시 돌립니다. 62회째에 샘플이 non-null 한 행을 잡았습니다.

```console
$ ANALYZE req_log;   -- 같은 statistics target 1, 샘플이 non-null을 잡은 회차 (62회째)
    attname    | null_frac  |  n_distinct
---------------+------------+---------------
 blocked_until | 0.99666667 | -0.0033333302
(1 row)

                                          QUERY PLAN
----------------------------------------------------------------------------------------------
 Bitmap Heap Scan on req_log  (cost=446.30..60162.91 rows=39982 width=8)
   Recheck Cond: (blocked_until IS NOT NULL)
   ->  Bitmap Index Scan on req_log_blocked_until_idx  (cost=0.00..436.30 rows=39982 width=0)
         Index Cond: (blocked_until IS NOT NULL)
(4 rows)
```

같은 쿼리를 같은 방식으로 5회 잰 중앙값 회차의 플랜입니다.

```console
$ EXPLAIN (ANALYZE, BUFFERS) ...같은 쿼리...
                                                                      QUERY PLAN
-------------------------------------------------------------------------------------------------------------------------------------------------------
 Aggregate  (cost=101857.00..101857.01 rows=1 width=8) (actual time=356.040..356.041 rows=1 loops=1)
   Buffers: shared hit=18750
   ->  Nested Loop  (cost=446.73..101790.03 rows=26788 width=0) (actual time=0.133..355.846 rows=2400 loops=1)
         Buffers: shared hit=18750
         ->  Bitmap Heap Scan on req_log r  (cost=446.30..60162.91 rows=39982 width=4) (actual time=0.105..0.415 rows=2400 loops=1)
               Recheck Cond: (blocked_until IS NOT NULL)
               Heap Blocks: exact=17
               Buffers: shared hit=26
               ->  Bitmap Index Scan on req_log_blocked_until_idx  (cost=0.00..436.30 rows=39982 width=0) (actual time=0.094..0.094 rows=2400 loops=1)
                     Index Cond: (blocked_until IS NOT NULL)
                     Buffers: shared hit=9
         ->  Memoize  (cost=0.44..402.27 rows=1 width=4) (actual time=0.001..0.148 rows=1 loops=2400)
               Cache Key: r.org_id
               Cache Mode: logical
               Hits: 2300  Misses: 100  Evictions: 0  Overflows: 0  Memory Usage: 11kB
               Buffers: shared hit=18724
               ->  Index Scan using ip_rule_org_id_idx on ip_rule i  (cost=0.43..402.26 rows=1 width=4) (actual time=0.010..3.539 rows=1 loops=100)
                     Index Cond: (org_id = r.org_id)
                     Filter: (rule_kind = 'burst'::text)
                     Rows Removed by Filter: 19999
                     Buffers: shared hit=18724
 Planning:
   Buffers: shared hit=202
 Planning Time: 1.265 ms
 Execution Time: 356.168 ms
(25 rows)
```

```
1 415.852
2 342.263
3 356.168
4 358.332
5 355.674
```

## 6. statistics target 1000으로 올리고 재계측

```console
$ ALTER TABLE req_log ALTER COLUMN ... SET STATISTICS 1000;   -- 샘플 300,000행
$ ANALYZE req_log;
    attname    | null_frac  |   n_distinct   | hist
---------------+------------+----------------+------
 blocked_until | 0.99982333 | -0.00017666817 |   53
 id            |          0 |             -1 | 1001
 org_id        |          0 |            100 |
 status_code   |          0 |              2 |
(4 rows)

-- 플래너가 잡은 추정 행수
                                         QUERY PLAN
---------------------------------------------------------------------------------------------
 Index Scan using req_log_blocked_until_idx on req_log  (cost=0.43..60.53 rows=2120 width=8)
   Index Cond: (blocked_until IS NOT NULL)
(2 rows)
```

```console
$ EXPLAIN (ANALYZE, BUFFERS) ...같은 쿼리...
                                                                          QUERY PLAN
--------------------------------------------------------------------------------------------------------------------------------------------------------------
 Aggregate  (cost=41931.50..41931.51 rows=1 width=8) (actual time=163.975..163.978 rows=1 loops=1)
   Buffers: shared hit=16675
   ->  Hash Join  (cost=87.03..41927.95 rows=1420 width=0) (actual time=0.964..163.772 rows=2400 loops=1)
         Hash Cond: (i.org_id = r.org_id)
         Buffers: shared hit=16675
         ->  Seq Scan on ip_rule i  (cost=0.00..41649.00 rows=67 width=4) (actual time=0.034..162.344 rows=100 loops=1)
               Filter: (rule_kind = 'burst'::text)
               Rows Removed by Filter: 1999900
               Buffers: shared hit=16649
         ->  Hash  (cost=60.53..60.53 rows=2120 width=4) (actual time=0.900..0.901 rows=2400 loops=1)
               Buckets: 4096  Batches: 1  Memory Usage: 117kB
               Buffers: shared hit=26
               ->  Index Scan using req_log_blocked_until_idx on req_log r  (cost=0.43..60.53 rows=2120 width=4) (actual time=0.027..0.529 rows=2400 loops=1)
                     Index Cond: (blocked_until IS NOT NULL)
                     Buffers: shared hit=26
 Planning:
   Buffers: shared hit=195
 Planning Time: 1.460 ms
 Execution Time: 164.090 ms
(19 rows)
```

```
1 162.852
2 174.258
3 168.461
4 164.090
5 162.615
```

## 7. 대조군: 같은 오추정, 안쪽이 싼 표

`org_plan`은 org_id 하나에 1행뿐이고 인덱스가 있습니다. null_frac이 다시 1인 상태에서 잰 값입니다.

```console
$ EXPLAIN (ANALYZE, BUFFERS)
  SELECT count(*), max(p.rpm_limit) FROM req_log r
    JOIN org_plan p ON p.org_id = r.org_id
   WHERE r.blocked_until IS NOT NULL;
                                                                        QUERY PLAN
----------------------------------------------------------------------------------------------------------------------------------------------------------
 Aggregate  (cost=12.44..12.45 rows=1 width=12) (actual time=1.389..1.390 rows=1 loops=1)
   Buffers: shared hit=30
   ->  Merge Join  (cost=8.88..12.43 rows=1 width=4) (actual time=0.786..1.215 rows=2400 loops=1)
         Merge Cond: (p.org_id = r.org_id)
         Buffers: shared hit=30
         ->  Index Scan using org_plan_org_id_idx on org_plan p  (cost=0.42..6289.42 rows=200000 width=8) (actual time=0.009..0.028 rows=101 loops=1)
               Buffers: shared hit=4
         ->  Sort  (cost=8.46..8.47 rows=1 width=4) (actual time=0.766..0.886 rows=2400 loops=1)
               Sort Key: r.org_id
               Sort Method: quicksort  Memory: 97kB
               Buffers: shared hit=26
               ->  Index Scan using req_log_blocked_until_idx on req_log r  (cost=0.43..8.45 rows=1 width=4) (actual time=0.025..0.475 rows=2400 loops=1)
                     Index Cond: (blocked_until IS NOT NULL)
                     Buffers: shared hit=26
 Planning:
   Buffers: shared hit=202
 Planning Time: 1.573 ms
 Execution Time: 1.506 ms
(18 rows)
```

오추정 5회 `1.735 1.487 1.506 1.457 1.716`, 해소 5회 `1.471 1.489 1.558 1.604 1.498`. 중앙값은 1.506 ms와 1.498 ms입니다.

## 8. 표본 사다리

target을 바꿔 가며 ANALYZE를 반복하고, 매회 `null_frac`과 `WHERE blocked_until IS NOT NULL`의 추정 행수를 적었습니다. 원본은 [results/40-sampling.csv](results/40-sampling.csv)입니다.

```console
$ cat results/41-sampling-summary.txt
target=1 sample=300행 null_frac=1 이 40회 중 39회
target=10 sample=3000행 null_frac=1 이 40회 중 20회
target=100 sample=30000행 null_frac=1 이 10회 중 1회
target=1000 sample=300000행 null_frac=1 이 5회 중 0회
```

```console
$ cat results/42-sampling-table.txt
target   sample     runs   nf=1       est_min   est_max   est_avg
1        300        40     39/40      1         39982     1001
10       3000       40     20/40      1         23998     3800
100      30000      10     1/10       1         6400      2800
1000     300000     5      0/5        1880      2640      2232
```

실제 행수는 2,400입니다.

## 9. GoCardless 쪽: 물리적 행 순서만 다른 두 표

전체 출력은 [results/50-ndistinct.txt](results/50-ndistinct.txt)에 있습니다.

```console
-- 두 표의 행 내용은 같다. payout_id 하나에 20행씩, 실제 distinct = 150,000.
-- clustered는 payout_id 순으로, shuffled는 흩어서 넣었다.

-- statistics target = 1 (샘플 300행)
      tablename       | n_distinct | correlation
----------------------+------------+-------------
 payout_txn_clustered |       3308 |      1.0000
 payout_txn_shuffled  |      44192 |      0.0724
(2 rows)

                                QUERY PLAN
---------------------------------------------------------------------------
 Seq Scan on payout_txn_clustered  (cost=0.00..53718.81 rows=907 width=16)
   Filter: (payout_id = 777)
(2 rows)

                               QUERY PLAN
-------------------------------------------------------------------------
 Seq Scan on payout_txn_shuffled  (cost=0.00..53718.81 rows=68 width=16)
   Filter: (payout_id = 777)
(2 rows)


-- statistics target = 10 (샘플 3000행)
      tablename       | n_distinct | correlation
----------------------+------------+-------------
 payout_txn_clustered |      28394 |      1.0000
 payout_txn_shuffled  |     182437 |      0.0780
(2 rows)

                                QUERY PLAN
---------------------------------------------------------------------------
 Seq Scan on payout_txn_clustered  (cost=0.00..53718.81 rows=106 width=16)
   Filter: (payout_id = 777)
(2 rows)

                               QUERY PLAN
-------------------------------------------------------------------------
 Seq Scan on payout_txn_shuffled  (cost=0.00..53718.81 rows=16 width=16)
   Filter: (payout_id = 777)
(2 rows)


-- statistics target = 100 (샘플 30000행)
      tablename       | n_distinct | correlation
----------------------+------------+-------------
 payout_txn_clustered |     149375 |      1.0000
 payout_txn_shuffled  |     148339 |      0.0476
(2 rows)

                                QUERY PLAN
--------------------------------------------------------------------------
 Seq Scan on payout_txn_clustered  (cost=0.00..53717.00 rows=20 width=16)
   Filter: (payout_id = 777)
(2 rows)

                               QUERY PLAN
-------------------------------------------------------------------------
 Seq Scan on payout_txn_shuffled  (cost=0.00..53717.00 rows=20 width=16)
   Filter: (payout_id = 777)
(2 rows)

-- 실제 매칭 행수
 clustered | shuffled
-----------+----------
        20 |       20
(1 row)
```

## 10. 해소의 값: target별 ANALYZE 소요 시간

```console
$ cat results/60-analyze-cost.txt
-- ANALYZE 소요 시간 (req_log 12,000,000행 / 507MB, psql \timing, target별 3회)
target=1 (샘플 300행)
Time: 12.892 ms
Time: 4.235 ms
Time: 4.252 ms
  pg_statistic 총 크기 = 504 kB, blocked_until 히스토그램 = 없음, null_frac = 1
target=100 (샘플 30000행)
Time: 285.955 ms
Time: 272.199 ms
Time: 294.761 ms
  pg_statistic 총 크기 = 512 kB, blocked_until 히스토그램 = 4, null_frac = 0.99986666
target=1000 (샘플 300000행)
Time: 1072.964 ms (00:01.073)
Time: 1212.967 ms (00:01.213)
Time: 1170.064 ms (00:01.170)
  pg_statistic 총 크기 = 520 kB, blocked_until 히스토그램 = 55, null_frac = 0.99981666
target=10000 (샘플 3000000행)
Time: 6562.940 ms (00:06.563)
Time: 6368.828 ms (00:06.369)
Time: 6269.833 ms (00:06.270)
  pg_statistic 총 크기 = 664 kB, blocked_until 히스토그램 = 605, null_frac = 0.99979836
```

`pg_statistic`은 데이터베이스 공유 카탈로그라 한 번 커지면 줄지 않습니다. 위 네 줄의 차이를 target별 증분으로 읽으면 안 되고, target 10000에서도 664kB라는 상한만 읽어야 합니다.

## 11. 정리

```console
$ docker compose down -v
 Container lab-a09-pg Stopping
 Container lab-a09-pg Stopped
 Container lab-a09-pg Removing
 Container lab-a09-pg Removed
 Network a09-planner-stats-flip_default Removing
 Network a09-planner-stats-flip_default Removed
```

## 측정값 요약

req_log 12,000,000행, non-null 2,400행(99.98% NULL), PostgreSQL 16.14, `EXPLAIN (ANALYZE, BUFFERS)` 5회 중앙값입니다.

| 통계 상태 | null_frac | 추정 행수 | 실제 행수 | 조인 방식 | shared hit | 중앙값 |
|---|---|---|---|---|---|---|
| target 1, 샘플이 전부 NULL | 1 | 1 | 2,400 | Nested Loop | 449,402 | 7,734.195 ms |
| target 1, 샘플이 non-null 1행 | 0.99666667 | 39,982 | 2,400 | Nested Loop + Memoize | 18,750 | 356.168 ms |
| target 1000 | 0.99982333 | 2,120 | 2,400 | Hash Join | 16,675 | 164.090 ms |

대조군(`org_plan` 조인)은 같은 오추정에서 1.506 ms, 해소 뒤 1.498 ms로 차이가 없었습니다.
