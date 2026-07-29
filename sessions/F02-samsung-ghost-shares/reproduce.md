# 재현 기록

실행한 명령과 출력을 원문 그대로 남깁니다. 요약하지 않습니다. 아래 발췌는 전부 한 번의
`docker compose up` 출력에서 가져왔고, 전체 로그 원문은 [results/full-run.txt](results/full-run.txt)에 있습니다.
같은 로그는 언제든 `docker compose up --abort-on-container-exit`로 다시 만들 수 있습니다.

## 환경

- 호스트: Rocky Linux 9 (aarch64), Docker 29.4.2, Docker Compose v5.1.3
- DB: postgres:16-alpine (PostgreSQL 16.14). 호스트 포트는 게시하지 않는다
- 러너: 같은 이미지의 psql이 sql/ 스크립트를 순서대로 실행 (scripts/run.sh)
- 데이터: 결정적 시드. 발행총수 1,000,000주, 우리사주 조합원 999계좌(계좌 i가 `5 + (i % 51)`주, 5~55주), 기관 수탁 1계좌. 예탁 합계 970,000주
- 동시성 실험 타이밍: 두 세션 기동 간격 1초, 각 세션은 UPDATE(검증) 후 `pg_sleep(3)` 뒤 커밋. 검증 구간이 겹치도록 고정한 값이며 측정치가 아니다
- 일시: 2026-07-28. 건수·배율은 결정적이라 실행마다 같다 (같은 날 4회 실행해 동일 수치 확인)

## 1. 기동과 초기 원장

```console
$ docker compose up --abort-on-container-exit
 Container lab-f02-db Healthy
 Container lab-f02-runner Started

lab-f02-runner  | [1] 초기 원장: 발행총수 1,000,000주, 계좌 1,000개, 교차행 불변식 없음
lab-f02-runner  | INSERT 0 999
lab-f02-runner  | INSERT 0 1
lab-f02-runner  | 초기 원장 상태:
lab-f02-runner  |  발행총수(주) | 계좌 수 | 잔고 합계(주) | 합계/발행총수 
lab-f02-runner  | --------------+---------+---------------+---------------
lab-f02-runner  |       1000000 |    1000 |        970000 |          0.97
```

## 2. 버그: 착오 배당 배치가 그대로 커밋된다

주당 1,000원 현금 지급이 의도인데, 같은 수가 단위 검증 없이 `shares` 컬럼으로 들어간다.

```console
lab-f02-runner  | [2] 버그 재현: 배당 배치의 원/주 단위 착오가 그대로 커밋된다
lab-f02-runner  | 착오 배당 배치 실행: 주당 1,000원 배당금이 주당 1,000주 입고로 들어간다
lab-f02-runner  | BEGIN
lab-f02-runner  | UPDATE 999
lab-f02-runner  | COMMIT
lab-f02-runner  | 
lab-f02-runner  | 커밋 성공. 발행총수를 넘겼는데 아무 제약에도 걸리지 않았다:
lab-f02-runner  |  발행총수(주) | 잔고 합계(주) | 합계/발행총수 
lab-f02-runner  | --------------+---------------+---------------
lab-f02-runner  |       1000000 |      30655000 |         30.66
lab-f02-runner  | 
lab-f02-runner  | 표본 계좌 잔고 (조합원-7 실보유 12주, 조합원-50 실보유 55주):
lab-f02-runner  |  계좌 |   주주    | 잔고(주) 
lab-f02-runner  | ------+-----------+----------
lab-f02-runner  |     7 | 조합원-7  |    12012
lab-f02-runner  |    50 | 조합원-50 |    55055
lab-f02-runner  | 
lab-f02-runner  | 이어지는 매도 주문: 계좌 50(실보유 55주)이 유령주 50,000주 매도
lab-f02-runner  | BEGIN
lab-f02-runner  | UPDATE 1
lab-f02-runner  | COMMIT
lab-f02-runner  | 
lab-f02-runner  | 매도도 통과했다. 잔고 차감 후:
lab-f02-runner  |  계좌 |   주주    | 잔고(주) 
lab-f02-runner  | ------+-----------+----------
lab-f02-runner  |    50 | 조합원-50 |     5055
```

