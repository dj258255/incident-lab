# R12 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| MySQL | 8.4.3 (컨테이너, cpus 4 / mem 2g, **버퍼 풀 256MB**) |
| 데이터 | small 10만 행(캐시에 다 들어감), hotrow 1행, big 400만 행 약 1.1GB |
| 샘플러 | Python, 1초·0.1초 두 간격 병행 |
| 일시 | 2026-07-29 |

## 실행

```console
$ docker compose up -d
$ ./scripts/run-experiments.sh          # 적재 + 함정 재현 + 3구간 워크로드, 약 12분
$ python3 scripts/lock-probe.py results/lock-probe.csv    # 보강 실험, 1분
$ python3 scripts/report.py
```

## 1. 계측 꺼짐 함정 (results/01-default-instruments.txt)

```console
-- 8.4 기본 상태: wait/io/file·wait/synch 계측 ENABLED=NO
-- 락에 막힌 세션 2개를 샘플링:
ts, active, cpu, io_file, io_table, lock, synch, other
...,     2,   2,       0,        0,    0,     0,     0     ← 전부 CPU로 보임

-- setup_instruments·setup_consumers에서 wait/% 활성화 후 같은 상황:
...,     2,   0,       0,        1,    0,     1,     0     ← 대기가 드러남
```

## 2. 3구간 분해 (results/pi-1s.csv, chart-pi-1s.png)

```console
[pi-1s.csv] 구간별 평균 활성 세션 (AAS) 분해
구간                    CPU    IO(파일)  IO(테이블)   락
1: CPU 점조회          0.33      0.00      0.08     0.00
2: 핫 로우 UPDATE      0.30      0.72      6.50     0.00   ← 행 락이 io_table로 나타남
3: 콜드 IO 조회        0.35      0.02      1.53     0.00

[pi-100ms.csv] 0.1초 샘플링도 동일 구조 (0.28 / 6.47 / 1.59)
```

## 3. 보강: io/table이 락인지 IO인지 (results/lock-probe.csv)

```console
핫 로우 UPDATE: io/table 세션 평균 6.5, data_lock_waits 평균 25.2
콜드 IO 조회:   io/table 세션 평균 1.1, data_lock_waits 평균  0.9
```

## 원문 파일 위치

| 내용 | 경로 |
|---|---|
| 1초·0.1초 샘플 원본 | `results/pi-1s.csv`, `results/pi-100ms.csv` |
| 계측 전·후 샘플 | `results/blind-sample.csv`, `results/sighted-sample.csv` |
| 락 판별 프로브 | `results/lock-probe.csv` |
| 실험 로그 | `results/experiments.log` |
