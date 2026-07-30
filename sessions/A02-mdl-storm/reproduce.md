# 재현 기록

실행한 명령과 출력을 그대로 붙입니다. 도커 컴포즈가 찍는 컨테이너 생성 줄은 `grep -v`로
걷어냈고, 그 경우 명령줄에 남겼습니다.

## 1. 환경 기동과 적재

```console
$ cd sessions/A02-mdl-storm
$ docker compose build load
 Image a02-load  Built

$ docker compose up -d --wait mysql
 Container a02-mysql  Healthy

$ docker compose run --rm load python seed.py
  1,300,000행 (130초)
  1,800,000행 (140초)
  2,000,000행 (144초)
테이블 280MB, 총 145초
```

버퍼 풀 1GB에 테이블 280MB이므로 조회는 메모리에서 끝납니다. 정지가 디스크 때문이 아니라는
것을 확실히 해 두는 조건입니다.

## 2. 네 조건

```console
$ for c in control ddl-default ddl-timeout ddl-alone; do
    docker compose run --rm load python mdl.py --case $c --out /results/case-$c.json
  done
=============== control ===============
[control] MySQL 8.4.3, 행 2,000,000, 기본 lock_wait_timeout 31536000초
  [ 15.0초] 롱 트랜잭션: BEGIN 후 SELECT 실행, 커밋하지 않음
  [ 45.0초] 롱 트랜잭션: 커밋
  평시 초당 3464건, 정지된 초 0개 []
=============== ddl-default ===============
[ddl-default] MySQL 8.4.3, 행 2,000,000, 기본 lock_wait_timeout 31536000초
  [ 15.0초] 롱 트랜잭션: BEGIN 후 SELECT 실행, 커밋하지 않음
  [ 25.0초] DDL: 실행 시작 (lock_wait_timeout=31536000) ALTER TABLE orders ADD COLUMN memo VARCHAR(64) NULL
  [ 45.0초] 롱 트랜잭션: 커밋
  [ 45.1초] DDL: 성공, 20.09초 걸림
  평시 초당 2462건, 정지된 초 20개 [25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44]
=============== ddl-timeout ===============
[ddl-timeout] MySQL 8.4.3, 행 2,000,000, 기본 lock_wait_timeout 31536000초
  [ 15.0초] 롱 트랜잭션: BEGIN 후 SELECT 실행, 커밋하지 않음
  [ 25.0초] DDL: lock_wait_timeout=2초로 설정
  [ 25.0초] DDL: 실행 시작 (lock_wait_timeout=2) ALTER TABLE orders ADD COLUMN memo VARCHAR(64) NULL
  [ 27.0초] DDL: 실패, 2.02초 뒤 (1205, 'Lock wait timeout exceeded; try restarting transaction')
  [ 45.0초] 롱 트랜잭션: 커밋
  평시 초당 3576건, 정지된 초 2개 [25, 26]
=============== ddl-alone ===============
[ddl-alone] MySQL 8.4.3, 행 2,000,000, 기본 lock_wait_timeout 31536000초
  [ 25.0초] DDL: 실행 시작 (lock_wait_timeout=31536000) ALTER TABLE orders ADD COLUMN memo VARCHAR(64) NULL
  [ 25.1초] DDL: 성공, 0.09초 걸림
  평시 초당 3658건, 정지된 초 0개 []
```

기본 `lock_wait_timeout`이 31,536,000초로 찍힙니다. 1년입니다.

## 3. 집계 코드를 고친 경위

첫 실행에서 겹침 조건이 "정지된 초 1개"로 나왔습니다. 타임라인을 직접 보니 이랬습니다.

```console
$ python3 -c "..."   # case-ddl-default.json의 timeline 출력
sec  건수    p50      p99      max
 24   3180     0.34     5.73     69.86
 25    302     0.50    11.82     22.92
 45   1711     0.38     7.37  19951.52
 46   2216     0.37     5.21      9.17
```

25초 다음이 45초입니다. 26초부터 44초까지 완료된 조회가 한 건도 없어서 그 초의 버킷이
만들어지지 않았고, 있는 버킷만 훑던 집계가 정지 구간을 통째로 건너뛰었습니다.

0초부터 끝까지 모든 초를 만들고 빈 초를 0건으로 채우도록 고친 뒤 다시 돌린 것이 위 2절의
출력입니다. 정지 20초가 그제서야 잡혔습니다.

## 4. 대기 큐 확인