30.66이라는 배수는 시드 구성이 정한 값이지 사건의 규모를 재현한 값이 아니다. UPDATE가 닿는 조합원 999계좌의 합은 29,685주(발행총수의 3%)뿐이고 나머지 940,315주는 배치가 손대지 않는 기관 수탁 1계좌에 있다. 1,001배로 부푸는 것은 앞부분뿐이라 29,685 × 1,001 + 940,315 = 30,655,000이 그대로 나온다. 조합원 지분 비율을 바꾸면 배수도 바뀐다.

두 번째 CHECK 시도(`shares <= (SELECT issued_shares ...)`)는 문법에 걸리기 전에 이미 다른 규칙이다. 행 하나의 상한이지 합계의 상한이 아니다. 착오 배치 뒤에도 최대 행은 기관 수탁의 940,315주, 조합원 쪽 최대는 55,055주라 어느 행도 1,000,000주에 닿지 않으므로, Postgres가 받아 줬더라도 이 배치를 막지 못했다.

## 3. CHECK로는 이 불변식을 쓸 수 없다

```console
lab-f02-runner  | [3] CHECK 제약은 왜 못 막나: 교차행 불변식 표현 시도
lab-f02-runner  | 시도 1: 집계 함수를 CHECK에 넣기
lab-f02-runner  | psql:/sql/03-check-limitation.sql:5: ERROR:  aggregate functions are not allowed in check constraints
lab-f02-runner  | 
lab-f02-runner  | 시도 2: 서브쿼리로 company.issued_shares 참조하기
lab-f02-runner  | psql:/sql/03-check-limitation.sql:10: ERROR:  cannot use subquery in check constraint
```

## 4. 해소 1: 총량 검증 트리거가 같은 배치를 롤백시킨다

```console
lab-f02-runner  | [4] 해소 1: 총량 검증 트리거, 같은 착오 배치가 롤백된다
lab-f02-runner  | CREATE FUNCTION
lab-f02-runner  | CREATE TRIGGER
lab-f02-runner  | 
lab-f02-runner  | 같은 착오 배당 배치를 다시 실행:
lab-f02-runner  | BEGIN
lab-f02-runner  | psql:/sql/04-fix-trigger.sql:30: ERROR:  원장 불변식 위반: 잔고 합계 30655000주가 발행총수 1000000주를 초과
lab-f02-runner  | CONTEXT:  PL/pgSQL function assert_total_within_issued() line 9 at RAISE
lab-f02-runner  | ROLLBACK
lab-f02-runner  | 
lab-f02-runner  | 트랜잭션이 롤백됐다. 원장은 그대로다:
lab-f02-runner  |  발행총수(주) | 잔고 합계(주) | 합계/발행총수 
lab-f02-runner  | --------------+---------------+---------------
lab-f02-runner  |       1000000 |        970000 |          0.97
```

정상 배당(원 단위 현금 지급)은 통과하고, 잔고는 늘지 않는다.

```console
lab-f02-runner  | 정상 배당(주당 1,000원, 원 단위 현금 지급)은 통과한다:
lab-f02-runner  | BEGIN
lab-f02-runner  | UPDATE 999
lab-f02-runner  | COMMIT
lab-f02-runner  |  계좌 | 잔고(주) | 배당금(원) 
lab-f02-runner  | ------+----------+------------
lab-f02-runner  |     7 |       12 |      12000
lab-f02-runner  |    50 |       55 |      55000
```

착오 입고분 매도는 잔고 부족으로 거부된다. 롤백으로 잔고가 55주뿐이라 50,000주 차감이 음수 잔고 CHECK에 걸린다.

