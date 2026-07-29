# 재현 기록

실행한 명령과 출력을 그대로 붙입니다. 조건이 열한 가지에 회차가 3회씩이라 전체 원문은
`results/raw/`에 두고, 여기에는 각 조건의 대표 출력을 옮겼습니다.

호스트에 자바나 그레이들을 설치할 필요는 없습니다. 앱은 멀티스테이지 도커 빌드로 만들고,
구독자 클라이언트도 `eclipse-temurin:21-jdk-alpine` 컨테이너에서 단일 파일 소스로 돌립니다.

## 1. 전체 실행

```console
$ cd sessions/F15-websocket-slow-consumer
$ bash scripts/run-suite.sh
```

모드 열한 개를 각각 3회씩 돕니다. 회차마다 앱을 새로 띄워 힙을 초기화합니다.
일부만 다시 돌리려면 이렇게 합니다.

```console
$ MODES="unbounded" RUNS=1 bash scripts/run-suite.sh
$ MODES="combo combo-stalled" RUNS=3 bash scripts/run-suite.sh
```

## 2. 직접 전송: 정상 구독자까지 굶는다

```console
$ MODES="direct" RUNS=1 bash scripts/run-suite.sh
=== direct-r1 (45s, 정상 5 + 느린 1, 3000 ticks/s, -Xmx128m) ===
== F15 클라이언트 측정 ==
mode=direct run=1 측정시간=45.1s 정상구독자=5 느린구독자=1(읽기 32768 B/s, SO_RCVBUF 8192B)
백분위는 워밍업 5s를 뺀 구간의 값이고, 수신건수와 최종틱seq는 전 구간 값이다.

-- 정상 구독자 --
id             수신건수     최종틱seq    지연p50    지연p95     지연p99     지연max     간격p95     간격max  비고
normal-1       3266       3266       1ms      10ms      20ms      25ms     2.1ms    1378ms  -
normal-2       3265       3265       1ms       9ms    1262ms    1378ms     2.1ms    1377ms  -
normal-3       3265       3265       1ms       9ms    1262ms    1378ms     2.2ms    1378ms  -
normal-4       3266       3266       0ms       8ms      17ms      24ms     2.1ms    1377ms  -
normal-5       3266       3266       1ms      11ms      24ms      28ms     2.1ms    1378ms  -

합계 수신 16328건, 정상 구독자 전체 지연 p50=1ms p95=9ms p99=23ms max=1378ms
최종 수신 틱 seq: 최소 3265, 최대 3266

-- 느린 구독자 --
slow-1  읽은 바이트 1,464,372 (평균 31.7 KB/s, 목표 32.0 KB/s)  서버가 끊지 않음(측정 끝까지 연결 유지)

SUMMARY mode=direct run=1 recv_total=16328 lat_p50_ms=1 lat_p95_ms=9 lat_p99_ms=23 lat_max_ms=1378 last_seq_min=3265 last_seq_max=3266 worst_client_p95_ms=11 worst_client_max_ms=1378 slow_read_bytes=1464372 slow_closed_at_s=none
```

정상 구독자 다섯 명의 최종 틱 seq가 3,265에서 3,266입니다. 느린 구독자가 없는 대조군에서는
129,138이었습니다. 느린 구독자 한 명 때문에 정상 구독자도 40분의 1만 받았습니다.

## 3. 무제한 큐: OOM까지의 곡선

`results/raw/server-unbounded-r1.csv`에서 10초 간격으로 뽑았습니다.

```console
$ python3 -c "..."   # server-unbounded-r1.csv 를 10초 간격으로 출력
 초   힙(MB)   느린큐(MB)   발행/초    GC(ms)
  0     36.5        0.07       240       119
 10     44.5       12.58     2,976       189
 20     54.8       25.71     2,886       214
 30     65.9       38.85     2,928       241
 40     77.7       52.02     2,940       270
 50    117.5       64.99     2,940       406
 60    104.1       77.29     2,598     1,112
 70    116.8       88.84     2,196     2,314
 80    123.6       95.42       474     6,899
 86    123.7       95.59         0    13,664
```

