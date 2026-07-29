# R04 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| 호스트 | macOS 26.3.1, Apple M2 Pro, 12코어(논리), 32GB (`results/env.txt`) |
| DB | PostgreSQL 17.5 (Debian 17.5-1.pgdg130+1), 컨테이너 cpus 4 / mem 2g |
| 설정 | wal_level=logical, max_wal_size=256MB, min_wal_size=64MB, checkpoint_timeout=30s |
| 일시 | 2026-07-29 |
| 반복 | 실험 1과 실험 2 각각 1회 실행 |

## 실행

```console
$ docker compose up -d
$ ./scripts/run.sh              # 실험 1 (슬롯 방치), 약 4분
$ ./scripts/exp2-keepsize.sh    # 실험 2 (안전장치), 약 1분
$ python3 scripts/report.py
```

## 실험 1: 컨슈머를 죽이고 슬롯을 방치 (results/timeline.txt)

`results/timeline.txt` 전문입니다. 편집하지 않았습니다.

```console
[20:02:49] 쓰기 시작 (초당 약 1,000행, 행당 1KB)
[20:03:19] 논리 복제 슬롯 생성 + pg_recvlogical 시작
  (cdc_slot,0/37322E0)
[20:03:21] 컨슈머 상태 active=t
[20:03:51] 컨슈머 강제 종료 (CDC 파이프라인이 죽은 상황)
[20:03:53] 슬롯 상태 active=f (슬롯은 남아 있다)
[20:03:53] 쓰기를 120초 더 계속한다
[20:05:53] 현재 WAL 128 MB, 파일 8개
[20:05:53] 슬롯 지연 127 MB
 slot_name | active | wal_status |  lag
-----------+--------+------------+--------
 cdc_slot  | f      | reserved   | 127 MB
(1 row)

[20:05:53] 조치: 슬롯 삭제 후 체크포인트
[20:06:02] 삭제 후 WAL 96 MB, 파일 6개
[20:06:20] 측정 종료
```

이 출력에서 그대로 읽으면 안 되는 값이 둘 있습니다.

- **"초당 약 1,000행"은 루프의 목표치이고 실측이 아닙니다.** 200행 INSERT 뒤 0.2초를 쉬는 루프라 목표는 초당 1,000행이지만, psql을 매번 새로 띄우는 비용이 붙습니다. 같은 실행의 `results/metrics.csv`로 다시 재면 **859.6행/초**(구간별 400~1,000, 중앙값 857)입니다. `scripts/run.sh`는 이후 실행에서 루프 구성만 찍도록 고쳤고, 이미 기록된 `timeline.txt`는 원문이라 손대지 않았습니다.
- **"슬롯 지연 127 MB"와 아래 시계열의 최대 125.78MB는 다른 시점의 관측입니다.** 앞의 값은 20:05:53에 `timeline.txt`가 직접 질의한 것이고, 뒤의 값은 평균 1.44초 간격 샘플러가 t=183.6에 찍은 것입니다. 지연이 초당 0.99MB로 늘고 있었으므로 1.2MB 차이는 약 1.2초 차이에 해당합니다.

### 1초 목표 시계열 원문 발췌 (results/metrics.csv)

`sleep 1`에 psql 왕복 다섯 번이 붙어 실제 간격은 평균 1.44초입니다. 총 147회, 209.8초.

아래는 147줄 중 12줄을 골라낸 것이고, 각 줄은 `results/metrics.csv`의 원문 그대로입니다.

```
ts,wal_bytes,wal_files,slot_lag_bytes,slot_active,rows
1785322969.5,16777216,1,0,f,400
1785322999.5,50331648,3,237384,t,26200
1785323019.5,67108864,4,20381048,t,43600
1785323021.0,67108864,4,6636176,t,44800
1785323032.6,83886080,5,7358936,f,54800
1785323072.9,83886080,5,49339000,f,89800
1785323105.9,83886080,5,83010744,f,118200
1785323107.4,100663296,6,84432424,f,119400
1785323124.3,117440512,7,102250944,f,134000
1785323141.7,134217728,8,120025152,f,149000
1785323153.1,134217728,8,131888040,f,158800
1785323154.5,100663296,6,0,f,160000
```

같은 줄을 첫 행 기준 경과 초와 MB로 환산한 표입니다. 손으로 적은 값이 아니라 위 CSV를 나눈 값입니다.