```console
lab-f02-runner  | 착오 입고분 매도 시도: 계좌 50(실보유 55주)이 50,000주 매도
lab-f02-runner  | psql:/sql/04-fix-trigger.sql:50: ERROR:  new row for relation "holdings" violates check constraint "holdings_shares_check"
lab-f02-runner  | DETAIL:  Failing row contains (50, 조합원-50, -49945, 55000).
lab-f02-runner  | 
lab-f02-runner  | 잔고 부족(음수 잔고 CHECK)으로 거부됐다. 계좌 50 잔고:
lab-f02-runner  |  계좌 | 잔고(주) 
lab-f02-runner  | ------+----------
lab-f02-runner  |    50 |       55
```

## 5. 동시 입고 경쟁 4라운드

잔고 합계 970,000주, 여유분 30,000주 상태에서 20,000주 대체입고 2건을 동시에 넣는다.
각각은 한도 안이고, 둘 다 커밋되면 10,000주 초과다.

라운드 1, 잠금 없는 트리거에 서로 다른 계좌 2건. 두 세션 모두 검증을 통과하고 커밋해 불변식이 깨진다.

```console
lab-f02-runner  | [5] 동시 입고 경쟁 (다른 계좌 2건, 잠금 없는 트리거)
lab-f02-runner  | [세션A] 계좌 101에 20,000주 대체입고, 검증 후 3초 뒤 커밋
lab-f02-runner  | BEGIN
lab-f02-runner  | UPDATE 1
lab-f02-runner  | COMMIT
lab-f02-runner  | [세션A] 커밋 완료
lab-f02-runner  | ------------------------------------------------------------------
lab-f02-runner  | [세션B] 계좌 202에 20,000주 대체입고, 검증 후 3초 뒤 커밋
lab-f02-runner  | BEGIN
lab-f02-runner  | UPDATE 1
lab-f02-runner  | COMMIT
lab-f02-runner  | [세션B] 커밋 완료
lab-f02-runner  | 두 세션 종료 후 원장:
lab-f02-runner  |  발행총수(주) | 잔고 합계(주) | 합계/발행총수 
lab-f02-runner  | --------------+---------------+---------------
lab-f02-runner  |       1000000 |       1010000 |          1.01
```

라운드 2, 같은 트리거에 같은 계좌 2건. 세션 B의 UPDATE가 행 잠금에 막혀 A의 커밋을 기다렸고, 풀려난 뒤의 검증이 합계 초과를 잡았다.

```console
lab-f02-runner  | [6] 같은 경쟁을 같은 계좌로 (잠금 없는 트리거)
lab-f02-runner  | [세션B] 계좌 101에 20,000주 대체입고 (A와 같은 계좌), 검증 후 3초 뒤 커밋
lab-f02-runner  | BEGIN
lab-f02-runner  | psql:/sql/race-same-b.sql:5: ERROR:  원장 불변식 위반: 잔고 합계 1010000주가 발행총수 1000000주를 초과
lab-f02-runner  | 두 세션 종료 후 원장:
lab-f02-runner  |  발행총수(주) | 잔고 합계(주) | 합계/발행총수 
lab-f02-runner  | --------------+---------------+---------------
lab-f02-runner  |       1000000 |        990000 |          0.99
```

라운드 3, advisory lock을 잡는 트리거에 서로 다른 계좌 2건. 세션 B는 A의 커밋까지 잠금에 매달렸다가 검증에서 거부됐다.

이 라운드가 성립하는 조건은 격리 수준이 아니라 검증 함수의 volatility다. VOLATILE 함수는 자기가 실행하는 질의마다 새 스냅숏을 잡으므로, 잠금 대기가 끝난 뒤의 `SUM(shares)`가 A가 커밋한 990,000주를 본다. 아래 오류 메시지의 1,010,000주가 그 증거다. `assert_total_within_issued()`는 volatility를 적지 않아 기본값 VOLATILE로 만들어져 있었고, STABLE이나 IMMUTABLE로 선언하면 호출한 질의의 스냅숏을 그대로 써서 잠금을 제대로 잡고도 낡은 합계를 읽는다. 오류 없이 조용히 통과하는 쪽이라 [sql/06-race-reset-lock.sql](sql/06-race-reset-lock.sql)에 `VOLATILE`을 명시하고 이유를 주석으로 남겼다. 04·05의 잠금 없는 버전에도 같은 이유로 명시했다. 명시는 기존 기본값과 같은 값이라 위 출력은 그대로다(수정 후 재실행해 psql 출력이 동일함을 확인했다). STABLE로 바꿔 실제로 뚫리는지 확인하는 라운드는 아직 실행 목록에 없다.

