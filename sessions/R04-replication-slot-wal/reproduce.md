# R04 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| 호스트 | macOS 26.3.1, Apple M2 Pro, 12코어(논리), 32GB (`results/env.txt`) |
| DB | PostgreSQL 17.5 (Debian 17.5-1.pgdg130+1), 컨테이너 cpus 4 / mem 2g |
| 설정 | wal_level=logical, max_wal_size=256MB, min_wal_size=64MB, checkpoint_timeout=30s |
| 일시 | 2026-07-29 |

## 실행

```console
$ docker compose up -d
$ ./scripts/run.sh              # 실험 1 (슬롯 방치), 약 4분
$ ./scripts/exp2-keepsize.sh    # 실험 2 (안전장치), 약 1분
$ python3 scripts/report.py
```

## 실험 1: 컨슈머를 죽이고 슬롯을 방치 (results/timeline.txt)

```console
[20:02:49] 쓰기 시작 (0.2초마다 200행, 행당 약 1KB)
[20:03:19] 논리 복제 슬롯 생성 + pg_recvlogical 시작
  (cdc_slot,0/37322E0)
[20:03:21] 컨슈머 상태 active=t
[20:03:51] 컨슈머 강제 종료
[20:03:53] 슬롯 상태 active=f (슬롯은 남아 있다)
[20:05:53] 현재 WAL 128 MB, 파일 8개
[20:05:53] 슬롯 지연 127 MB
 slot_name | active | wal_status |  lag
 cdc_slot  | f      | reserved   | 127 MB
[20:05:53] 조치: 슬롯 삭제 후 체크포인트
[20:06:02] 삭제 후 WAL 96 MB, 파일 6개
```

1초 시계열(`results/metrics.csv`) 발췌:

```console
  경과       WAL    파일       슬롯지연  active        행수
     0       16M     1       0.0M       f       400
    30       48M     3       0.2M       t    26,200
    52       64M     4       6.3M       t    44,800
    63       80M     5       7.0M       f    54,800     <- 컨슈머 사망
   103       80M     5      47.1M       f    89,800
   155      112M     7      97.5M       f   134,000
   172      128M     8     114.5M       f   149,000
   189       96M     6       0.0M       f   163,800     <- 슬롯 삭제 후
```

## 실험 2: max_slot_wal_keep_size = 64MB (results/exp2.txt)

```console
[20:07:40] 현재값 64MB
[20:07:41] 슬롯 생성. 컨슈머는 붙이지 않는다
  t=1s   WAL  80MB  슬롯지연   0MB  상태 reserved    여유  70MB
  t=10s  WAL  96MB  슬롯지연  73MB  상태 unreserved  여유  -1MB
  t=19s  WAL 128MB                  상태 lost        여유   0MB

 slot_name | active | wal_status | lag | safe_wal
 cdc_slot  | f      | lost       |     |

무효화된 슬롯에 컨슈머를 다시 붙이면:
  pg_recvlogical: error: could not send replication command
  "START_REPLICATION SLOT "cdc_slot" LOGICAL 0/0":
  ERROR:  can no longer get changes from replication slot "cdc_slot"
  DETAIL:  This slot has been invalidated because it exceeded the maximum reserved size.
```

## 원문 파일 위치

| 내용 | 경로 |
|---|---|
| 타임라인 | `results/timeline.txt`, `results/exp2.txt` |
| 1초 시계열 | `results/metrics.csv`, `results/keepsize.csv` |
| 호스트·버전 | `results/env.txt` |
| 차트·증거 카드 | `results/chart-wal.png`, `results/fig-lost.png` |
