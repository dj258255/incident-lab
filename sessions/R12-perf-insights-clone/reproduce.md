# R12 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| 호스트 | **기록하지 않았습니다.** `uname -srm`·`nproc`·`free -g`를 남기지 않아 CPU 수, 메모리, 저장 장치 종류를 확인할 수 없습니다. 이 저장소는 호스트가 두 종류이므로 절대 시간을 다른 세션과 비교하지 마십시오 |
| 컨테이너 | MySQL 8.4.3, `cpus: 4`, `mem_limit: 2g`, **버퍼 풀 256MB**, `max_connections=200` |
| 데이터 | small 10만 행(캐시에 다 들어감), hotrow 1행, big 400만 행 약 1.1GB |
| 부하 생성기 | Python(CPython) + PyMySQL, 스레드 8개(`workload.py`의 `THREADS`), 동기 드라이버 |
| 샘플러 | Python, 1초·0.1초 두 간격 병행 |
| 일시 | 2026-07-29 |

`cpus: 4`는 컨테이너 CPU 할당량이지 호스트 코어 수가 아닙니다. `scripts/report.py`가 긋는 점선(`VCPU = 4`)도 같은 값입니다.

## 실행

```console
$ docker compose up -d
$ ./scripts/run-experiments.sh          # 적재 + 함정 재현 + 3구간 워크로드, 약 12분
$ python3 scripts/lock-probe.py results/lock-probe.csv    # 보강 실험, 1분
$ python3 scripts/report.py
```

## 1. 소비자 꺼짐 함정 (results/01-default-instruments.txt)

원인은 계측(instrument)이 아니라 소비자(consumer)입니다. 아래는 출력 원문입니다.

```console
--- 8.4 기본값에서 wait/% 계측과 waits 소비자 상태
+--------------------------------------+---------+
| NAME                                 | ENABLED |
+--------------------------------------+---------+
| wait/io/file/innodb/innodb_data_file | YES     |
| wait/lock/table/sql/handler          | YES     |
+--------------------------------------+---------+
+---------------------------+---------+
| NAME                      | ENABLED |
+---------------------------+---------+
| events_waits_current      | NO      |
| events_waits_history      | NO      |
| events_waits_history_long | NO      |
+---------------------------+---------+
```

조회한 계측 둘은 **켜져 있었고**, 꺼져 있던 것은 waits 소비자 셋입니다.
MySQL 문서(`Pre-Filtering by Consumer`)가 "이벤트가 어느 목적지에도 전달되지 않으면 Performance Schema는 그 이벤트를 만들지 않는다"고 적은 그대로입니다.
소비자가 `NO`면 `events_waits_current`가 비고, 샘플러의 LEFT JOIN이 NULL을 받고, NULL은 CPU로 분류됩니다.

세 번째로 조회한 `wait/synch/mutex/innodb/buf_pool_mutex`는 8.4에 그 이름의 계측이 없어 행이 나오지 않았습니다.
`wait/synch/%`와 `wait/io/socket/%`처럼 기본이 꺼진 계측도 있으므로, `run-experiments.sh`는 계측과 소비자를 모두 켭니다.

```console
-- 락에 막힌 세션 2개를 샘플링 (소비자 활성화 전, results/blind-sample.csv)
ts, active, cpu, io_file, io_table, lock, synch, other
...,     2,   2,       0,        0,    0,     0,     0     ← 전부 CPU로 보임

-- 계측·소비자 활성화 후 같은 상황 (results/sighted-sample.csv)
...,     2,   0,       0,        1,    0,     1,     0     ← 대기가 드러남
```

## 2. 3구간 분해 (results/pi-1s.csv, chart-pi-1s.png)

`report.py`의 출력에는 `other`(기타, 분류기가 못 알아본 이벤트) 열이 들어 있습니다. **이 열을 빼고 인용하지 마십시오.**
분류기의 정확도를 검증하는 세션이라 미분류 비율이 결과의 일부입니다.

```console
[pi-1s.csv] 구간별 평균 활성 세션 (AAS) 분해   (각 구간 60샘플)
구간                    CPU    IO(파일)  IO(테이블)     락   내부 동기화     기타
1: CPU 점조회          0.33      0.00      0.08     0.00      0.00     0.12
2: 핫 로우 UPDATE      0.30      0.72      6.50     0.00      0.00     0.00   ← 행 락이 io_table로 나타남
3: 콜드 IO 조회        0.35      0.02      1.53     0.00      0.00     0.18
```

| 구간 | 6열 합 | 활성 세션(관측) |
|---|---|---|
| 1 | 0.53 | 0.55 |
| 2 | 7.52 | 7.52 |
| 3 | 2.08 | 2.08 |

구간 1에서 합과 활성 세션이 어긋나는 것은 샘플러 구현 탓입니다.
`classify()`가 `idle`로 분류한 세션은 `active_sessions`에는 들어가고 여섯 열 어디에도 안 들어갑니다. 60샘플 중 1건입니다.

### 0.1초 샘플링과의 비교 (results/pi-100ms.csv)

