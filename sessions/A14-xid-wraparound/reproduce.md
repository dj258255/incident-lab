# A14 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| 호스트 | Darwin 25.3.0 arm64, 12코어, 32GB |
| PostgreSQL | 17.5 공식 Docker 이미지 (`server_version_num` 170005) |
| 컨테이너 한도 | `cpus: 4`, `mem_limit: 2g` |
| 서버 설정 | `shared_buffers=512MB`, `autovacuum=on`, `autovacuum_freeze_max_age=200000000`(기본), `vacuum_failsafe_age=1600000000`(기본), `max_prepared_transactions=10` |
| 데이터 | `sponsor` 5만 행 |
| 데이터 위치 | 이름 있는 볼륨 `a14data`. `pg_resetwal`을 별도 컨테이너에서 돌려야 하므로 필요하다 |
| 일시 | 2026-07-30 |
| 반복 | 4회. `tools/repeat-runs.sh`로 3회 추가. 회차별 원문은 `results/run0-timeline.txt`~`run3-timeline.txt` |
| 호스트 기록 | `results/host.txt`, 회차별 `results/host-run*.txt` |
| `autovacuum_naptime` | 기본값 60초. 자가 복구 시각이 여기에 좌우됩니다 |

이 세션은 지연이나 처리량을 재지 않습니다. 문구와 임계값과 상태 전이만 봅니다. 그래서 호스트 사양이 결론에 영향을 주지 않습니다.

## 실행

```console
$ docker compose up -d
# pg_isready만으로는 부족하다. 초기화 중 임시 서버에도 참을 돌려주므로 대상 DB 존재를 확인한다.
$ until docker exec a14-pg psql -U postgres -d spoon -qAt -c "SELECT 1" 2>/dev/null | grep -q 1; do sleep 2; done
$ docker exec -i a14-pg psql -U postgres -d spoon -q < schema.sql
$ ./scripts/run.sh        # 약 6분
```

전체 타임라인은 `results/timeline.txt`, XID 소비 곡선은 `results/burn.csv`에 있습니다.

## 임계값 계산

```
oldestXid=744  경고임계=2107484392  정지임계=2144484392  랩임계=2147484392
```

`oldestXid + 2^31`이 랩 지점이고, 정지는 거기서 300만 앞, 경고는 4,000만 앞입니다(PG14 이상).

## 1. autovacuum=off로도 wraparound 방지 vacuum은 돈다

설계를 엎게 만든 관측입니다. `autovacuum=off`로 두고 XID를 20억으로 점프시킨 직후입니다.

```console
  datname  | age | remaining  |  pct
-----------+-----+------------+-------
 postgres  |  12 | 2147483636 | 0.000
 spoon     |  12 | 2147483636 | 0.000

spoon=# SELECT datname, datfrozenxid FROM pg_database;
  datname  | datfrozenxid
-----------+--------------
 spoon     |   2000000000     ← 점프 직후 긴급 autovacuum이 전부 동결했다
```

`age`가 20억이 아니라 12입니다. `pg_resetwal`이 `oldestXid`를 `nextXid - 20억`으로 옮겨 놓자 그 값이 `autovacuum_freeze_max_age`(2억)를 즉시 넘겨, `autovacuum=off`인데도 wraparound 방지 autovacuum이 발동해 전부 동결했습니다.

## 2. pg_resetwal은 -u 없이는 정지 임계에 닿지 못한다

`-x 2000000000`만 준 결과입니다.

```console
$ pg_controldata | grep -iE "NextXID|oldestXID:"
Latest checkpoint's NextXID:          0:2000000000
Latest checkpoint's oldestXID:        731
```

여기서 `oldestXid`가 731로 남아 있어야 정지 임계가 낮게 계산되는데, `-x`만 주면 `pg_resetwal`이 `oldestXid`를 `nextXid - 20억`으로 강제합니다. 그 간격 20억은 정지 임계 조건(2^31 - 300만 = 21.44억)에 못 미치므로 아무리 점프해도 멈추지 않습니다. `-u`로 명시해야 합니다.

## 3. clog 세그먼트가 없으면 기동하지 못한다

```console
FATAL:  could not access status of transaction 2000000000
DETAIL:  Could not open file "pg_xact/0773": No such file or directory.
LOG:  startup process (PID 29) exited with exit code 1
```

2,000,000,000 ÷ 1,048,576 = 1907 = 0x773입니다. 256KB를 0으로 채워 만들면 뜹니다.

```console
-rw-r--r-- 1 postgres postgres 262144 Jul 30 01:43 0773
```

## 4. 정지 임계를 넘긴 디렉터리로는 재시작이 안 된다

`-x 2145000000 -u 731`(정지임계 2,144,484,379 초과)로 점프한 뒤입니다.

```console
WARNING:  database with OID 0 must be vacuumed within 2484378 transactions
HINT:  To avoid XID assignment failures, execute a database-wide VACUUM in that database.
	You might also need to commit or roll back old prepared transactions, or drop stale replication slots.
(이후 로그 없음. 접속하면 계속 FATAL: the database system is starting up)
```

경고까지 찍고 기동이 끝나지 않습니다. 그래서 점프를 두 번으로 나눠 각각 임계 직전에 착지하고 나머지는 태워서 넘었습니다.

## 5. 경고 지점 (results/timeline.txt)