GC(ms)는 누적값입니다. 50초까지 406ms이던 것이 80초에 6,899ms, 86초에 13,664ms가 됩니다.
발행량은 그 반대로 2,940건에서 0건이 됩니다.

서버 로그 원문입니다.

```console
$ grep -E "Started StreamApp|OOM" results/raw/serverlog-unbounded-r1.txt
03:24:35.910 INFO  Started StreamApp in 6.508 seconds (process running for 7.962)
[OOM] thread publisher java.lang.OutOfMemoryError: Java heap space
```

## 4. 조건별 요약

회차 원문에서 한 줄씩 뽑아 모읍니다.

```console
$ bash scripts/summarize.sh
mode             run  seconds  published  publish_per_s  heap_peak_mb  slow_queue_peak_mb  gc_ms  broadcast_blocked_ms  oom  lat_p95_ms  last_seq_min  slow_closed_at_s
baseline         1    45       130926     2909           47.0          0.00                328    1048                  0    1           129138        n/a
direct           1    46       6564       143            45.6          0.00                178    43953                 0    9           3265          none
direct           2    45       5550       123            45.5          0.00                147    44004                 0    9           3167          none
direct           3    46       6510       142            45.3          0.00                146    44059                 0    11          3167          none
direct-stalled   1    46       75174      1634           47.1          0.00                263    20809                 0    2           71256         none
unbounded        1    111      215037     1937           123.7         95.60               16994  419                   1    1           215037        none
unbounded        2    111      215043     1937           123.7         95.58               18797  2585                  1    1           215043        none
unbounded        3    111      215084     1938           123.7         95.54               15777  504                   2    1           214912        none
bounded          1    46       134412     2922           47.4          0.46                189    164                   0    1           129762        none
conflate         1    46       132540     2881           47.5          0.01                189    164                   0    1           128910        none
terminate        2    46       126996     2761           52.9          3.76                447    120                   0    1209        18686         7.3
terminate-tight  1    45       131934     2932           49.0          1.11                172    87                    0    1           130644        4.3
decorator        1    46       133488     2902           48.1          0.51                175    144                   0    2           129708        4.5
combo            1    46       135054     2936           47.5          0.01                180    182                   0    1           130758        none
combo-stalled    1    46       134844     2931           47.3          0.01                196    153                   0    1           131202        none
```

전체 33행은 `results/summary.csv`에 있습니다. 위 발췌는 열 일부를 줄인 것입니다.

`terminate` 조건의 2회차가 `lat_p95_ms=1209`, `last_seq_min=18686`으로 다른 회차와 크게
다릅니다. 처음에는 한도 1MB에 3초 판정이라 끊기로 결정하기까지 피해가 쌓인 회차로 읽었습니다.
실제로는 이 회차를 포함한 여섯 회차가 같은 호스트에서 다른 세션의 MySQL 부하가 도는 동안
측정된 것이었습니다. 6절에서 다시 쟀고 아래 표와 그림은 재측정값입니다. 이 편차 때문에
표에는 평균이 아니라 중앙값을 씁니다.

## 5. 리포트와 그림 생성