두 샘플러를 같은 실행에서 동시에 돌렸습니다.

| 구간 | 간격 | 샘플 수 | CPU | IO(파일) | IO(테이블) | 락 | 내부 동기화 | 기타 | 활성 세션 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 1초 | 60 | 0.33 | 0.00 | 0.08 | 0.00 | 0.00 | 0.12 | 0.55 |
| 1 | 0.1초 | 594 | 0.32 | 0.00 | 0.04 | 0.01 | 0.00 | 0.12 | 0.50 |
| 2 | 1초 | 60 | 0.30 | 0.72 | 6.50 | 0.00 | 0.00 | 0.00 | 7.52 |
| 2 | 0.1초 | 588 | 0.28 | 0.69 | 6.47 | 0.00 | 0.00 | 0.02 | 7.46 |
| 3 | 1초 | 60 | 0.35 | 0.02 | 1.53 | 0.00 | 0.00 | 0.18 | 2.08 |
| 3 | 0.1초 | 594 | 0.39 | 0.03 | 1.59 | 0.00 | 0.01 | 0.14 | 2.16 |

열별 차이가 0.06 이내라 구조가 같습니다. 다만 구간 1의 `락`은 1초에서 0, 0.1초에서 0.01로, 드물고 짧은 대기는 1초 간격에서 통째로 빠집니다.

## 3. 보강: io/table이 락인지 IO인지 (results/lock-probe.csv)

```console
핫 로우 UPDATE: io/table 세션 평균 6.5, data_lock_waits 평균 25.2   (30샘플 전부)
콜드 IO 조회:   io/table 세션 평균 1.1, data_lock_waits 평균  0.9   (30샘플 전부)
```

위는 `lock-probe.py`가 그대로 인쇄한 값입니다. **다만 각 구간의 첫 샘플이 경계값이라 인용할 때 주의해야 합니다.**

| 구간 | 뺀 샘플 | io/table 대기 세션 | data_lock_waits |
|---|---|---|---|
| 핫 로우 UPDATE | t=0.0 (스레드 기동 전, 0/0) | 평균 6.7 (6~7), 29샘플 | 평균 26.1 (21~28), 29샘플 |
| 콜드 IO 조회 | t=30.1 (구간 전환 직후, 앞 구간의 28건이 남음) | 평균 0.9 (0~4), 29샘플 | **0 (29샘플 전부)** |

콜드 구간의 `data_lock_waits` 평균 0.9는 전적으로 전환 직후 1샘플 때문입니다. 구간이 안정된 뒤로는 정확히 0입니다.

## 4. 이 세션이 검증하지 못한 것

- **구간 1(CPU)의 검증이 성립하지 않습니다.** `workload.py`의 `THREADS = 8`이 60초 내내 PK 점조회를 도는데 활성 세션이 0.55입니다.
  스레드 하나가 쿼리 안에 있던 시간 비율이 약 7%라 DB가 사실상 논 상태입니다.
  CPython의 GIL과 동기 드라이버 조합 때문에 부하 생성기가 DB를 못 채웠을 가능성이 크지만, 클라이언트를 프로파일링하지 않아 확정하지 못했습니다.
  같은 8스레드가 구간 2에서 7.52를 만든 것이 방증입니다. 락이 세션을 DB 안에 붙잡아 두는 구간에서만 부하가 찼습니다.
- **미분류(`other`)의 정체를 모릅니다.** 구간 1에서 활성 세션의 21%, 구간 3에서 8.8%가 `other`인데,
  샘플러가 개수만 CSV에 쓰고 이벤트 이름을 안 남겨 확인할 수 없습니다. 다음 실행에서 이름을 기록해야 합니다.
- **콜드 IO 구간의 AAS가 낮은 이유를 설명할 근거가 없습니다.** 저장 장치를 기록하지 않았고 버퍼 풀 미스 한 번의 지연도 재지 않았습니다.
  위의 부하 생성기 문제도 이 구간에 그대로 걸립니다.
- **락 판별의 대안을 재지 않았습니다.** `SHOW ENGINE INNODB STATUS`, `sys.innodb_lock_waits`와 비교하지 않았습니다.
- **실제 PI 화면과 나란히 대조하지 못했습니다.** RDS 인스턴스 없이 로컬 재현만 했습니다.

## 원문 파일 위치

| 내용 | 경로 |
|---|---|
| 1초·0.1초 샘플 원본 | `results/pi-1s.csv`, `results/pi-100ms.csv` |
| 계측 전·후 샘플 | `results/blind-sample.csv`, `results/sighted-sample.csv` |
| 소비자 상태 출력 | `results/01-default-instruments.txt`, `results/02-enable.txt` |
| 워크로드 구간 전환 로그 | `results/03-workload.txt` |
| 락 판별 프로브 | `results/lock-probe.csv` |
| 대시보드 | `results/chart-pi-1s.png`, `results/chart-pi-100ms.png` |

`run-experiments.sh`는 실행 로그를 파일로 남기지 않습니다. 위 표에 적힌 것이 저장된 산출물 전부입니다.