```console
lab-f02-runner  | [7] 해소 1 보강: advisory lock으로 총량 검증 직렬화 (다른 계좌 2건)
lab-f02-runner  | 재설정 완료. 검증 함수가 pg_advisory_xact_lock(20180406)을 먼저 잡는다.
lab-f02-runner  | [세션B] 계좌 202에 20,000주 대체입고, 검증 후 3초 뒤 커밋
lab-f02-runner  | BEGIN
lab-f02-runner  | psql:/sql/race-session-b.sql:4: ERROR:  원장 불변식 위반: 잔고 합계 1010000주가 발행총수 1000000주를 초과
lab-f02-runner  | 두 세션 종료 후 원장:
lab-f02-runner  |  발행총수(주) | 잔고 합계(주) | 합계/발행총수 
lab-f02-runner  | --------------+---------------+---------------
lab-f02-runner  |       1000000 |        990000 |          0.99
```

라운드 4, 잠금 없는 트리거로 되돌리고 두 세션만 SERIALIZABLE로 실행. UPDATE는 둘 다 통과하고, 늦게 커밋한 세션이 커밋 시점에 직렬화 오류로 중단됐다.

```console
lab-f02-runner  | [8] 대안: 잠금 없는 트리거 + SERIALIZABLE 격리 (다른 계좌 2건)
lab-f02-runner  | [직렬화B] 계좌 202에 20,000주 대체입고 (SERIALIZABLE), 검증 후 3초 뒤 커밋
lab-f02-runner  | BEGIN
lab-f02-runner  | UPDATE 1
lab-f02-runner  | psql:/sql/race-ser-b.sql:6: ERROR:  could not serialize access due to read/write dependencies among transactions
lab-f02-runner  | DETAIL:  Reason code: Canceled on identification as a pivot, during commit attempt.
lab-f02-runner  | HINT:  The transaction might succeed if retried.
lab-f02-runner  | 두 세션 종료 후 원장:
lab-f02-runner  |  발행총수(주) | 잔고 합계(주) | 합계/발행총수 
lab-f02-runner  | --------------+---------------+---------------
lab-f02-runner  |       1000000 |        990000 |          0.99
```

네 라운드는 각각 고정 타이밍 실행 한 번이다. 기동 간격 1초와 `pg_sleep(3)`으로 겹침을 만들어 둔 인터리빙 하나를 본 것이고, 전체 실행을 4회 반복해 같은 수치를 얻었지만 타이밍이 고정이라 본 인터리빙은 그대로 하나다. 방향에 따라 세기가 다르다. 라운드 1은 잠금 없는 트리거에 구멍이 있다는 존재 증명이라 반례 하나로 충분하다. 라운드 3·4는 advisory lock과 SERIALIZABLE에 구멍이 없다는 부재 주장이라 인터리빙 하나로는 증명되지 않는다. 이 로그가 보이는 것은 그 인터리빙에서 구멍이 재현되지 않았다는 사실까지다.

트리거의 범위도 적어 둔다. `AFTER INSERT OR UPDATE OF shares`는 증감을 구분하지 않아 매도 차감도 검증 함수와 advisory lock을 지난다. 증가분만 걸러내려면 행 단위 트리거의 `WHEN (NEW.shares > OLD.shares)`나 전이 테이블(`REFERENCING OLD TABLE ... NEW TABLE ...`)이 필요하다. 문장 단위 트리거의 WHEN은 컬럼 값을 참조할 수 없다. 둘 다 구현하지 않았고, 매도가 잠금 하나에 직렬화되는 비용도 재지 않았다.

## 6. 해소 2: maker-checker

발행총수의 1%(10,000주)를 넘는 단일 입고는 잔고에 반영하지 않고 승인 대기로 적재한다.

