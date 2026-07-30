# A19 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| 호스트 | Darwin 25.3.0 arm64, 12코어, 32GB |
| PostgreSQL | 17.5 공식 Docker 이미지 (Debian 17.5-1.pgdg130+1) |
| 구성 | 프라이머리 + 스트리밍 복제 핫 스탠바이(비동기), 같은 호스트의 두 컨테이너 |
| 컨테이너 한도 | 각 `cpus: 4`, `mem_limit: 4g` |
| 서버 설정 | `shared_buffers=1GB`, `autovacuum=off`, `wal_level=replica`, `max_connections=300`(양쪽) |
| `subtransaction_buffers` | 조건에 따라 32블록(256kB) 또는 512블록(4MB). 기본값 0(자동)은 이 `shared_buffers`에서 256블록이 된다 |
| 데이터 | `sponsor` 50만 행 |
| 부하 생성기 | pgbench 17.5, `-M prepared` |
| 일시 | 2026-07-29 (1회차), 2026-07-30 (2~4회차) |
| 반복 | 4회. `tools/repeat-runs.sh`로 3회 추가. 회차별 원문은 `results/run0-*`~`run3-*` |
| 호스트 기록 | `results/host.txt`, 회차별 `results/host-run*.txt` |

같은 호스트에서 두 인스턴스가 각 4코어를 쓰므로 12코어를 나눠 씁니다. 조건 간 상대 비교만 유효하고 다른 세션의 절대 TPS와 비교하면 안 됩니다.

## 실행

```console
$ docker compose up -d                    # 스탠바이가 베이스백업을 뜨므로 30초 정도 걸린다
$ docker exec -i a19-primary psql -U postgres -d spoon -q < schema.sql
$ ./scripts/run-primary.sh sub500k 500000 64 20    # 프라이머리 단일 조건
$ ./scripts/run-standby.sh sb-sp3 writer-sp-write yes
```

프라이머리 매트릭스 전체는 `results/primary-matrix.log`, 스탠바이는 `results/standby-matrix.log`에 있습니다.

## 0. 버전 사실 확인

```console
spoon=# SHOW server_version;
 17.5 (Debian 17.5-1.pgdg130+1)

spoon=# SHOW subtransaction_buffers;   -- 32블록을 준 결과
 256kB

spoon=# SELECT name FROM pg_stat_slru;
 commit_timestamp / multixact_member / multixact_offset / notify
 serializable / subtransaction / transaction / other
```

17에서 `pg_stat_slru`의 name이 `Subtrans`에서 `subtransaction`으로 바뀐 것을 확인했습니다. GUC 단위는 8kB 블록 수라 32를 주면 256kB로 보고됩니다.

## 1. 프라이머리 매트릭스 (results/primary-matrix.log)

동시 리더 64, 20초. 긴 트랜잭션이 50만 행 전량을 갱신하고 그 범위를 리더가 읽습니다.

4회 집계입니다(`scripts/report.py` 출력).

```console
none         n=4 서브TX=      0 버퍼=256kB tps중앙=  94,741 (94,017~101,383) 기준선대비 100~100% 미스율  0.0~ 0.0% SubtransSLRU   0~  0%
sub64        n=4 서브TX=     64 버퍼=256kB tps중앙=  91,936 (90,774~ 98,383) 기준선대비  97~ 97% 미스율  0.0~ 0.0% SubtransSLRU   0~  0%
sub10k       n=4 서브TX= 10,000 버퍼=256kB tps중앙=  88,242 (87,779~ 95,112) 기준선대비  93~ 94% 미스율  0.0~ 0.0% SubtransSLRU   0~  0%
sub500k      n=4 서브TX=500,000 버퍼=256kB tps중앙=  66,026 (63,431~ 70,049) 기준선대비  67~ 71% 미스율 22.2~22.4% SubtransSLRU  44~ 57%
sub500k-buf  n=4 서브TX=500,000 버퍼=4MB   tps중앙=  89,470 (89,036~ 97,146) 기준선대비  94~ 96% 미스율  0.0~ 0.0% SubtransSLRU   0~  0%
```

미스율은 `sub500k`에서 네 회차 모두 22.2~22.4%입니다. 버퍼를 4MB로 올린 조건에서는
조회 700만 건이 전부 적중하고 미스가 네 회차 모두 0입니다.

절대 처리량은 회차 간 1.08배 안쪽으로 흔들리고 run0이 모든 조건에서 7% 정도 높습니다.
가장 조용한 상태에서 측정했기 때문입니다. 그래서 기준선 대비를 회차마다 따로 계산했습니다.
중앙값끼리 나누면 서로 다른 회차가 섞입니다.

## 2. XID 카운터를 밀지 않으면 아무 일도 안 일어난다

이 세션에서 가장 오래 막혔던 지점입니다. 긴 트랜잭션과 서브트랜잭션 20만 개를 만들고도 `pg_subtrans` 조회가 계속 0이었습니다.

```console
-- 긴 트랜잭션만 있고 다른 쓰기가 없을 때, 다른 세션에서
spoon=# SELECT pg_current_snapshot();
 2218:2218:                       ← xmin = xmax, 진행 중 목록 비어 있음

spoon=# SELECT id, xmin, xmax FROM sponsor WHERE id IN (5, 50000, 99999);
  id   | xmin | xmax
-------+------+------
     5 |  847 | 2219
 50000 |  847 | 2318
 99999 |  847 | 2418
```

서브트랜잭션 XID가 2219부터인데 스냅샷의 xmax가 2218입니다. `XidInMVCCSnapshot`은 xid가 xmax 이상이면 즉시 "진행 중"으로 판정하고 끝내므로 `pg_subtrans`를 보지 않습니다.