| 경과 | pg_wal | 파일 | 슬롯 지연 | active | 누적 행수 | 비고 |
|---|---|---|---|---|---|---|
| 0.0초 | 16MB | 1 | 0MB | f | 400 | 슬롯 없음 |
| 30.0초 | 48MB | 3 | 0.23MB | t | 26,200 | 슬롯 생성 직후 |
| 50.0초 | 64MB | 4 | 19.44MB | t | 43,600 | 생존 구간 톱니 마루 |
| 51.5초 | 64MB | 4 | 6.33MB | t | 44,800 | 생존 구간 톱니 골 |
| 63.1초 | 80MB | 5 | 7.02MB | f | 54,800 | 컨슈머 사망 관측 |
| 103.4초 | 80MB | 5 | 47.05MB | f | 89,800 | |
| 136.4초 | 80MB | 5 | 79.17MB | f | 118,200 | 80MB 고원의 끝 |
| 137.9초 | 96MB | 6 | 80.52MB | f | 119,400 | |
| 154.8초 | 112MB | 7 | 97.51MB | f | 134,000 | |
| 172.2초 | 128MB | 8 | 114.46MB | f | 149,000 | |
| 183.6초 | 128MB | 8 | 125.78MB | f | 158,800 | 지연 최대 |
| 185.0초 | 96MB | 6 | 0MB | f | 160,000 | 슬롯 삭제 + CHECKPOINT 후 |

`scripts/report.py`가 같은 CSV에서 계산해 찍는 값입니다. 본문의 수치는 전부 이 출력에서 왔습니다.

```console
$ docker run --rm -u "$(id -u):$(id -g)" -e MPLCONFIGDIR=/tmp/mpl \
    -v "$PWD":/work -w /work/sessions/R04-replication-slot-wal \
    incident-lab-plot python scripts/report.py
저장: /work/sessions/R04-replication-slot-wal/results/chart-wal.png
슬롯 지연 최대 125.78MB(t=183.6s), WAL 최대 128MB, 종료 시 WAL 96MB
컨슈머 사망 t=63.1s, 이후 120.5초 동안 7.0MB -> 125.78MB (0.986MB/s)
생존 구간 슬롯 지연 0.23~19.44MB, 실측 쓰기 859.6행/초(구간별 400~1000, 중앙값 857)
pg_wal 80MB 고원 t=55.9~136.4s (80.5초), 다음 관측 t=137.9s에서 96MB
사망~최대 구간 삽입 행수 104,000행 (payload 1,024B 기준 약 102MB), 평균 관측 간격 1.44초
```

## 실험 2: max_slot_wal_keep_size = 64MB (results/exp2.txt)

`results/exp2.txt` 전문입니다. 편집하지 않았습니다.

```console
[20:07:39] 안전장치 설정: max_slot_wal_keep_size = 64MB
[20:07:40] 현재값 64MB
[20:07:41] 슬롯 생성. 컨슈머는 붙이지 않는다 (죽은 CDC 상태로 시작)
[20:07:41] 쓰기 시작
[20:07:41]   t=1s  WAL 80MB  슬롯지연 0MB  상태 reserved  여유 70MB
[20:08:02]   t=10s  WAL 96MB  슬롯지연 73MB  상태 unreserved  여유 -1MB
[20:08:23]   t=19s  WAL 128MB  슬롯지연 MB  상태 lost  여유 0MB
[20:08:23]   슬롯이 무효화됐다. 더 쌓지 않는다.
[20:08:23] 최종 상태
 slot_name | active | wal_status | lag | safe_wal
-----------+--------+------------+-----+----------
 cdc_slot  | f      | lost       |     |
(1 row)

[20:08:23] WAL 128 MB, 파일 8개
[20:08:23] 무효화된 슬롯에 컨슈머를 다시 붙이면
  pg_recvlogical: error: could not send replication command "START_REPLICATION SLOT "cdc_slot" LOGICAL 0/0": ERROR:  can no longer get changes from replication slot "cdc_slot"
  DETAIL:  This slot has been invalidated because it exceeded the maximum reserved size.
  pg_recvlogical: disconnected; waiting 5 seconds to try again
[20:08:28] 종료
```

이 출력에서 그대로 읽으면 안 되는 값이 셋 있습니다.