```console
lab-f02-runner  | [9] 해소 2: maker-checker, 발행총수 1% 초과 입고는 승인 대기
lab-f02-runner  | 착오 배당과 같은 대형 입고 요청: 계좌 50에 55,000주(배당금 55,000원의 단위 착오)
lab-f02-runner  |  PENDING: 55000주는 임계치 10000주(발행총수의 1%)를 초과, 승인 대기
lab-f02-runner  | 
lab-f02-runner  | 승인 전이므로 잔고는 그대로다:
lab-f02-runner  |  계좌 | 잔고(주) 
lab-f02-runner  | ------+----------
lab-f02-runner  |    50 |       55
lab-f02-runner  | 
lab-f02-runner  | 승인 전 매도 시도: 계좌 50이 50,000주 매도
lab-f02-runner  | psql:/sql/07-maker-checker.sql:68: ERROR:  new row for relation "holdings" violates check constraint "holdings_shares_check"
lab-f02-runner  | 
lab-f02-runner  | 입력자 본인이 승인 시도:
lab-f02-runner  | psql:/sql/07-maker-checker.sql:72: ERROR:  입력자(오퍼레이터A)와 승인자가 같을 수 없다
lab-f02-runner  | 
lab-f02-runner  | 검토자가 단위 착오를 확인하고 반려:
lab-f02-runner  |  REJECTED: credit 1 반려
lab-f02-runner  | 
lab-f02-runner  | 임계치 이하의 정상 입고(계좌 101에 5,000주 타사 대체입고)는 즉시 반영:
lab-f02-runner  |  APPLIED: 5000주 즉시 입고
lab-f02-runner  | 
lab-f02-runner  | 입고 대장:
lab-f02-runner  |  id | 계좌 | 수량(주) |  status  |   입력자    |       승인자       |           사유           
lab-f02-runner  | ----+------+----------+----------+-------------+--------------------+--------------------------
lab-f02-runner  |   1 |   50 |    55000 | REJECTED | 오퍼레이터A | 검토자B            | 우리사주 배당(단위 착오)
lab-f02-runner  |   2 |  101 |     5000 | APPLIED  | 오퍼레이터A | (임계치 이하 자동) | 타사 대체입고
```

## 7. 정리

```console
$ docker compose down
 Container lab-f02-runner Removed
 Container lab-f02-db Removed
 Network f02-samsung-ghost-shares_default Removed
```

## 측정값 요약

| 구분 | 잔고 합계(주) | 합계/발행총수 | 비고 |
|---|---|---|---|
| 초기 원장 | 970,000 | 0.97 | 계좌 1,000개, 발행총수 1,000,000주 |
| 버그: 착오 배치 커밋 후 | 30,655,000 | 30.66 | UPDATE 999 커밋 성공, 유령주 50,000주 매도도 통과. 배율은 시드 구성이 정한 값 |
| 해소 1: 트리거 롤백 후 | 970,000 | 0.97 | 같은 배치가 ERROR 후 ROLLBACK. 매도 거부는 롤백된 잔고 55주에 기존 음수 잔고 CHECK가 걸린 것이라 트리거의 성과가 아님 |
| 경쟁 R1: 잠금 없음, 다른 계좌 | 1,010,000 | 1.01 | 두 세션 모두 커밋, 불변식 깨짐. 고정 타이밍 1회 |
| 경쟁 R2: 잠금 없음, 같은 계좌 | 990,000 | 0.99 | 행 잠금이 직렬화, B 거부. 고정 타이밍 1회 |
| 경쟁 R3: advisory lock | 990,000 | 0.99 | B가 잠금 대기 후 검증에서 거부. 함수가 VOLATILE이라 성립. 고정 타이밍 1회 |
| 경쟁 R4: SERIALIZABLE | 990,000 | 0.99 | B가 커밋 시점 직렬화 오류, 재시도 힌트. 고정 타이밍 1회 |
| 해소 2: maker-checker | 975,000 | 0.98 | 55,000주는 PENDING 후 반려, 5,000주는 즉시 반영 |
