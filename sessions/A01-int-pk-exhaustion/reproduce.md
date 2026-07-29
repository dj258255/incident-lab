# A01 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| 호스트 | 기록하지 않았습니다 |
| MySQL | 8.4.3 (컨테이너 `cpus: 4`, `mem_limit: 2g`, 버퍼 풀 1GB, `innodb_flush_log_at_trx_commit=1`, `log-bin`) |
| 데이터 | 실험 1은 행 2개, 실험 2는 300만 행 × 2벌 (sponsor_a 167MB). 둘 다 INT AUTO_INCREMENT PK |
| 동시 부하 | Python 단일 커넥션, INSERT 사이 10ms 대기. 전환 직전 5초 실측 초당 62~67건 |
| 측정 | 방법별 1회. 반복 측정하지 않았으므로 관측 범위가 없습니다 |
| 일시 | 2026-07-29 |

호스트 사양을 찍어 남기지 않았습니다. `uname -srm`, `nproc`, `free -g` 어느 것도 실행하지
않아 어느 장비였는지 확인되지 않습니다. 다만 사양을 몰라도 하나는 확정할 수 있습니다.
`compose.yml`의 `cpus: 4`는 코어가 4개 미만인 호스트에서 컨테이너를 띄우지 못하게 하므로,
이 저장소가 사양을 남긴 2코어 리눅스 서버는 아닙니다(A22 재측정 때 같은 값에서
`range of CPUs is from 0.01 to 2.00`으로 기동이 막힌 기록이 있습니다). 그 이상은 추정입니다.
이 세션의 절대 시간을 다른 세션의 절대 시간과 이어 붙여 읽으면 안 됩니다.

동시 부하를 "초당 약 100건"으로 적어 두었다가 고쳤습니다. `exp2-migrate.sh`의 writer는
INSERT 하나를 던지고 `time.sleep(0.01)` 하는 단일 커넥션이라 설정상 상한이 초당 100건인데,
왕복 시간이 붙어 실측은 그보다 낮습니다. 위 62~67건은 `report.py`가 전환 시작 직전 5초의
CSV 기록에서 센 값입니다. 설정값이 아니라 이 실측값이 기준선입니다.

## 실행

```console
$ docker compose up -d
$ ./scripts/exp1-exhaust.sh    # 상한 도달, 약 5초
$ ./scripts/exp2-migrate.sh    # 무중단 전환 비교, 약 6분

$ docker run --rm -u $(id -u):$(id -g) -v "$PWD/../..":/work \
    -w /work/sessions/A01-int-pk-exhaustion \
    incident-lab-plot python scripts/report.py        # chart-migration.png

$ docker run --rm -u $(id -u):$(id -g) -v "$PWD/../..":/work \
    incident-lab-render sessions/A01-int-pk-exhaustion/results   # fig-1062.png
```

`exp1-exhaust.sh`는 `docker exec`로 mysql 클라이언트만 부르므로 호스트에 따로 깔 것이 없습니다.
`exp2-migrate.sh`는 적재와 부하 생성에 `../../.venv/bin/python`을 쓰므로 그 가상환경에 `pymysql`이 있어야 합니다.
그림 두 장은 호스트에 matplotlib과 한글 폰트를 깔지 않고 저장소 공용 이미지로 만듭니다.
`incident-lab-plot`이 `scripts/report.py`를 돌려 차트를, `incident-lab-render`가
`results/render.json`을 읽어 증거 카드를 냅니다.

## 실험 1: 상한 도달

`results/exp1.txt` 전문입니다. 줄을 줄이거나 고치지 않았습니다.

```console
$ SELECT ~0 >> 33 AS int_max;      # signed INT 상한
  2147483647

행을 21억 개 넣지 않는다. 카운터만 상한 직전으로 민다.
데이터 양이 아니라 AUTO_INCREMENT 값이 문제라는 것이 이 사고의 핵심이다.
삭제를 반복해 행은 적은데 카운터만 올라간 테이블도 똑같이 터진다.

$ ALTER TABLE sponsor_int AUTO_INCREMENT = 2147483646;
  현재 카운터 2147483646

후원 세 건을 넣어 본다.

  [1번째] INSERT
    성공. id = 2147483646

  [2번째] INSERT
    성공. id = 2147483647

  [3번째] INSERT
    ERROR 1062 (23000) at line 1: Duplicate entry '2147483647' for key 'sponsor_int.PRIMARY'

상한에 닿으면 INSERT가 에러로 거부된다. 서비스로 치면 쓰기 전면 중단이다.
Basecamp가 2018년에 이 상태로 5시간 동안 쓰기를 받지 못했다.

$ SELECT COUNT(*) FROM sponsor_int;   # 행은 두 개뿐인데
  2
  행 수와 무관하게 카운터가 상한이라 더 넣을 수 없다.
```

행 2개짜리 테이블에서 중복 키 에러가 납니다. 카운터가 상한에 닿아 같은 값을 계속 내주기 때문입니다.