- **`t=1s / t=10s / t=19s`는 경과 초가 아니라 루프 반복 횟수입니다.** 한 바퀴에 psql 왕복이 네 번 들어가 평균 2.32초가 걸렸습니다. 벽시계로 `20:07:41 → 20:08:23`이니 실제 경과는 42초이고, `results/keepsize.csv`의 타임스탬프로 재면 **41.7초**입니다. `scripts/exp2-keepsize.sh`는 이후 실행에서 시작 시각과의 차이를 찍도록 고쳤고, 이미 기록된 `exp2.txt`는 원문이라 손대지 않았습니다.
- **`슬롯지연 MB`가 빈 것은 0이 아니라 NULL입니다.** 무효화된 슬롯은 `restart_lsn`이 NULL이라 `pg_wal_lsn_diff` 계산이 NULL을 돌려줍니다.
- **`여유 0MB`도 실제로는 NULL입니다.** PostgreSQL 문서가 `safe_wal_size`를 "NULL for lost slots"로 정의합니다. 스크립트의 `COALESCE(...,0)`이 0으로 바꿔 찍었습니다.

### 상한 실험 시계열 원문 (results/keepsize.csv)

19회 관측, 평균 2.32초 간격, 총 41.7초. 전문입니다.

```console
$ cat results/keepsize.csv
ts,wal_mb,lag_mb,wal_status,safe_wal_mb
1785323261.404928000,80,0,reserved,70
1785323263.721760000,80,9,reserved,62
1785323266.063224000,80,17,reserved,54
1785323268.378730000,80,25,reserved,46
1785323270.713812000,80,33,reserved,38
1785323273.018058000,80,41,reserved,30
1785323275.329198000,80,49,reserved,22
1785323277.652598000,80,57,reserved,14
1785323279.981322000,80,65,reserved,5
1785323282.275814000,96,73,unreserved,-1
1785323284.588515000,96,81,unreserved,-9
1785323286.899969000,112,90,unreserved,-17
1785323289.211603000,112,98,unreserved,-26
1785323291.535954000,128,106,unreserved,-34
1785323293.853931000,128,114,unreserved,-42
1785323296.184495000,144,122,unreserved,-50
1785323298.497192000,144,131,unreserved,-59
1785323300.808625000,160,138,unreserved,-67
1785323303.111632000,128,0,lost,0
```

첫 행 기준 경과로 환산하면 이렇습니다. 마지막 행의 `lag_mb=0`, `safe_wal_mb=0`은 `COALESCE`가 만든 값이고 원래는 NULL입니다.

| 실제 경과 | pg_wal | 슬롯 지연 | wal_status | safe_wal_size | 비고 |
|---|---|---|---|---|---|
| 0.0초 | 80MB | 0MB | reserved | 70MB | 슬롯 생성 직후 |
| 18.6초 | 80MB | 65MB | reserved | 5MB | 마지막 reserved |
| 20.9초 | 96MB | 73MB | unreserved | -1MB | 첫 unreserved |
| 39.4초 | 160MB | 138MB | unreserved | -67MB | 마지막 unreserved, 상한의 2.2배 |
| 41.7초 | 128MB | NULL | lost | NULL | 무효화 |

`unreserved` 상태로 찍힌 관측은 9회이고, 그 첫 관측 20.9초부터 `lost`가 확인된 41.7초까지 20.8초가 걸렸습니다. 상한이 `checkpoint_timeout=30s`의 체크포인트 시점에만 적용되므로, 그사이 슬롯 지연이 상한 64MB를 넘어 138MB까지 올라간 상태가 유지됐습니다.

## 증거 카드 재생성 (results/render.json)

```console
$ docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/work \
    incident-lab-render sessions/R04-replication-slot-wal/results
생성: sessions/R04-replication-slot-wal/results/fig-lost.png  2160x858
생성: sessions/R04-replication-slot-wal/results/fig-keepsize.png  1388x560
```

`fig-lost.png`의 본문은 `results/exp2.txt`를 한 줄도 고치지 않고 옮긴 것입니다. `fig-keepsize.png`는 그 출력의 `t=Ns`가 반복 횟수라서 따로 그린 그림이고, 값은 `results/keepsize.csv` 타임스탬프 기준 경과 초입니다.

## 원문 파일 위치

| 내용 | 경로 |
|---|---|
| 타임라인 | `results/timeline.txt`, `results/exp2.txt` |
| 시계열 | `results/metrics.csv`(147회, 평균 1.44초 간격), `results/keepsize.csv`(19회, 평균 2.32초 간격) |
| 호스트·버전 | `results/env.txt` |
| 차트·증거 카드 | `results/chart-wal.png`, `results/fig-lost.png`, `results/fig-keepsize.png` |
| 렌더 스펙 | `results/render.json` |
