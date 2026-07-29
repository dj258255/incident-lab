# A06 갭 락 데드락, "없으면 넣는다"가 만드는 교착

> 근거 등급: `E2`
> 출처: [MySQL 8.4, InnoDB Locking (gap locks, insert intention locks)](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking.html) · [Deadlocks in InnoDB](https://dev.mysql.com/doc/refman/8.4/en/innodb-deadlocks.html)

## 1. 유명한 이유

실무에서 가장 자주 만나는 데드락은 두 트랜잭션이 자원을 반대 순서로 잡는 고전적 형태가 아닙니다. **같은 코드가 동시에 두 번 실행됐을 뿐인데** 나는 데드락입니다.

정산이나 집계에서 "그 날짜 행이 있으면 더하고 없으면 만든다"를 짤 때, 자연스러운 코드는 이렇습니다.

```sql
SELECT id FROM settlement WHERE live_id=? AND settle_date=? FOR UPDATE;  -- 확인
INSERT INTO settlement (...) VALUES (...);                                -- 없으면 삽입
```

두 요청이 동시에 오면 이 코드가 데드락을 냅니다. 원인은 REPEATABLE READ의 갭 락과 insert intention 락의 조합입니다. MySQL 공식 문서가 두 락을 각각 정의해 두었지만, 둘이 만났을 때 어떻게 되는지는 직접 재봐야 감이 옵니다.

이 세션은 그 조합을 재현하고, `performance_schema.data_locks`로 **락이 걸린 순간의 상태**를 포착하고, `SHOW ENGINE INNODB STATUS`의 데드락 그래프를 읽습니다. 그다음 해소 두 가지를 각각 30회씩 돌려 데드락이 실제로 사라지는지 셉니다.

## 2. 재현

### 환경

MySQL 8.4.3, REPEATABLE READ(기본값), `innodb_print_all_deadlocks=ON`. 데드락은 부하가 아니라 순서 문제라서 스레드 두 개면 재현됩니다. 자원 상한은 걸지 않았습니다.

기본값인 `innodb_print_all_deadlocks=OFF` 상태에서는 `SHOW ENGINE INNODB STATUS`가 **마지막 한 건만** 보여줍니다. 운영에서 데드락을 추적하려면 이 값을 켜서 에러 로그에 전부 남겨야 합니다.

### 락이 걸린 순간

![락 상태](results/fig-locks.png)

```
트랜잭션 2658  uk_live_date  X,GAP                   GRANTED   2, 1037565, 301
트랜잭션 2658  uk_live_date  X,GAP,INSERT_INTENTION  WAITING   2, 1037565, 301
트랜잭션 2659  uk_live_date  X,GAP                   GRANTED   2, 1037565, 301
```

세 줄이 이 세션의 전부입니다.

1. 두 트랜잭션이 **같은 갭에 X 갭 락을 동시에 GRANTED로 잡고 있습니다.** 갭 락끼리는 서로를 막지 않습니다. 갭 락의 목적은 "이 구간에 새 행이 들어오는 것을 막는 것"이지 "다른 갭 락을 막는 것"이 아니기 때문입니다.
2. 그런데 INSERT는 그 갭에 **insert intention 락**을 요청합니다. 이 락은 갭 락과 충돌합니다.
3. A의 insert intention이 B의 갭 락에 막히고, B의 것이 A의 갭 락에 막힙니다. 서로를 기다립니다.

`SELECT ... FOR UPDATE`가 성공했을 때 "내가 이 자리를 확보했다"고 읽으면 틀립니다. 확보한 것은 **다른 트랜잭션이 넣지 못하게 하는 권리**이지, 내가 넣을 수 있는 권리가 아닙니다.

### 데드락 그래프

![데드락 그래프](results/fig-graph.png)

`SHOW ENGINE INNODB STATUS`의 출력을 읽는 순서는 이렇습니다.

- `*** (1) TRANSACTION:` 아래 `HOLDS THE LOCK(S)`와 `WAITING FOR THIS LOCK`
- `*** (2) TRANSACTION:` 아래 같은 두 항목
- `*** WE ROLL BACK TRANSACTION (2)` — InnoDB가 희생자로 고른 쪽

락 대상이 `supremum` 레코드로 찍히는 것도 갭 락의 표시입니다. 마지막 레코드 뒤의 열린 구간을 잠글 때 supremum 의사 레코드에 락을 겁니다.

## 3. 해소

같은 시나리오를 두 방법으로 고쳐 각각 30회(시도 60건)씩 돌렸습니다.

| 방법 | 데드락 | 중복키 에러 | 판단 |
|---|---|---|---|
| 원래 방식 (`SELECT FOR UPDATE` 후 `INSERT`) | **30회** | 0 | 재현 기준 |
| `INSERT ... ON DUPLICATE KEY UPDATE` | **0회** | 0 | 권장 |
| READ COMMITTED로 낮추기 | **0회** | 30회 | 조건부 |

**확인과 삽입을 한 문장으로 합치는 쪽**이 답입니다. 갭 락을 먼저 잡는 단계 자체가 없어지고, 중복 처리는 엔진이 유니크 키로 합니다. 30회 전부 성공했고 중복키 에러도 없었습니다.

**READ COMMITTED**도 데드락은 없앱니다. 갭 락이 아예 없기 때문입니다. 다만 결과가 다릅니다. 60시도 중 30건이 중복키 에러(1062)로 실패했습니다. 데드락이 중복키 에러로 바뀐 것이고, 애플리케이션이 그 에러를 잡아 재시도하거나 무시해야 합니다. 실패를 없앤 게 아니라 실패의 종류를 바꾼 것이라, 예외 처리를 함께 넣지 않으면 장애의 모양만 달라집니다.

## 4. 인덱스가 없으면 락 범위가 넓어진다

두 번째 시나리오로 인덱스 없는 컬럼의 UPDATE를 넣었습니다. `WHERE status='PENDING'`은 `status`에 인덱스가 없어서 InnoDB가 전 행을 훑고, 훑은 행마다 락을 잡습니다. 조건에 맞지 않는 행의 락은 곧 풀리지만 그 사이가 곧 충돌 창입니다.

200행 테이블에서 조건에 맞는 건 100행인데 실제로는 그보다 많은 락이 잡혔습니다. 인덱스를 거는 것이 조회 성능만의 문제가 아니라 **락 범위를 좁혀 데드락 확률을 낮추는 일**이기도 합니다. 이 관점은 A22(인덱스가 있는데 못 쓰는 경우)와 짝이 됩니다.

## 5. 예상과 달랐던 점

### 격리 수준 변경이 조용히 안 먹었습니다

READ COMMITTED 해소를 검증하는데 데드락이 30회 그대로 나왔습니다. 원인은 `BEGIN` **뒤에** `SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED`를 둔 것이었습니다.

```
BEGIN;
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
SELECT @@transaction_isolation;   →  READ-COMMITTED
```

**변수는 바뀐 값을 보여주는데 실행 중인 트랜잭션은 그대로 REPEATABLE READ로 돕니다.** 세션 설정은 다음 트랜잭션부터 적용되기 때문입니다. 변수를 찍어 확인했는데도 안 먹는 상황이라, 이걸 모르면 "READ COMMITTED로 바꿨는데 갭 락이 그대로다"라는 결론에 도달합니다. `BEGIN` 앞으로 옮기자 데드락이 0회가 됐습니다.

### 행이 있으면 다른 데드락이 됩니다

시나리오를 두 번째 실행할 때 락 모드가 `X,GAP`이 아니라 `X,REC_NOT_GAP`으로 나왔습니다. 첫 실행에서 만든 행이 남아 있어 `SELECT FOR UPDATE`가 갭이 아닌 레코드를 잠근 것입니다. 여전히 데드락은 나지만 **메커니즘이 다릅니다.** 갭 락 데드락을 재현하려면 대상 행이 없는 상태에서 시작해야 하고, 그래서 매 실행 전 초기화를 넣었습니다.

같은 증상(1213 Deadlock found)이라도 원인이 갭 락인지 레코드 락인지에 따라 해법이 달라지므로, `data_locks`의 `LOCK_MODE`를 보지 않고 증상만으로 진단하면 안 됩니다.

## 못 한 것

- **세 번째 시나리오(획득 순서 엇갈림)를 문서에 넣지 않았습니다.** 고전적 형태라 새로 배울 게 적어 갭 락 쪽에 집중했습니다.
- **재시도 전략을 재지 않았습니다.** 데드락은 정상 동작의 일부이므로 잡아서 재시도하는 것이 정석인데, 재시도 횟수와 백오프에 따른 처리량 변화는 측정하지 않았습니다.
- **`SELECT ... FOR UPDATE SKIP LOCKED`나 `NOWAIT`을 비교하지 않았습니다.** 큐 소비 패턴에서 유효한 선택지인데 이 시나리오의 해법은 아닙니다.
- **분산 환경은 다루지 않았습니다.** 단일 인스턴스 두 세션입니다.