```console
$ python3 scripts/report.py
================================================================================================
F15 슬로우 컨슈머   (정상 구독자 5 + 느린 구독자 1, 초당 3,000틱, 힙 128MB, 모드마다 3회 중앙값)
================================================================================================

                          조건     발행/초     힙 최대      느린큐      생산자 정지      GC    정상 p95  OOM      느린구독자
------------------------------------------------------------------------------------------------
             대조군 (느린 구독자 없음)    2,909    47.2M    0.00M        1.0초    0.3초        1ms    0      끊지 않음
            직접 전송 (느린 구독자 1)      142    45.5M    0.00M       44.0초    0.1초        9ms    0      끊지 않음
           직접 전송 (완전 정지 구독자)    1,630    46.2M    0.00M       20.7초    0.2초        2ms    0      끊지 않음
                       무제한 큐    1,937   123.7M   95.58M        0.5초   17.0초        1ms    1      끊지 않음
                바운디드 큐 1000건    2,925    47.5M    0.46M        0.2초    0.3초        1ms    0      끊지 않음
        conflation (종목별 최신만)    2,907    46.7M    0.01M        0.3초    0.2초        1ms    0      끊지 않음
                   절단 1MB/3초    2,949    50.7M    3.70M        0.1초    0.2초        1ms    0       6.9초
                 절단 512KB/1초    2,932    48.1M    1.11M        0.1초    0.2초        1ms    0       4.3초
          Spring 데코레이터 512KB    2,902    47.3M    0.51M        0.1초    0.2초        2ms    0       4.3초
             conflation + 절단    2,936    47.5M    0.01M        0.2초    0.2초        1ms    0      끊지 않음
     conflation + 절단 (완전 정지)    2,931    46.7M    0.01M        0.3초    0.2초        1ms    0      끊지 않음

발행/초는 서버가 실제로 만들어 내보낸 틱이다. 대조군 2,909가 정상값이다.
생산자 정지는 브로드캐스트 스레드가 전송에 막혀 있던 누적 시간이다.
느린큐는 느린 구독자 몫으로 서버가 들고 있던 메모리의 최댓값이다.

render.json 작성: 이미지 4장
```

그림은 저장소 루트에서 만듭니다.

```console
$ docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/work incident-lab-render \
    sessions/F15-websocket-slow-consumer/results
생성: sessions/F15-websocket-slow-consumer/results/00-oom.png  1166x733
생성: sessions/F15-websocket-slow-consumer/results/01-publish.png  940x560
생성: sessions/F15-websocket-slow-consumer/results/02-blocked.png  940x560
생성: sessions/F15-websocket-slow-consumer/results/03-heap.png  940x560
```

## 6. 재측정

4절의 `conflate` 2·3회차와 `terminate` 1·2·3회차는 같은 호스트에서 다른 세션의 MySQL 부하가
도는 동안 측정됐습니다. 그 부하가 모두 끝나 실험 컨테이너가 하나도 없고 `uptime`의 1분
로드가 2.17로 내려간 것을 확인한 뒤, 두 모드를 3회씩 다시 쟀습니다.

```console
$ MODES="conflate terminate" RUNS=3 bash scripts/run-suite.sh

$ bash scripts/summarize.sh
mode             run  seconds  published  publish_per_s  heap_peak_mb  slow_queue_peak_mb  gc_ms  broadcast_blocked_ms  oom  lat_p95_ms  recv_total  slow_closed_at_s
conflate         1    46       132984     2891           47.1          0.01                222    282                   0    2           628107      none
conflate         2    45       132648     2948           46.7          0.01                154    420                   0    1           649398      none
conflate         3    46       133722     2907           46.6          0.01                195    111                   0    1           646500      none
terminate        1    46       134718     2929           52.7          4.61                255    82                    0    1           655974      6.9
terminate        2    45       133080     2957           50.7          3.57                208    49                    0    1           654626      6.9
terminate        3    45       132720     2949           50.7          3.70                214    107                   0    1           650196      6.8
```

`terminate` 세 회차의 총 수신 건수가 655,974건과 654,626건과 650,196건으로 편차가 1% 안에
들어왔고 정상 구독자 p95는 세 회차 모두 1ms입니다. 오염된 측정에서는 619,878건과 306,506건과
634,597건이었고 p95는 10ms와 1,209ms와 175ms였습니다. 4절과 5절의 표, `results/`의 그림은
모두 이 재측정값으로 갱신했습니다. 오염된 회차의 원본 로그는 `results/raw/suite-before-remeasure.txt`에
남겨 두었습니다.

## 7. 정리

```console
$ docker compose down --remove-orphans
```