```console
[3] 경고 임계 직전으로 점프한 뒤 태워서 경고를 넘는다
  점프 직후 nextXid=2107184392  (경고까지 300000개)
  경고 구간 진입: nextXid=2107561897
  서버가 남긴 문구:
    WARNING:  database with OID 0 must be vacuumed within 40000000 transactions
    HINT:  To avoid XID assignment failures, execute a database-wide VACUUM in that database.
    	You might also need to commit or roll back old prepared transactions, or drop stale replication slots.
```

정확히 40,000,000입니다.

## 6. 정지 지점

```console
[4] 정지 임계 직전으로 점프한 뒤 태워서 정지를 넘는다
  점프 직후 nextXid=2144084392  (정지까지 400000개)
  쓰기 거부: nextXid=2144484392  (정지임계 2144484392 를 0개 넘음)
  클라이언트가 받은 문구:
    ERROR:  database is not accepting commands that assign new transaction IDs to avoid wraparound data loss in database with OID 0
    HINT:  Execute a database-wide VACUUM in that database.
    You might also need to commit or roll back old prepared transactions, or drop stale replication slots.
```

정지임계와 정확히 같은 XID에서 거부가 시작됐습니다. HINT에 단일 사용자 모드 언급이 없습니다.

## 7. 정지 상태의 동작

```console
[5] 정지 상태에서 되는 것과 안 되는 것
  SELECT      : 50005 행
  INSERT      : ERROR:  database is not accepting commands that assign new transaction IDs to avoid ...
  DELETE      : ERROR:  database is not accepting commands that assign new transaction IDs to avoid ...
  읽기전용 TX : 50005 행
  VACUUM      : WARNING:  cutoff for removing and freezing tuples is far in the past
```

`txid_current()`도 거부됩니다. XID를 할당하는 함수이기 때문입니다. 그래서 이 스크립트는 관측에 `pg_snapshot_xmax(pg_current_snapshot())`을 씁니다.

## 8. 원인을 두고 VACUUM해도 소용없다

```console
[6] 원인을 그대로 두고 전체 VACUUM FREEZE
  age=2144483646   내려가지 않는다
  공식 문서가 지목하는 세 용의자:
    prepared xacts: 1 건  xid=746 age=2144483646
    장기 트랜잭션 : 1 건
    복제 슬롯     : 0 건
```

## 9. 원인 제거 후에도 다른 데이터베이스가 붙잡는다

```console
[7] 원인을 제거하고 다시
  spoon만 동결한 뒤 age=0
  그런데 쓰기는: ERROR: ... in database "postgres"
  임계를 붙잡고 있는 것은 다른 데이터베이스다:
    postgres age=2144483648
    template1 age=2144483648
    template0 age=2144483648
    spoon age=0
```

## 10. 손대지 않으면 스스로 복구된다

```console
[8] 손대지 않고 기다린다
  +20초: template0=2144483648 postgres=0 spoon=0 template1=0
  +40초: postgres=0 spoon=0 template1=0 template0=0
  쓰기 재개됨

  autovacuum이 남긴 failsafe 기록:
    WARNING:  bypassing nonessential maintenance of table "spoon.public.sponsor" as a failsafe after 0 index scans
    WARNING:  bypassing nonessential maintenance of table "spoon.pg_catalog.pg_statistic" as a failsafe after 0 index scans
  최종: postgres=1 spoon=1 template1=1 template0=1
  쓰기: ok
```

접속이 막힌 `template0`까지 긴급 autovacuum이 처리했습니다. `vacuum_failsafe_age`(PG14, 기본 16억) 발동 기록이 함께 남았습니다.

## 반복 측정

임계값은 상수에서 계산되어 편차가 없습니다. 4회 모두 정지 임계 2,144,484,392,
복구 시각 +40초, 쓰기 재개 성공이었습니다. run3만 거부 XID가 임계를 3개 넘었고
(2,144,484,395) 이는 XID 태우는 루프가 2초 단위라 마지막 구간에서 조금 넘긴 것입니다.

`+40초`는 20초 간격 샘플링의 결과이므로 실제 복구 완료는 20초와 40초 사이입니다.
`autovacuum_naptime` 기본값이 60초라 원인을 제거한 시점이 주기의 어디였는지에 따라
값이 흔들릴 수 있는데, 4회에서는 흔들리지 않았습니다.

## 밟은 함정

1. **`autovacuum=off`를 사고 조건으로 착각.** 1절. 설계를 한 번 엎었습니다.
2. **`pg_resetwal -x` 단독 사용.** 2절. `-u`가 없으면 절대 멈추지 않습니다.
3. **clog 세그먼트 누락.** 3절.
4. **정지 임계 초과 상태로 재시작.** 4절.
5. **`pg_isready`로 초기화 완료 판단.** 초기화 중 임시 서버에도 참을 돌려줍니다. `spoon` DB가 없는 상태로 시드를 넣어 전체 실행을 한 번 버렸습니다. 대상 DB에 `SELECT 1`이 통하는지로 판단해야 합니다.
6. **관측 함수가 상태를 바꿈.** `txid_current()`가 정지 상태에서 실패해 스크립트 파싱이 깨졌습니다. `pg_current_snapshot()`으로 교체했습니다.
7. **경고 공식을 PG13 기준으로 계산.** 처음에 `경고 = 정지 - 1000만`으로 뒀습니다. PG14부터는 `랩 - 4000만`입니다. 조사로 잡아 고쳤습니다.
