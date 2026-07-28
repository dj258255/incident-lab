# A18 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| PostgreSQL | 17.5 (컨테이너), shared_buffers 1GB, wal_compression=off |
| 데이터 | 동일 스키마 테이블 6개 x 50만 행 (인덱스 0·3·6·10 x fillfactor 100·70) |
| 일시 | 2026-07-29 |

## 실행

```console
$ docker compose up -d
$ ./scripts/run-experiments.sh     # 적재 + 7개 변형 측정, 약 5분
$ python3 scripts/report.py
```

측정 원문은 `results/measure.csv` (변형별 WAL 바이트, 소요 초, pg_stat 전후값).

## 측정 방법

변형마다 다음 순서로 잽니다.

```sql
CHECKPOINT;                              -- full-page image 부담을 같은 조건으로
SELECT pg_current_wal_lsn();             -- lsn0
UPDATE <table> SET <col> = <col> + 1;    -- 50만 행 전체
SELECT pg_current_wal_lsn();             -- lsn1
SELECT pg_wal_lsn_diff(lsn1, lsn0);      -- WAL 증가량
-- HOT 비율은 pg_stat_user_tables.n_tup_hot_upd 전후 차이
```

## 결과 (results/measure.csv 집계)

```console
변형                                  WAL(MB)   소요(초)   HOT 비율
인덱스 0 · 꽉 찬 페이지                     267      1.6      0.0%
인덱스 3 · 꽉 찬 페이지                     364      3.5      0.0%
인덱스 6 · 꽉 찬 페이지                     462      5.3      0.0%
인덱스 10 · 꽉 찬 페이지                    595      8.5      0.0%
인덱스 0 · 여유 공간(ff70)                  210      1.2     45.2%
인덱스 10 · 여유 공간(ff70)                 419      5.8     45.2%
인덱스 10 · ff70 · 인덱스 컬럼 갱신           651     10.3      0.0%
인덱스 10 · ff70 · 2차 갱신(정상 상태)        249      2.0     83.5%
인덱스 0 · ff70 · 2차 갱신(정상 상태)         176      1.0     69.9%
```

## 쿼리 단위 증거 (results/02-explain-wal.txt)

```console
-- 인덱스 10개(ff100), 1만 행 갱신
Update on t10  (actual time=192.693..192.693)
  WAL: records=132851 fpi=1434 bytes=17683522

-- 인덱스 0개(ff100), 같은 갱신
Update on t0   (actual time=23.195..23.196)
  WAL: records=30017 fpi=224 bytes=5245672
```
