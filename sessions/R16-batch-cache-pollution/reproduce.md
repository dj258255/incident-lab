# R16 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| 호스트 | macOS 26.3.1, Apple M2 Pro, 12코어(논리), 32GB, NVMe |
| MySQL | 8.4.3 (컨테이너, cpus 4 / mem 2g, 버퍼 풀 1GB) |
| Python | 3.14 + PyMySQL |
| 일시 | 2026-07-29 |

## 1. 기동과 적재

```console
$ docker compose up -d
$ python3 scripts/seed.py        # 핫 150만 행 + 콜드 800만 행, 약 19분

orders_hot: 388MB
settlement_history: 2056MB       # 버퍼 풀 1GB의 2배
```

## 2. 실험

```console
$ ./scripts/run-experiments.sh   # 단발 스캔 3조건, 약 13분
$ ./scripts/exp-sustained.sh     # 60초 지속 스캔 2조건, 약 9분
```

각 조건: 점조회(스레드 8) 240초, 60초 지점에 콜드 테이블 풀 스캔 집계 시작.
사전 상태 확인 원문(`results/pre-state.txt`):

```console
bp_gb            @@innodb_old_blocks_pct   @@innodb_old_blocks_time
1.125000000000   37                        1000
```

## 3. 집계

```console
$ python3 scripts/report.py

조건                           배치 전 p95   배치 중 p95   배치 후 p95   히트율 최저
방어 꺼짐 · 단발 스캔            2.70ms      2.80ms      2.63ms      12.4%
기본값 · 단발 스캔              2.65ms      2.99ms      2.59ms      10.2%
배치 없음 (대조군)              2.65ms      2.61ms      2.57ms      89.5%
방어 꺼짐 · 60초 지속 스캔       2.63ms      2.81ms      2.60ms       7.2%
기본값 · 60초 지속 스캔          2.65ms      2.94ms      2.75ms       9.1%
```

스캔 종료 후 히트율 99% 회복 시간(1초 시계열 `*-bp.csv`에서 계산):

```console
defense-off        13.7초
default             1.6초
sustained-off      15.2초
sustained-default   0.7초
```

## 원문 파일 위치

| 내용 | 경로 |
|---|---|
| 건별 점조회 지연 | `results/*-lat.csv` |
| 버퍼 풀 지표 1초 시계열 (HIT_RATE, young/old 승격) | `results/*-bp.csv` |
| 배치 시작·종료 시각 | `results/*-batch-start.txt`, `*-batch-done.txt` |
| 실험 로그 | `results/experiments.log`, `results/sustained.log` |