이어서 같은 파일이 행 2개짜리 테이블에서 타입 변경이 얼마나 빠른지도 남깁니다.

```console
$ ALTER TABLE sponsor_int MODIFY id BIGINT AUTO_INCREMENT;
  소요 .082110000초 (행 2개짜리 테이블)

$ INSERT INTO sponsor_int (user_id, amount) VALUES (100, 1000);
  성공. id = 2147483648
```

이 0.08초는 행이 둘일 때의 값입니다. 실험 2가 재는 것은 같은 문장을 300만 행에 던질 때입니다.

## 실험 2: 전환

`results/exp2.txt`에서 두 방법 블록을 그대로 옮겼습니다.

### 방법 A. 한 방 ALTER

```console
방법 A. ALTER TABLE ... MODIFY id BIGINT (한 방)
  적재 3000000행, 167MB
  먼저 온라인으로 시도한다
    ERROR 1846 (0A000) at line 1: ALGORITHM=INPLACE is not supported. Reason: Cannot change column type INPLACE. Try ALGORITHM=COPY.
  엔진이 거부한다. 타입 변경은 테이블을 다시 만들어야 하므로 COPY만 가능하다.
  COPY로 실행한다
  소요 12.774395000초
  전환 중 쓰기 11건 · 성공 11 · 실패 0
  성공한 쓰기의 p95 12602.0ms · 최대 12602ms
```

### 방법 B. expand-contract

```console
방법 B. expand-contract 3단계
  적재 3000000행

  1단계 expand: BIGINT 신규 컬럼 추가
    소요 5.273829000초
  2단계 backfill: 기존 행을 청크로 채운다
    청크 151회, 소요 112.560399000초
    남은 NULL 6건 (백필 중 들어온 새 행)
  3단계 잔여 백필: 백필 중에 들어온 새 행을 마저 채운다
    소요 1.094026000초
    (실제 전환은 여기서 애플리케이션이 두 컬럼을 함께 쓰도록 배포한 뒤
     컬럼명을 교체한다. 이 실험은 DB 쪽 작업만 잰다)
  전체 소요 119.419805000초
  전환 중 쓰기 8,427건 · 성공 8,427 · 실패 0
  성공한 쓰기의 p95 3.8ms · 최대 49ms
```

`bc`가 찍은 소수점 아홉 자리는 유효숫자가 아닙니다. 아래 집계와 README는 소수점 한 자리로 줄여 씁니다.

`exp2.txt`의 마지막 줄은 "판단 기준은 소요 시간이 아니라 전환 중 쓰기 실패 건수다"입니다.
측정 전에 세운 가설이 스크립트에 박혀 그대로 출력된 것이고, 이 실행이 그 가설을 반증했습니다.
양쪽 다 실패 0건이라 그 기준으로는 두 방법이 갈리지 않습니다. 실행 출력이므로 손대지 않고
그대로 두었습니다.

## 집계 (scripts/report.py)

```console
방법                           소요      통과한 쓰기       초당     실패        p95         최대
-----------------------------------------------------------------------------------
한 방 ALTER (COPY)          12.8초          11     0.9건      0  12602.0ms    12602ms
expand-contract          119.4초       8,427    70.6건      0      3.8ms       49ms
-----------------------------------------------------------------------------------
전환 직전 5초 기준선: 한 방 ALTER (COPY) 66.5건/초 · expand-contract 61.7건/초
표본이 20건 미만이면 exp2-migrate.sh가 p95 대신 최댓값을 씁니다. 방법 A의 p95는 최댓값입니다.
```

건수 두 개를 나란히 놓고 읽으면 안 됩니다. 관측 창이 12.8초와 119.4초로 다르기 때문에
11건과 8,427건은 같은 축의 값이 아닙니다. 같은 축으로 놓은 것이 `초당` 열이고,
전환 직전 기준선과 견주면 방법 A는 66.5건에서 0.9건으로 떨어졌고
방법 B는 61.7건에서 70.6건으로 떨어지지 않았습니다.

방법 A의 `p95` 12,602.0ms는 백분위수가 아닙니다. 표본이 11건이라 `exp2-migrate.sh`의
`summarize()`가 20건 미만일 때 최댓값으로 대체합니다. 그래서 p95 열과 최대 열이 같은 값입니다.
창 안 11건의 응답 시간은 14.2 / 2.2 / 3.1 / 3.4 / 4.4 / 2.5 / 2.2 / 2.4 / 2.5 / 12602.0 / 1.8ms이고,
느린 것은 열째 한 건뿐입니다.

## 원문 파일 위치

| 내용 | 경로 |
|---|---|
| 상한 도달 로그 | `results/exp1.txt` |
| 전환 비교 로그 | `results/exp2.txt` |
| 건별 INSERT 지연 | `results/writer-a.csv`, `results/writer-b.csv` |
| 차트·증거 카드 | `results/chart-migration.png`, `results/fig-1062.png` |
