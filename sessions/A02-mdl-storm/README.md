# A02 0.09초짜리 DDL이 20초 동안 조회를 세웠다

> 근거 등급: `E2`
> 출처: [MySQL 8.4 Reference, Metadata Locking](https://dev.mysql.com/doc/refman/8.4/en/metadata-locking.html), [Online DDL Performance, Concurrency, and Space Requirements](https://dev.mysql.com/doc/refman/8.4/en/innodb-online-ddl-performance.html), [Online DDL Operations](https://dev.mysql.com/doc/refman/8.4/en/innodb-online-ddl-operations.html), [Server System Variables, `lock_wait_timeout`](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html#sysvar_lock_wait_timeout), [InnoDB Startup Options and System Variables, `innodb_lock_wait_timeout`](https://dev.mysql.com/doc/refman/8.4/en/innodb-parameters.html#sysvar_innodb_lock_wait_timeout)

## 1. 유명한 이유

**이 세션은 MySQL 사건의 공개 원문을 확보하지 못했습니다.** 컬럼 하나를 붙이려다 서비스가 섰다는 이야기는 흔히 오가지만, MySQL 메타데이터 락으로 그 인과 전체를 적어 둔 기업 보고서는 조사에서 못 찾았습니다. 그래서 이 글은 사건이 아니라 **구조**에서 시작합니다. 구조는 매뉴얼에 그대로 적혀 있고, 같은 구조의 공개 사례는 옆 엔진(PostgreSQL)에 둘 있습니다.

근거를 이렇게 나눠 씁니다.

| 무엇 | 등급 | 출처 |
|---|---|---|
| 락 구조 | 1차 | MySQL 매뉴얼 두 문장(아래 인용) |
| 같은 구조의 실사건 | E1 | Railway, GoCardless. **다만 PostgreSQL 이고 락 이름도 다릅니다** |
| MySQL 에서의 실측 | 본인 계측 | 이 글의 2절부터 |

**MySQL 실사례를 유사 엔진 사례로 대체했다는 것을 먼저 적어 둡니다.** 그 자리를 메우는 것이 이 글의 계측입니다.

매뉴얼은 락의 수명을 이렇게 적습니다.

> The server achieves this by acquiring metadata locks on tables used within a transaction and deferring release of those locks until the transaction ends.

트랜잭션이 끝날 때까지 유지됩니다. 그래서 커밋하지 않은 트랜잭션 하나가 남아 있으면 DDL이 들어가지 못합니다. 여기까지는 "DDL이 기다린다"는 이야기이고 서비스와는 상관이 없어 보입니다. 문제는 그다음 문장입니다.

> Additionally, a pending exclusive metadata lock requested by an online DDL operation blocks subsequent transactions on the table.

대기 중인 DDL이 그 뒤에 오는 트랜잭션을 막습니다. 조회 하나하나는 서로를 막지 않지만, 가운데 낀 DDL이 벽이 됩니다.

MySQL 8.4에는 반전이 하나 더 붙습니다. 매뉴얼은 `INSTANT is the default algorithm in MySQL 8.4`라고 적습니다. 컬럼 추가는 데이터 파일을 건드리지 않고 메타데이터만 고치므로 실행 자체가 순식간에 끝납니다. 그런데도 배타적 메타데이터 락은 필요합니다. 실행 시간이 0에 가까운 DDL이 장애를 만드는 구도가 여기서 나옵니다.

이 세션은 롱 트랜잭션과 DDL과 일반 조회를 한 타임라인에 올려 놓고, 무엇이 무엇을 얼마나 막는지를 초 단위로 잽니다.

## 2. 재현

### 환경

| 항목 | 값 |
|---|---|
| 호스트 | Rocky Linux, 커널 5.14.0-570.33.2.el9_6.aarch64, 2코어, 11GB |
| DB | MySQL 8.4.3 (컨테이너 `cpus: 2`, `mem_limit: 2g`) |
| 버퍼 풀 | 1GB, `performance_schema=ON` |
| 데이터 | `orders` 200만 행, 280MB |
| 부하 | PK 점조회, 프로세스 2개, 60초 |

버퍼 풀 1GB에 테이블이 280MB이므로 조회는 전부 메모리에서 끝납니다. 정지 구간이 디스크 때문일 가능성을 없애려는 조건입니다. `performance_schema`를 켠 것은 `metadata_locks` 테이블을 보기 위해서입니다.

### 일정

네 조건 모두 같은 시각에 같은 일을 합니다.

| 시각 | 하는 일 |
|---|---|
| 0초 | 조회 부하 시작 |
| 15초 | 세션 L이 `BEGIN` 후 `SELECT` 한 번. 커밋하지 않음 |
| 25초 | 세션 D가 `ALTER TABLE orders ADD COLUMN memo VARCHAR(64) NULL` |
| 45초 | 세션 L이 커밋 |
| 60초 | 측정 종료 |

조건은 넷입니다. 롱 트랜잭션만 도는 대조군, DDL만 도는 대조군, 둘이 겹치는 조건, 겹치되 `lock_wait_timeout`을 2초로 줄인 조건입니다. 대조군 둘이 있어야 정지가 롱 트랜잭션 탓인지 DDL 탓인지 겹침 탓인지 가릴 수 있습니다.

### 결과

| 조건 | DDL 이전 초당 | 전면 정지 | 최대 지연 | DDL 결과 |
|---|---|---|---|---|
| 롱 트랜잭션만 (DDL 없음) | 3,464건 | 0초 | 183ms | 실행 안 함 |
| DDL만 (롱 트랜잭션 없음) | 3,658건 | 0초 | 139ms | 성공, 0.09초 |
| 겹침 + `lock_wait_timeout` 2초 | 3,576건 | 2초 | 2,005ms | 실패(1205), 2.02초 |
| 겹침 + 기본 타임아웃 | 2,462건 | 20초 | 20,021ms | 성공, 20.09초 |

"DDL 이전 초당"은 0초부터 24초까지 초당 완료 건수의 중앙값입니다. 네 조건 모두 DDL이 25초에 들어가므로 이 구간에는 아직 아무 개입도 없습니다. 조건 사이의 차이를 설정의 효과로 읽으면 안 되고, 그 이유는 5절에 따로 적었습니다.

![전면 정지 구간의 길이](results/01-stall.png)

"전면 정지"는 그 초의 완료 건수가 위 중앙값의 10% 아래인 초를 셉니다. 겹침 + 기본 타임아웃 조건에서 여기 걸린 초는 25초부터 44초까지 20개입니다. 그중 완료 건수가 정확히 0인 초는 26초부터 44초까지 19개이고, 25초에는 104건이 완료됐습니다. `lock_wait_timeout` 2초 조건의 정지 2초도 마찬가지로 25초(68건)와 26초(0건)입니다. 정지 길이와 완전 무응답 길이가 1초씩 다릅니다.

![MDL 폭풍 구간](results/00-timeline.png)

25초에 DDL이 들어가고 26초부터 44초까지 완료 건수가 0입니다. 45초에 롱 트랜잭션이 커밋되자 밀려 있던 조회가 한꺼번에 돌아왔고, 그중 가장 오래 기다린 것이 20,020.8ms입니다.

여기서 짚을 것이 둘입니다. 첫째, 롱 트랜잭션만 있을 때는 정지가 0초입니다. 트랜잭션이 30초 동안 락을 쥐고 있어도 다른 조회는 아무 영향을 받지 않습니다. 둘째, DDL만 있을 때도 정지가 0초이고 DDL은 0.09초에 끝납니다. 각각은 무해합니다.

### 대기 큐

`performance_schema.metadata_locks`를 1초마다 훑었습니다. 겹침 조건의 25.1초 스냅샷입니다.

```
granted 2 / pending 3
  EXCLUSIVE:PENDING
  SHARED_READ:GRANTED
  SHARED_READ:PENDING
  SHARED_UPGRADABLE:GRANTED
```

`SHARED_READ:GRANTED`는 롱 트랜잭션이 쥔 것입니다. `SHARED_UPGRADABLE:GRANTED`와 `EXCLUSIVE:PENDING`은 DDL이 쥔 것과 원하는 것입니다. 그리고 `SHARED_READ:PENDING`이 일반 조회입니다. 조회가 롱 트랜잭션을 기다리는 것이 아니라 그 앞에 선 DDL을 기다리고 있습니다.

대조군 두 조건에서는 DDL 실행 이후 구간에 대기 중인 락이 잡히지 않았습니다.

## 3. 내부 원리

메타데이터 락은 테이블의 정의를 보호합니다. 어떤 세션이 테이블을 읽는 중에 다른 세션이 그 테이블의 구조를 바꾸면 안 되기 때문에, 조회는 `SHARED_READ`를, DDL은 `EXCLUSIVE`를 잡습니다. 둘은 서로 충돌합니다.

수명은 문장이 아니라 트랜잭션에 묶입니다. 매뉴얼은 오토커밋일 때 "metadata locks acquired for the statement are held only to the end of the statement"라고 적고, 명시적 트랜잭션에서는 트랜잭션이 끝날 때까지 유지된다고 적습니다. 이 실험의 롱 트랜잭션이 `SELECT` 한 번만 하고 30초를 놀아도 락을 계속 쥐고 있는 이유입니다.

DDL이 막히는 것까지는 여기서 설명됩니다. 조회까지 막히는 이유는 대기 큐의 우선순위에 있습니다. 매뉴얼은 이렇게 적습니다.

> If there are multiple waiters for a given lock, the highest-priority lock request is satisfied first ... Write lock requests have higher priority than read lock requests.

DDL의 배타적 락 요청이 뒤에 오는 읽기 락 요청보다 우선합니다. 그래서 조회는 앞선 DDL이 처리될 때까지 큐에서 기다립니다. DDL은 롱 트랜잭션을 기다리고, 조회는 DDL을 기다리는 사슬이 만들어집니다.

`ALGORITHM=INPLACE, LOCK=NONE`으로 지정해도 이 사슬은 끊기지 않습니다. 온라인 DDL 문서가 그 이유를 적습니다.

> In the commit table definition phase, the metadata lock is upgraded to exclusive to evict the old table definition and commit the new one. Once granted, the duration of the exclusive metadata lock is brief.

> Due to the exclusive metadata lock requirements outlined above, an online DDL operation may have to wait for concurrent transactions that hold metadata locks on the table to commit or rollback.

배타적 락을 쥐고 있는 시간은 짧습니다. 문제는 그것을 **얻기까지** 기다리는 시간이고, 그 대기 자체가 뒤의 조회를 막습니다. "온라인 DDL"이라는 이름은 DDL이 도는 동안 DML을 허용한다는 뜻이지, 락을 기다리지 않는다는 뜻이 아닙니다.

8.4에서 `ADD COLUMN`이 `INSTANT`로 처리되는 것도 같은 이야기입니다. 실행 단계가 사라져도 락을 잡는 단계는 남습니다. 이 실험에서 DDL 단독 조건의 소요가 0.09초였고 겹침 조건이 20.09초였는데, 그 차이 20초는 전부 대기입니다.

`INSTANT`가 늘 되는 것은 아닙니다. 매뉴얼은 테이블 하나가 가질 수 있는 행 버전을 64개로 제한합니다(9.1.0부터 255개). 컬럼을 즉시 붙이거나 지울 때마다 행 버전이 하나 늘고, 상한을 넘기면 `ADD COLUMN`과 `DROP COLUMN`이 거부됩니다.

```
ERROR 4092 (HY000): Maximum row versions reached for table test/t1.
No more columns can be added or dropped instantly. Please use COPY/INPLACE.
```

번호만 보고 원인을 단정하면 안 됩니다. 매뉴얼은 행 크기가 상한을 넘길 때도 같은 4092를 보여줍니다. `Column can't be added with ALGORITHM=INSTANT as after this max possible row size crosses max permissible row size` 쪽입니다. 두 경우는 대응이 다르니 메시지 본문까지 읽어야 합니다. 그리고 `ROW_FORMAT=COMPRESSED` 테이블, FULLTEXT 인덱스가 있는 테이블, 데이터 딕셔너리 테이블스페이스에 있는 테이블은 `INSTANT`로 컬럼을 붙이거나 지울 수 없고, 임시 테이블은 `ALGORITHM=COPY`만 됩니다. 이 조건에 걸리면 8.4에서도 `ADD COLUMN`이 0.09초로 끝나지 않으므로 정지 구간의 모양이 달라집니다.

이 세션의 `scripts/mdl.py`가 그 상한에 직접 걸리는 코드입니다. 조건마다 같은 `orders` 테이블에 `memo`를 붙이고, 다음 조건을 시작하기 전에 남아 있으면 지웁니다. 붙이는 것도 지우는 것도 행 버전을 하나씩 올리므로 반복 실행이 쌓이면 4092에 닿습니다. 이번에는 몇 바퀴만 돌려서 실제로 보지는 못했습니다. 반복 측정으로 회차를 늘린다면 조건 사이에 테이블을 다시 만들어 행 버전을 되돌려야 합니다.

## 4. 해소

`lock_wait_timeout`을 짧게 잡고 DDL을 던집니다. 기본값은 31,536,000초, 곧 1년입니다. 사실상 무한정 기다린다는 뜻이고, 기다리는 내내 조회를 막습니다.

```sql
SET SESSION lock_wait_timeout = 2;
ALTER TABLE orders ADD COLUMN memo VARCHAR(64) NULL;
```

2초 안에 락을 못 얻으면 DDL이 `ERROR 1205 (HY000): Lock wait timeout exceeded` 로 죽습니다. DDL이 죽으면 대기 큐가 풀리고 조회가 돌아옵니다. 장애 시간이 DDL의 인내심과 같아지므로, 그 인내심을 짧게 두는 것이 방어입니다.

여기서 번호 하나를 갈라 두어야 합니다. 1205를 내는 타임아웃은 두 개이고, 서로 다른 변수가 관장합니다. 메타데이터 락 쪽은 `lock_wait_timeout` 문서가 적습니다.

> A given statement can require more than one lock, so it is possible for the statement to block for longer than the lock_wait_timeout value before reporting a timeout error. When lock timeout occurs, ER_LOCK_WAIT_TIMEOUT is reported.

`ER_LOCK_WAIT_TIMEOUT`이 1205입니다. 그런데 `innodb_lock_wait_timeout` 문서에도 같은 번호가 있습니다.

> The length of time in seconds an InnoDB transaction waits for a row lock before giving up. The default value is 50 seconds. A transaction that tries to access a row that is locked by another InnoDB transaction waits at most this many seconds for row locks before issuing the following error:
>
> `ERROR 1205 (HY000): Lock wait timeout exceeded; try restarting transaction`

두 변수는 대상도 기본값도 다릅니다. `lock_wait_timeout`은 테이블 정의를 지키는 메타데이터 락에 걸리고 기본값이 31,536,000초입니다. `innodb_lock_wait_timeout`은 행 락에 걸리고 기본값이 50초입니다. 이 세션이 줄인 것은 앞의 것이고, 뒤의 것은 건드리지 않았습니다.

에러 사전은 1205를 InnoDB 관점으로만 설명해서 메타데이터 락 쪽이 잘 보이지 않습니다. 그래서 1205 로그를 보고 `innodb_lock_wait_timeout`부터 줄이는 일이 생기는데, 그렇게 하면 이 세션이 보인 정지는 1초도 줄지 않습니다. 어느 문장이 1205를 냈는지부터 갈라야 합니다. `ALTER`나 `RENAME`이나 `TRUNCATE`가 냈으면 메타데이터 락이고, `UPDATE`나 `SELECT ... FOR UPDATE`가 냈으면 행 락입니다.

DDL은 실패하므로 재시도가 따라와야 합니다. 실무에서는 마이그레이션 도구가 짧은 타임아웃으로 여러 번 시도하고, 매번 실패하면 사람에게 알립니다. 반복해서 실패한다면 그것은 DDL의 문제가 아니라 그 테이블에 롱 트랜잭션이 상주한다는 신호입니다.

근본 쪽도 같이 봅니다. 이 실험에서 락을 쥔 것은 `SELECT` 한 번 하고 커밋하지 않은 트랜잭션이었습니다. 애플리케이션이 트랜잭션을 열어 놓고 외부 호출을 하거나, ORM이 세션을 오래 붙들거나, 관리자가 콘솔에서 `BEGIN`만 치고 자리를 비우면 같은 상태가 됩니다. `information_schema.INNODB_TRX`나 `performance_schema.metadata_locks`로 DDL 전에 확인할 수 있습니다.

## 5. 재계측

같은 부하와 같은 일정에서 `lock_wait_timeout`만 2초로 바꿨습니다.

| 항목 | 기본 타임아웃 | 2초 타임아웃 | 차이 |
|---|---|---|---|
| 전면 정지 | 20초 | 2초 | 18초 단축 |
| 조회 최대 지연 | 20,021ms | 2,005ms | 90% 감소 |
| DDL | 성공, 20.09초 | 실패(1205), 2.02초 | 재시도 필요 |
| DDL 이전 초당 (0~24초) | 2,462건 | 3,576건 | 개입 이전 구간이라 효과가 아님 |

![조회 최대 대기 시간](results/02-latency.png)
![ALTER 문장 소요 시간](results/03-ddl.png)

정지가 20초에서 2초로 줄었고, 그 2초는 DDL이 기다리기로 정한 시간과 같습니다. 장애 시간을 설정값 하나로 정할 수 있게 됩니다.

**마지막 행은 이 설정의 성과가 아닙니다.** 처음 쓴 표에는 "평시 초당 처리가 2,462건에서 3,576건으로 대조군 수준으로 회복됐다"고 적혀 있었는데 틀린 귀속이었습니다. `scripts/mdl.py`가 평시 기준선을 잡는 구간은 `sec < args.ddl_at`, 곧 0초부터 24초까지입니다. `ddl_at`은 네 조건 모두 25로 고정이고 `SET SESSION lock_wait_timeout = 2`는 그 25.0초에 실행됩니다. 기준선을 다 잰 다음에 설정이 들어가므로 설정이 그 구간에 영향을 줄 경로가 없습니다.

`results/case-*.json`의 원시값을 보면 더 분명합니다. 겹침 + 기본 타임아웃 조건은 측정이 시작된 0초부터 이미 초당 2,400~2,700건대였고 0~24초 평균이 2,473건입니다. 나머지 세 조건은 같은 구간 평균이 3,549건, 3,692건, 3,715건입니다. DDL 직전 5초만 떼어 보면 2,129건 대 3,537~3,580건으로 40% 차이입니다. 아무 일도 일어나지 않은 구간에서 벌어진 차이이므로 통제하지 못한 실행 간 편차로 보았습니다.

### 그 편차를 반복 측정으로 확인했습니다 (2026-07-30)

당시에는 "편차 말고 설명할 방법이 없다"고만 적어 두었습니다. 실재하는 차이라면 조건 비교
자체가 흔들리므로, 세 회차를 더 돌려 확인했습니다. 12코어 맥에서 `tools/repeat-runs.sh`로 돌린 값입니다. **네 칸 모두 `timeline`의 0~24초 구간 평균, 곧 DDL 이 들어오기 전 평시 기준선입니다**(`median_qps` 가 아닙니다). 이 절의 질문이 "아무 일도 없는 구간에서 조건끼리 갈리는가"라서 그 구간만 잘라 봅니다. run0 은 2코어 호스트라 절대값이 낮고, 비교는 회차 안에서만 해야 합니다.

| 조건 | run0 (2코어) | run1 | run2 | run3 |
|---|---|---|---|---|
| 롱 트랜잭션만 | 3,549 | 14,685 | 14,704 | 15,863 |
| 겹침 + 기본 타임아웃 | **2,473** | 14,771 | 14,834 | 15,767 |
| 겹침 + 2초 타임아웃 | 3,715 | 14,685 | 14,739 | 15,674 |
| DDL만 | 3,692 | 14,635 | 15,685 | 15,806 |

회차마다 겹침 조건과 나머지 세 조건의 평균을 견주면 이렇습니다.

| 회차 | 겹침 조건 | 나머지 셋 평균 | 차이 |
|---|---|---|---|
| run0 | 2,473 | 3,652 | 겹침이 32.3% 낮음 |
| run1 | 14,771 | 14,668 | 겹침이 0.7% 높음 |
| run2 | 14,834 | 15,043 | 겹침이 1.4% 낮음 |
| run3 | 15,767 | 15,781 | 겹침이 0.1% 낮음 |

**세 회차에서 그 차이가 재현되지 않았습니다.** 1.4% 안쪽이고 부호도 갈립니다. 아무 일도
일어나지 않은 구간에서 겹침 조건만 낮게 나오는 성질은 없습니다. 조건 비교가 흔들릴
걱정은 여기서 닫힙니다.

한 가지는 분명히 해 두어야 합니다. run0은 2코어 리눅스 서버에서, run1~3은 12코어 맥에서
쟀습니다. 절대 처리량이 3,500건대와 14,700건대로 4배 차이 나는 것이 그래서입니다. 그러니
"run0의 31.0%가 편차였다"를 장비 간 비교로 증명한 것은 아닙니다. 말할 수 있는 것은
**조건 외의 변수를 같게 둔 세 회차에서 그 차이가 나타나지 않았다**는 것까지입니다.

정지 길이와 DDL 결과는 네 회차 모두 같습니다. 장비가 달라도 흔들리지 않았습니다.

| 조건 | 정지 | DDL 소요 | DDL 결과 |
|---|---|---|---|
| 롱 트랜잭션만 | 0초 (4/4) | 실행 안 함 | 없음 |
| 겹침 + 기본 타임아웃 | 20초 (4/4) | 20.09 / 20.01 / 20.01 / 20.01초 | 성공 (4/4) |
| 겹침 + 2초 타임아웃 | 2초 (4/4) | 2.02 / 2.00 / 2.00 / 2.00초 | 1205 실패 (4/4) |
| DDL만 | 0초 (4/4) | 0.09 / 0.01 / 0.01 / 0.00초 | 성공 (4/4) |

이 세션의 결론은 전부 이 표에서 나옵니다. 그리고 이 표는 2코어와 12코어에서 같습니다.

이 표에서 개입의 효과로 읽어도 되는 것은 정지 길이와 최대 지연과 DDL 결과, 이 셋뿐입니다. 셋 다 25초 이후, 곧 설정이 적용된 뒤 구간에서 나온 값입니다.

대가는 DDL이 실패한다는 것입니다. 이 트레이드오프는 한쪽으로만 기울지 않습니다. 마이그레이션을 반드시 이번 배포에 통과시켜야 한다면 긴 타임아웃이 필요하고, 그 경우 트래픽이 적은 시간대를 골라야 합니다. 다만 기본값 1년은 어느 쪽 선택도 아닙니다.

DDL 단독 조건이 기준선을 줍니다. 롱 트랜잭션이 없을 때 같은 `ALTER`는 0.09초에 끝났고 정지는 0초였습니다. 앞을 비워 두기만 하면 이 DDL은 무해합니다.

## 6. 사고가 되는 구간: 커넥션 풀 고갈

`scripts/cascade.py`, 원문은 `results/cascade-*.json`. 앞에 크기 10(HikariCP 기본값)짜리 풀을
두고 엔드포인트 둘을 초당 20건씩 20초 동안 때립니다. 획득 타임아웃은 2초입니다.

![커넥션을 못 받은 요청](results/fig-cascade.png)

| 조건 | DDL | 풀 여유 최소 | `/orders` 성공 | `/orders` 풀 실패 | `/other` 성공 | `/other` 풀 실패 |
|---|---|---|---|---|---|---|
| 대조군 | 없음 | 8 | 400/400 | 0 | 400/400 | 0 |
| DDL, 읽기 | 11,046ms | **0** | 229 | **171** | 228 | **172** |
| DDL, 쓰기 | 11,046ms | **0** | 229 | 171 | 229 | 171 |

`/other` 는 DDL 대상 테이블을 건드리지 않는데도 43%를 잃습니다.

![죽는 방식](results/fig-cascade-how.png)

| | p50 | max | 무엇에 걸렸나 |
|---|---|---|---|
| `/orders` | 1,079.2ms | **11,023.8ms** | MDL 큐에서 실제로 기다림 |
| `/other` | 645.9ms | **2,009.4ms** | 획득 타임아웃 2초. **DB 에 닿지도 못함** |

`/other` 의 실패는 슬로우 쿼리 로그에도 `performance_schema` 에도 없습니다. 애플리케이션
로그의 `Connection is not available, request timed out` 이 유일한 흔적입니다.

쓰기 부하로 바꿔도 값이 같습니다(171 대 171). `SHARED_WRITE` 도 대기 중인 `EXCLUSIVE` 뒤에
섭니다. 2절에서 읽기만 쟀던 것을 여기서 채웠습니다.

### 밟은 함정 셋

1. **엔드포인트를 스레드 하나로 두었습니다.** 순차 요청이라 `/orders` 가 11초 막히는 동안
   커넥션을 하나만 쥐어 풀 10개 중 9개가 남았습니다. 재현하려던 풀 고갈이 일어나지 않았고
   `/other` 는 멀쩡했습니다. 요청마다 스레드를 띄우는 모델로 바꿨습니다.

2. **동시 실행 상한을 누적 스레드 수로 셌습니다.** `threads` 리스트가 줄어들지 않아 상한
   600 이 총 발사 수를 제한했고, 대조군에서도 200건이 발사되지 못했습니다. 조건 사이 비교가
   깨집니다. `BoundedSemaphore` 로 바꿨습니다.

3. **`load` 이미지에 `cryptography` 가 없었습니다.** MySQL 8 의 `caching_sha2_password` 는
   서버 캐시가 비어 있을 때 RSA 공개키 교환을 하고 pymysql 이 그것을 하려면 이 패키지가
   필요합니다. 한 번 성공하면 캐시 덕에 없어도 붙으므로 **볼륨을 새로 만든 회차에서만
   조용히 깨집니다.** 반복 측정에서 특히 위험한 결함이라 Dockerfile 에 넣었습니다.

## 7. 예상과 달랐던 점

**정지 구간이 집계에서 통째로 사라졌습니다.** 첫 실행에서 스크립트가 "정지된 초 1개"라고 찍었습니다. 20초 정지를 눈으로 보고도 코드가 못 잡은 것인데, 원인은 집계 방식이었습니다. 초당 버킷을 실제로 완료된 조회에서만 만들었기 때문에, 완료가 0건인 초는 버킷 자체가 생기지 않았습니다. 있는 버킷만 훑으며 정지를 세니 26초부터 44초까지가 표에서 빠졌습니다. 가장 심한 구간이 데이터에 아예 없는 상태로 "정상"이라고 보고될 뻔했습니다. 모니터링에서도 같은 일이 일어납니다. 완료된 요청의 지연만 그리는 대시보드는 아무것도 완료되지 않는 구간을 빈 구간으로 그립니다.

**롱 트랜잭션 단독은 무해했습니다.** 롱 트랜잭션이 위험하다는 말을 자주 듣지만, 이 실험에서 30초짜리 트랜잭션이 락을 쥐고 있던 15초부터 44초까지 초당 완료 건수의 중앙값은 3,446건이었고 전면 정지는 0초, 60초 전체의 최대 지연은 183ms였습니다. DDL이 끼어들어야 문제가 됩니다. 위험한 것은 롱 트랜잭션 자체가 아니라 롱 트랜잭션과 DDL이 만나는 시점입니다.

**DDL이 20.09초 걸렸다는 기록만 보면 원인을 잘못 짚습니다.** 로그에 남는 것은 "ALTER가 20초 걸렸다"입니다. 이 숫자를 보면 테이블이 커서 오래 걸렸다고 읽기 쉽고, 실제로는 DDL이 일한 시간이 0.09초입니다. 나머지 20초는 남의 트랜잭션을 기다린 시간입니다. 같은 DDL을 빈 시간에 돌리면 0.09초에 끝납니다.

## 알고리즘을 명시한 세 DDL (2026-08-01)

지금까지 쟀던 DDL 은 `ADD COLUMN` 하나입니다. MySQL 8.4 에서 그것은 `INSTANT` 라 실행 자체가 0.09초이고, 테이블을 다시 쓰는 DDL 이 같은 MDL 대기 아래에서 어떻게 되는지는 안 봤습니다. 알고리즘을 명시한 셋을 3회씩 돌렸습니다. 명시하면 그 알고리즘으로 못 할 때 서버가 거부하므로 조건이 안 선 채로 지나가지 않습니다.

타임라인은 앞 절들과 같습니다. t=15 에 롱 트랜잭션이 `SELECT` 후 커밋하지 않고, t=25 에 DDL 이 들어오고, t=45 에 롱 트랜잭션이 커밋합니다.

| 알고리즘 | DDL 전체 | 회차 폭 | 단독 실행 |
|---|---|---|---|
| `INSTANT` (`ADD COLUMN`) | 20.01초 | 0.00초 | 0.07초 |
| `INPLACE` (`ADD INDEX`, `LOCK=NONE`) | **22.58초** | 0.08초 | 2.29초 |
| `COPY` (테이블 재작성) | 20.04초 | 0.03초 | 3.84초 |

**전체 시간만 보면 세 알고리즘이 거의 같습니다.** 20.01, 22.58, 20.04초입니다. 200만 행을 통째로 다시 쓰는 `COPY` 가 `INSTANT` 와 같은 20초입니다. 단독으로 재면 3.84초 대 0.07초로 55배 차이인데도 그렇습니다.

`performance_schema.metadata_locks` 를 1초마다 훑은 기록이 이유를 말해 줍니다.

| 알고리즘 | `SHARED_UPGRADABLE` 확보 | `EXCLUSIVE` 요청 | 일반 조회가 막히기 시작 | 막힌 시간 |
|---|---|---|---|---|
| `INSTANT` | 25.1초 | 25.1초 | 25.1초 | **19.9초** |
| `INPLACE` | 25.1초 | 25.1초 | 25.1초 | **19.9초** |
| `COPY` | 25.1초 | **29.1초** | **29.1초** | **15.9초** |

**세 DDL 다 락을 안 기다리고 바로 시작합니다.** `SHARED_UPGRADABLE` 은 롱 트랜잭션이 쥔 `SHARED_READ` 와 호환됩니다. 25.1초에 셋 다 확보합니다.

**`COPY` 는 복사를 먼저 끝내고 나중에 배타 락을 요구합니다.** 25.1초부터 29.1초까지 4초 동안 200만 행을 새 파일로 복사합니다. 그 4초 동안 일반 조회는 멀쩡히 돕니다. 복사가 끝난 29.1초에야 교체용 `EXCLUSIVE` 를 요청하고, 그 순간부터 뒤따르는 조회가 큐에 쌓입니다.

**`INPLACE` 는 시작하자마자 배타 락을 요구합니다.** 25.1초에 `EXCLUSIVE:PENDING` 이 뜨고 그때부터 조회가 막힙니다. 인덱스 빌드는 락을 얻은 **뒤에** 합니다. 그래서 완료가 22.58초로 가장 늦습니다. **다만 조회가 막힌 시간은 `INSTANT` 와 같은 19.9초입니다.** 완료가 늦은 것과 장애가 긴 것은 다릅니다.

**조회가 막힌 시간은 `COPY` 가 가장 짧습니다.** 15.9초 대 19.9초입니다. 처리량이 0 인 초도 16 대 19 입니다.

이건 통념과 반대입니다. `ALGORITHM=COPY` 는 "테이블을 통째로 다시 쓰는 최악" 이고 `ALGORITHM=INPLACE, LOCK=NONE` 은 "온라인" 이라고 부릅니다. **앞을 막는 롱 트랜잭션이 있으면 그 이름이 뒤집힙니다.**

이유는 배타 락을 언제 요구하느냐입니다. **DDL 이 도는 시간이 아니라 배타 락을 요구한 시점부터 장애가 시작합니다.** `COPY` 는 일을 먼저 하고 요구하고, `INPLACE` 는 요구하고 나서 일을 합니다.

**이 역전에는 조건이 하나 붙습니다.** `COPY` 가 유리하게 나온 것은 복사 4초가 롱 트랜잭션의 잔여 대기 20초보다 **짧았기** 때문입니다. 표가 커서 복사가 25초 걸렸다면 배타 락 요청은 50초에 나가는데 롱 트랜잭션은 45초에 이미 커밋했으므로, 그때는 `COPY` 가 훨씬 나쁩니다. **역전은 복사 시간이 롱 트랜잭션 잔여 시간보다 짧을 때만 성립합니다.** 여기서 4초는 200만 행이라는 특정 규모에서 나온 값입니다.

세 알고리즘의 회차 폭이 0.00~0.08초입니다. 조건 사이 차이가 2.5초이므로 이 값을 인용할 수 있습니다.

**읽는 법이 하나 더 있습니다.** 롱 트랜잭션이 없으면 이 순서가 다시 뒤집힙니다. `COPY` 는 3.84초 내내 쓰기를 막고 `INPLACE` 는 2.29초 동안 온라인으로 돕니다. **위 표는 "앞에 롱 트랜잭션이 있을 때" 의 값이고, 그것이 이 세션이 다루는 조건입니다.**

## 못 한 것

- **세 알고리즘은 롱 트랜잭션이 있는 조건에서만 쟀습니다.** 롱 트랜잭션 없이 같은 셋을 부하 아래에서 돌린 대조는 안 했습니다. 단독 실행 시간만 따로 재 두었습니다.
- **gh-ost와 pt-online-schema-change를 돌리지 않았습니다.** 카탈로그의 원래 설계에는 들어 있었는데 이번에는 빼고 `lock_wait_timeout` 쪽만 다뤘습니다. 두 도구도 최종 전환 시점에 배타적 락이 필요하므로 이 세션이 보인 사슬에서 자유롭지 않지만, 그것을 실측하지는 않았습니다.
- **2절부터 5절까지는 읽기 부하만입니다.** 쓰기 부하는 6절에서만 쟀고 조건 1회 실행입니다.
- **6절의 풀은 최소 구현입니다.** `queue.Queue` 기반이라 HikariCP 의 `maxLifetime`, `leakDetectionThreshold`, 하우스키핑이 없습니다. 획득 타임아웃도 기본값 30초가 아니라 2초로 줄여 잡았습니다.
- **복제는 다루지 않았습니다.** 단일 인스턴스입니다. DDL이 레플리카에서 재생될 때의 지연은 이 세션 밖입니다.

## 파일

| 경로 | 내용 |
|---|---|
| [compose.yml](compose.yml) | MySQL 8.4.3과 부하 컨테이너 |
| [schema.sql](schema.sql) | `orders` 한 장 |
| [scripts/seed.py](scripts/seed.py) | 200만 행 적재 |
| [scripts/mdl.py](scripts/mdl.py) | 롱 트랜잭션, DDL, 조회 부하를 한 타임라인에 올려 계측 |
| [scripts/report.py](scripts/report.py) | 표 출력과 `results/render.json` 생성 |
| [reproduce.md](reproduce.md) | 실행 명령과 출력 원문 |