`performance_schema.metadata_locks`를 1초 간격으로 훑은 기록에서 겹침 조건의 25.1초
스냅샷입니다.

```console
$ python3 -c "..."   # case-ddl-default.json의 lock_snapshots 출력
   25.1초 granted 2 pending 3  ['EXCLUSIVE:PENDING', 'SHARED_READ:GRANTED', 'SHARED_READ:PENDING', 'SHARED_UPGRADABLE:GRANTED']
```

`SHARED_READ:GRANTED`가 롱 트랜잭션, `SHARED_UPGRADABLE:GRANTED`와 `EXCLUSIVE:PENDING`이
DDL, `SHARED_READ:PENDING`이 일반 조회입니다.

## 5. 리포트와 그림 생성

```console
$ python3 scripts/report.py
================================================================================
A02 메타데이터 락 폭풍   (MySQL 8.4.3, 2,000,000행, 조회 프로세스 2개, 60초)
일정: 15초 롱 트랜잭션 시작, 25초 DDL 실행, 45초 롱 트랜잭션 커밋
================================================================================

                        조건     평시 초당     전면 정지       최대 지연                DDL 결과
--------------------------------------------------------------------------------
          롱 트랜잭션만 (DDL 없음)    3,464건        0초       183ms                실행 안 함
          DDL만 (롱 트랜잭션 없음)    3,658건        0초       139ms             성공, 0.09초
 겹침 + lock_wait_timeout 2초    3,576건        2초     2,005ms       실패(1205), 2.02초
              겹침 + 기본 타임아웃    2,462건       20초    20,021ms            성공, 20.09초

메타데이터 락 (performance_schema.metadata_locks, 정지 구간)
--------------------------------------------------------------------------------
          롱 트랜잭션만 (DDL 없음)  대기 중인 락 없음
          DDL만 (롱 트랜잭션 없음)  대기 중인 락 없음
 겹침 + lock_wait_timeout 2초  25.1초  granted 2 / pending 3
                              EXCLUSIVE:PENDING
                              SHARED_READ:GRANTED
                              SHARED_READ:PENDING
                              SHARED_UPGRADABLE:GRANTED
              겹침 + 기본 타임아웃  25.1초  granted 2 / pending 3
                              EXCLUSIVE:PENDING
                              SHARED_READ:GRANTED
                              SHARED_READ:PENDING
                              SHARED_UPGRADABLE:GRANTED

render.json 작성: 이미지 4장
```

> 위 출력의 "평시 초당" 열은 그 뒤로 이름이 바뀌었습니다. 이 값은 `mdl.py`가 `sec < ddl_at`,
> 곧 0초부터 24초까지에서 잡는 중앙값이고 네 조건 모두 개입 이전 구간이라, 조건 사이의 차이는
> 설정의 효과가 아니라 실행 간 편차입니다. 지금 `report.py`는 열 이름을 "DDL 전 초당"으로
> 부르고 그 주의 문구와 "0건인 초" 열을 함께 찍습니다. 실행 출력은 그때 찍힌 그대로 두었습니다.

그림은 저장소 루트에서 만듭니다.

```console
$ docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/work incident-lab-render \
    sessions/A02-mdl-storm/results
생성: sessions/A02-mdl-storm/results/00-timeline.png  1544x1471
생성: sessions/A02-mdl-storm/results/01-stall.png  940x560
생성: sessions/A02-mdl-storm/results/02-latency.png  940x560
생성: sessions/A02-mdl-storm/results/03-ddl.png  940x560
```

## 6. 정리

```console
$ docker compose down -v
```

## 커넥션 풀 캐스케이드 실험 (results/cascade-*.json)

```console
$ docker compose run --rm load python seed.py            # 200만 행, 약 30초
$ for c in control ddl ddl-write; do
    docker compose run --rm load python cascade.py --case $c --out /results/cascade-$c.json
  done                                                   # 조건마다 20초
```

풀 크기 10, 획득 타임아웃 2초, 엔드포인트마다 초당 20건입니다. `/other` 테이블은 스크립트가
매 실행마다 `orders` 에서 10만 행을 복사해 만듭니다.

`ALTER TABLE orders ADD COLUMN cascade_probe` 를 DDL 로 쓰고, 다음 실행 시작 때 그 컬럼이
남아 있으면 지웁니다. 그러지 않으면 두 번째 실행에서 중복 컬럼 에러로 DDL 이 즉시 실패해
대기가 만들어지지 않습니다.