`SELECT txid_current()`를 pgbench로 반복해 카운터를 서브트랜잭션 범위 너머로 밀자 조회가 나타났습니다.

```console
  XID 밀기: 최상위=1451295 목표=1952295 현재=2075212
sub10k   SLRU(hit read)=5821214 6        ← 조회 발생, 전부 적중
```

`scripts/run-primary.sh`가 이 단계를 별도로 수행합니다.

## 3. 64 경계 확인

```console
sub64    서브TX=64     SLRU(hit read)=0 0
sub10k   서브TX=10000  SLRU(hit read)=7615598 6
```

64개에서는 조회가 정확히 0입니다. `PGPROC_MAX_CACHED_SUBXIDS = 64`를 넘지 않으므로 PGPROC 배열만 보고 판정이 끝납니다.

## 4. 스탠바이 매트릭스 (results/standby-matrix.log)

```console
sb-sp3         쓰기=writer-sp-write  롱TX=yes tps=60768.587802 SLRU(hit read)=0 0 ASSIGNMENT=0 스냅샷=6580420:6829068: 지연=0s
sb-plain3      쓰기=writer-plain3    롱TX=yes tps=51931.198155 SLRU(hit read)=0 0 ASSIGNMENT=0 스냅샷=6958204:7220354: 지연=0s
sb-sp70        쓰기=writer-sp70      롱TX=yes tps=72983.028978 SLRU(hit read)=0 0 ASSIGNMENT=0 스냅샷=7267299:7287232: 지연=1s
sb-sp70-nolong 쓰기=writer-sp70      롱TX=no  tps=76224.763955 SLRU(hit read)=0 0 ASSIGNMENT=0 스냅샷=7288681:7289043: 지연=0s
```

스탠바이의 `subtransaction`이 전 조건 0입니다. 통계 수집이 죽지 않았다는 근거로 같은 시점 `transaction` 행을 함께 읽었습니다.

```console
      name      | blks_hit | blks_read
----------------+----------+-----------
 subtransaction |        0 |         0
 transaction    |    20784 |         0
```

## 5. ASSIGNMENT 레코드가 나오는 조건

스탠바이가 오버플로를 통보받는 유일한 경로입니다. `pg_waldump`로 직접 셌습니다.

```console
-- 한 트랜잭션에 쓰기 서브트랜잭션 10만 개
=== 이 구간 ASSIGNMENT 레코드 ===
1562 ASSIGNMENT

-- SAVEPOINT 3개짜리 트랜잭션 1.7만 건
16954 COMMIT          ← ASSIGNMENT 0건

-- 쓰기 서브트랜잭션 70개짜리 트랜잭션 7건
   7 COMMIT
   1 ABORT            ← ASSIGNMENT 0건
```

100,000 ÷ 64 = 1,562.5입니다. 한 트랜잭션 안에서 서브트랜잭션 64개마다 한 번 기록됩니다.

## 6. sb-sp70 조건의 결함

이 조건은 ASSIGNMENT 레코드가 나올 수 있는 유일한 조건이었는데 쓰기 처리량이 없었습니다.

```console
number of transactions actually processed: 7
number of failed transactions: 0 (0.000%)
latency average = 5895.706 ms
tps = 0.678460 (without initial connection time)
```

4개 클라이언트가 한 트랜잭션에서 70개 행 락을 잡아 서로 막고 데드락까지 났습니다(WAL의 ABORT 1건). GitLab이 요구한 "동시에 많은 쓰기"를 만들지 못했으므로, 이 조건의 음성 결과는 반박 근거가 되지 못합니다.

## 밟은 함정

0. **대기 샘플 파일을 초기화하지 않음.** `run-primary.sh`가 `>>`로 이어 붙이기만 해서
   반복 측정에서 회차마다 누적됐습니다(235 → 464 → 686 → 920). 회차별 비중은 차분해서
   얻었고 스크립트는 고쳤습니다. 회차가 늘수록 뒤 회차가 앞 회차에 희석되는 형태라
   그대로 두면 편차가 실제보다 작게 보입니다.

1. **XID 카운터를 밀지 않음.** 2절. 이 세션의 핵심 함정입니다. 조건을 다 갖췄다고 믿고 여러 번 재는 동안 계속 0이 나왔습니다.
2. **쓰지 않는 SAVEPOINT.** 처음 writer 스크립트는 `savepoint s1; savepoint s2; savepoint s3;`를 연달아 두고 마지막에 UPDATE 하나를 뒀습니다. 쓰지 않는 서브트랜잭션은 XID를 받지 않으므로 서브트랜잭션이 1개만 생깁니다. `scripts/writer-sp-write.sql`처럼 SAVEPOINT마다 쓰기를 넣어야 합니다.
3. **시퀀스 테이블 행 삭제.** 초기 설계에서 Hibernate식 시퀀스를 쓰다 `DELETE FROM ..._seq`로 행을 지웠더니 이후 INSERT가 에러 없이 조용히 실패했습니다.
4. **스탠바이 `max_connections`.** 프라이머리보다 작으면 `recovery aborted because of insufficient parameter settings`로 아예 뜨지 않습니다.
5. **`pg_waldump` stderr 무시.** 처음에 `2>/dev/null`로 에러를 버려 놓고 결과 0을 사실로 착각했습니다. 범위를 LSN으로 명시하고 stderr를 살려서 다시 셌습니다.
6. **한 번 나온 6,660 TPS.** 초기 시도에서 스탠바이 TPS가 6,660으로 찍혀 절벽을 잡았다고 생각했는데, 통제된 조건으로 반복하니 6만대로 돌아왔고 `subtransaction` 카운터는 그때도 0이었습니다. 복제 지연 회복 중이었을 가능성이 큽니다. 재현되지 않은 단발 관측이라 결론에서 제외했습니다.
