# A06 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| MySQL | 8.4.3, REPEATABLE READ(기본), `innodb_print_all_deadlocks=ON`, `innodb_lock_wait_timeout=10` |
| 재현 | Python 스레드 2개 + `threading.Barrier`로 두 세션의 진행을 맞춤 |
| 호스트 | 기록하지 않았습니다 (`uname -srm`, `nproc`, `free -g`를 찍어 두지 않음) |
| 컨테이너 자원 한도 | 걸지 않음 |
| 일시 | 2026-07-29 |

## 실행

```console
$ docker compose up -d
$ python3 scripts/deadlock.py results/deadlock.txt   # 두 시나리오 + 해소 검증, 약 40초
```

출력 전문은 `results/deadlock.txt`입니다.

## 1. 락이 걸린 순간 (data_locks)

두 세션이 `SELECT ... FOR UPDATE`를 마치고 `INSERT` 직전인 상태를 포착했습니다. 이 출력은 `time.sleep(0.15)` 뒤에 `data_locks`를 한 번 조회한 **단일 스냅숏**이고, 같은 상태를 여러 번 관측해 재현성을 확인하지는 않았습니다. 30회 반복은 아래 3절의 데드락 발생 횟수에만 해당합니다.

```console
$ SELECT ENGINE_TRANSACTION_ID, INDEX_NAME, LOCK_TYPE, LOCK_MODE, LOCK_STATUS, LOCK_DATA
    FROM performance_schema.data_locks WHERE OBJECT_SCHEMA='spoon';

  2658  uk_live_date  RECORD  X,GAP                   GRANTED  2, 1037565, 301
  2658  uk_live_date  RECORD  X,GAP,INSERT_INTENTION  WAITING  2, 1037565, 301
  2659  uk_live_date  RECORD  X,GAP                   GRANTED  2, 1037565, 301
```

갭 락 두 개가 동시에 GRANTED이고, 그 위의 insert intention이 WAITING입니다.

## 2. 데드락 그래프

```console
$ SHOW ENGINE INNODB STATUS\G
LATEST DETECTED DEADLOCK
------------------------
*** (1) TRANSACTION:
TRANSACTION 2228, ACTIVE 0 sec inserting
INSERT INTO settlement (live_id, settle_date, amount) VALUES (3,'2026-07-29',1000)
*** (1) HOLDS THE LOCK(S):
RECORD LOCKS space id 2 page no 5 n bits 72 index uk_live_date ... lock_mode X
Record lock, heap no 1 PHYSICAL RECORD: n_fields 1; compact format; info bits 0
 0: len 8; hex 73757072656d756d; asc supremum;;
...
*** WE ROLL BACK TRANSACTION (2)
```

`supremum` 레코드에 걸린 락이 갭 락의 표시입니다.

## 3. 해소 검증 (각 30회, 시도 60건)

```console
INSERT ... ON DUPLICATE KEY UPDATE       데드락 0회, 중복키 에러 0회
READ COMMITTED로 낮추기                   데드락 0회, 중복키 에러 30회
원래 방식 (SELECT FOR UPDATE 후 INSERT)   데드락 30회
```

## 4. 격리 수준 변경 시점 확인

```console
$ BEGIN;
$ SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
$ SELECT @@transaction_isolation;
READ-COMMITTED          <- 변수는 바뀌었지만 실행 중인 트랜잭션은 REPEATABLE READ로 돈다
```

`BEGIN` 앞으로 옮기기 전에는 해소 검증에서 데드락이 30회 그대로 나왔습니다.

## 원문 파일 위치

| 내용 | 경로 |
|---|---|
| 시나리오·락 상태·데드락 그래프·해소 검증 전문 | `results/deadlock.txt` |
| 증거 카드 | `results/fig-locks.png`, `results/fig-graph.png` |
