# R01 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| MySQL | 8.4.3 x 2노드 (source 13310, replica 13311), GTID, binlog |
| 복제 | 비동기 → 실험 B부터 semisync 플러그인 (AFTER_SYNC, timeout 8000ms) |
| 분단 방법 | 복제 전용 네트워크에서 `docker network disconnect` |
| 쓰기 | Python, 후원 1건씩 커밋, 커밋 성공 건만 로그 (초당 약 30건) |
| 일시 | 2026-07-29 |

## 실행

```console
$ docker compose up -d
$ ./scripts/setup.sh          # 복제 구성
$ ./scripts/exp-async.sh      # 실험 A (약 2분)
$ ./scripts/setup.sh          # 재동기화
$ ./scripts/exp-semisync.sh   # 실험 B·C (약 2분)
```

## 실험 A: 비동기 (results/async-timeline.txt)

```console
[06:52:29] 쓰기 시작 (40초 예정)
[06:52:39] 복제망 분단 (docker network disconnect)
[06:52:54] 소스 강제 종료 (docker kill)
[06:52:54] 쓰기 종료: 커밋 성공 927건, 합계 8,628,000원, 마지막 seq 927
[06:52:58] 승격본 상태: 행수/최대seq/합계 = 372  372  3596000
[06:53:39] GTID 차집합(옛 소스에만 있는 트랜잭션): 7bddaea1-...:380-934
[06:53:39] 옛 소스의 행수/최대seq/합계: 927  927  8628000
```

유실 = 927 - 372 = 555건, 8,628,000 - 3,596,000 = 5,032,000원.

`Seconds_Behind_Source` 1초 시계열(`results/async-sbs.csv`): 분단(10초 지점) 후에도 29초 지점까지 0을 표시. `replica_net_timeout=20` 경과 후에야 IO 스레드가 No로 전환.

## 실험 B: 반동기, ack 창 안에서 종료 (results/semi-timeline.txt)

```console
Rpl_semi_sync_source_status  ON
[06:54:52] 복제망 분단
[06:54:58] 소스 강제 종료 (반동기가 ack를 기다리는 창 안)
[06:54:58] 쓰기 종료: 커밋 성공 371건
[06:55:00] 승격본: 이번 실험 분 371건 전부 보유     → 확정 커밋 유실 0
```

## 실험 C: 강등 후 종료

```console
[06:55:19] 복제망 분단. 8초 뒤 강등을 기다린다
Rpl_semi_sync_source_status  OFF                    ← 비동기로 강등됨
[06:55:37] 쓰기 종료: 커밋 성공 707건
[06:55:39] 승격본: 이번 실험 분 373건만 보유        → 334건(3,240,000원) 유실
```

## 원문 파일 위치

| 내용 | 경로 |
|---|---|
| 커밋 성공 로그 (정답지) | `results/async-writer.csv`, `semi-writer.csv`, `degraded-writer.csv` |
| Seconds_Behind_Source 시계열 | `results/async-sbs.csv` |
| GTID 집합·차집합 | `results/async-*-gtid.txt`, `async-gtid-subtract.txt` |
| 타임라인 | `results/async-timeline.txt`, `semi-timeline.txt` |
