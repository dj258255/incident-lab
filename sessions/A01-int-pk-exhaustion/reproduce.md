# A01 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| MySQL | 8.4.3 (컨테이너, cpus 4 / mem 2g, 버퍼 풀 1GB) |
| 데이터 | 300만 행 × 2벌 (약 170MB), INT AUTO_INCREMENT PK |
| 동시 부하 | Python 단일 커넥션, 초당 약 100건 INSERT, 건별 지연 실시간 기록 |
| 일시 | 2026-07-29 |

## 실행

```console
$ docker compose up -d
$ ./scripts/exp1-exhaust.sh    # 상한 도달, 약 5초
$ ./scripts/exp2-migrate.sh    # 무중단 전환 비교, 약 6분
$ python3 scripts/report.py
```

## 실험 1: 상한 도달 (results/exp1.txt)

```console
$ SELECT ~0 >> 33 AS int_max;
2147483647

$ ALTER TABLE sponsor_int AUTO_INCREMENT = 2147483646;

[1번째] INSERT  → 성공. id = 2147483646
[2번째] INSERT  → 성공. id = 2147483647
[3번째] INSERT  → ERROR 1062 (23000) at line 1:
                  Duplicate entry '2147483647' for key 'sponsor_int.PRIMARY'

$ SELECT COUNT(*) FROM sponsor_int;
2
```

행 2개짜리 테이블에서 중복 키 에러가 납니다. 카운터가 상한에 닿아 같은 값을 계속 내주기 때문입니다.

## 실험 2: 전환 (results/exp2.txt)

### 방법 A. 한 방 ALTER

```console
$ ALTER TABLE sponsor_a MODIFY id BIGINT AUTO_INCREMENT, ALGORITHM=INPLACE, LOCK=NONE;
ERROR 1846 (0A000): ALGORITHM=INPLACE is not supported.
Reason: Cannot change column type INPLACE. Try ALGORITHM=COPY.

$ ALTER TABLE sponsor_a MODIFY id BIGINT AUTO_INCREMENT, ALGORITHM=COPY;
소요 12.774초
전환 중 쓰기 11건 · 성공 11 · 실패 0
성공한 쓰기의 p95 12602.0ms · 최대 12602ms
```

### 방법 B. expand-contract

```console
1단계 expand: ADD COLUMN id_new BIGINT NULL (INPLACE, LOCK=NONE)
    소요 5.274초
2단계 backfill: UPDATE ... WHERE id_new IS NULL LIMIT 20000 반복
    청크 151회, 소요 112.560초
    남은 NULL 6건 (백필 중 들어온 새 행)
3단계 잔여 백필
    소요 1.094초
전체 소요 119.420초
전환 중 쓰기 8,427건 · 성공 8,427 · 실패 0
성공한 쓰기의 p95 3.8ms · 최대 49ms
```

## 집계 (scripts/report.py)

```console
방법                           소요      통과한 쓰기     실패        p95         최대
한 방 ALTER (COPY)          12.8초          12      0  12602.0ms    12602ms
expand-contract          119.4초       8,427      0      3.8ms       49ms
```

## 원문 파일 위치

| 내용 | 경로 |
|---|---|
| 상한 도달 로그 | `results/exp1.txt` |
| 전환 비교 로그 | `results/exp2.txt` |
| 건별 INSERT 지연 | `results/writer-a.csv`, `results/writer-b.csv` |
| 차트·증거 카드 | `results/chart-migration.png`, `results/fig-1062.png` |
