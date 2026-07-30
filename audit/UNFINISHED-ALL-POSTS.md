# 발행된 32편의 "못 한 것" 전수 분류

2026-07-30 작성. 앞선 두 감사(`UNFINISHED-AUDIT.md`, `UNFINISHED-NEW-SESSIONS.md`)는 일부
세션만 다뤘습니다. 이 문서는 발행된 32편의 "못 한 것"과 "안 한 것" 항목을 **전부** 뽑아
같은 기준으로 분류합니다. 총 **145건**입니다.

판정 장비는 12코어 맥, 32GB입니다.

- **A**: 원리적으로 불가
- **B**: 이 환경에서 불가
- **C**: 가능한데 안 함
- **D**: 범위 밖
- **E**: 이미 해결됨

## 먼저, 구조적 불일치 하나

32편 가운데 **10편에는 "못 한 것" 절이 아예 없습니다.**

bigdecimal-money, expand-contract, hanmac-divide-by-zero, market-open-connection-storm,
matching-engine-priority, nasdaq-ipo-livelock, negative-price, planner-stats-flip,
samsung-ghost-shares, threadlocal-classloader-leak

이 10편은 `> 출처:` 인용 블록이 없던 10편과 **정확히 같은 목록**입니다(2026-07-30 보완 완료).
한 시기에 쓴 글들이 관례를 공유하지 않은 것이고, 근거 표기는 채웠으나 "못 한 것" 절은
아직 없습니다. 한계를 안 적었다는 뜻이지 한계가 없다는 뜻이 아니므로 채워야 합니다.
이것 자체를 C로 둡니다.

## 집계

| 등급 | 건수 | 비중 |
|---|---|---|
| A 원리적 불가 | 7 | 5% |
| B 환경 불가 | 38 → 35 | 26% → 24% |
| C 가능한데 안 함 | 61 → 64 | 42% → 44% |
| D 범위 밖 | 33 | 23% |
| E 이미 해결 | 6 | 4% |
| 합계 | 145 | |

C가 42%입니다(2026-07-30 2차 재분류로 44%). 아래 집계는 1차 시점 값이고, 문서 끝의
2차 절에 옮긴 내역을 적었습니다. 포트폴리오에서 가장 아픈 비중이고, 그래서 아래 C 목록을 우선순위대로
처리합니다.

## C: 가능한데 안 함 (우선순위 순)

### C1. 다른 엔진 대조 (4건)

원 사례의 엔진과 재현 엔진이 다른 자리입니다. 가장 값이 큰 묶음입니다.

| 세션 | 항목 | 상태 |
|---|---|---|
| A23 backup-pitr | PostgreSQL PITR | **완료 (2026-07-30)**. `recovery_target_action` 기본 `pause`와 `recovery_target_inclusive`의 사정거리를 네 조건으로 실측 |
| A01 int-pk-exhaustion | PostgreSQL `integer` 고갈과 `ALTER TYPE` | **완료 (2026-07-30)**. 고갈 에러가 선언 방식에 따라 셋으로 갈리고, MySQL 과 달리 사전 거부가 없음을 실측 |
| A22 index-not-used | PostgreSQL 대조 | 남음. `EXPLAIN (ANALYZE, BUFFERS)`로 같은 쿼리를 재면 됩니다 |
| B?? jpa-list-api | PostgreSQL 대조 | 남음. `rewriteBatchedStatements` 대응물이 없어 삽입 쪽 결론이 갈릴 수 있습니다 |

### C2. 설정 조건 하나만 바꿔 재는 것 (19건)

전부 GUC 한 줄이나 쿼리 한 줄 차이입니다. 장비도 도구도 이미 있습니다.

| 세션 | 항목 | 예상 |
|---|---|---|
| A06 gap-lock-deadlock | `SKIP LOCKED` / `NOWAIT` 비교 | 30분 |
| A06 gap-lock-deadlock | 재시도 전략별 처리량 | 1시간 |
| A06 gap-lock-deadlock | 세 번째 시나리오(획득 순서 엇갈림) 문서화 | 30분 |
| A01 int-pk-exhaustion | `INT UNSIGNED`로 미루는 선택지 | 30분 |
| A02 mdl-storm | 쓰기 부하를 넣은 조건 | 1시간 |
| A02 mdl-storm | 커넥션 풀 고갈로 번지는 경로 | 1시간 |
| A14 xid-wraparound | `vacuum_failsafe_age` 대조 | 1시간 (아래 C3과 묶어야 함) |
| A19 subtransaction-slru | `RELEASE SAVEPOINT`의 효과 | 1시간 |
| A23 backup-pitr | 논리·물리 백업 복원 시간 비교 | 1시간 |
| uuid-page-split | 적재 말고 조회 | 1시간 |
| uuid-page-split | 페이지 충전율 직접 측정 | 1시간 |
| timeseries-partition | 파티션 수가 조회에 물리는 비용 | 1시간 |
| index-not-used | `COLLATE` 명시로 넘길 수 있는지 | 30분 |
| index-not-used | 결과 집합 크기별 배수 곡선 | 1시간 |
| jpa-list-api | 삽입 세 방식을 같은 테이블에서 | 1시간 |
| jpa-list-api | `rewriteBatchedStatements` 끈 조건의 `batchUpdate` | 30분 |
| jpa-list-api | `Persistable.isNew()` 변형 | 1시간 |
| reader-endpoint-skew | `maxLifetime` 흔들림 분리 측정 | 1시간 |
| perf-insights-clone | 샘플링 오버헤드 정밀 측정 | 1시간 |

### C3. 규모를 키워야 보이는 것 (2건, C2와 짝)

| 세션 | 항목 | 왜 |
|---|---|---|
| A14 xid-wraparound | 거대 테이블 | 5만 행에서는 `vacuum_failsafe_age`의 차이가 시간으로 드러나지 않습니다. C2의 failsafe 항목의 전제 조건입니다 |
| timeseries-partition | 행 수를 운영 규모에 가깝게 | 파티션 드롭과 `DELETE`의 격차가 규모에 따라 벌어지는지 봐야 합니다 |

### C4. 반복 측정 (12건)

`tools/repeat-runs.sh`가 이미 있습니다. 세션마다 3회씩 더 돌리면 됩니다.
backup-pitr, buffer-pool-sizing, gap-lock-deadlock, int-pk-exhaustion, jpa-list-api,
mdl-storm, reader-endpoint-skew, replication-slot-wal, uuid-page-split.

**주의**: `run-all.sh` 계열이 접두어 없는 파일명으로 쓰기 때문에 그냥 돌리면 발행된
기준값을 덮어씁니다. A02에서 실제로 한 번 잃고 git 에서 복구했습니다. 먼저 원본을
`run0-*`로 저장해야 합니다.

### C5. "못 한 것" 절이 없는 10편에 그 절을 채우는 것 (10건)

위 "구조적 불일치" 항목입니다.

### C6. 도구를 실제로 돌리는 것 (3건)

| 세션 | 항목 | 왜 가능한가 |
|---|---|---|
| A01 int-pk-exhaustion | `gh-ost` / `pt-online-schema-change` | 컨테이너 이미지가 공개돼 있습니다 |
| A02 mdl-storm | 같음 | 같음 |
| R04 replication-slot-wal | Debezium | 공식 이미지가 있습니다. 하트비트와 자동 재연결이 결론을 바꿀 수 있습니다 |

### C7. 나머지 (11건)

charset-timezone의 `utf8mb4` 전환 실행과 DST 전환, batch-cache-pollution의 `mysqldump`
조건, replica-promotion-loss의 `AFTER_COMMIT` 비교와 복구 실행, websocket의 재접속 폭풍과
STOMP 경로, perf-insights-clone의 top SQL 차원 분해, index-not-used의 OR 조건과 index merge.

## B: 이 환경에서 불가 (38건)

### B1. 클라우드 실계정이 필요한 것 (8건)

charset-timezone, failover-dns-cache, reader-endpoint-skew(3건), replica-promotion-loss,
replication-slot-wal, timeseries-partition.

RDS와 Aurora에서 직접 돌리는 것, 그리고 비용 계산입니다. 실제 계정과 과금이 필요하므로
이 랩의 범위 밖입니다. 다만 **문서를 읽고 정리한 것과 계정에서 잰 것을 글에서 구분해
표기하는 일**은 이미 했습니다.

### B2. 규모 (4건 + C3과 중복)

21억 행, TB급 테이블, 수십 GB 덤프입니다. 12코어 맥 32GB에서 디스크와 시간이 안 됩니다.
다만 C3에 적은 두 건은 "운영 규모"가 아니라 "차이가 보이는 규모"까지만 올리는 것이라
C로 뒀습니다.

### B3. 호스트 사양 미기록 (6건)

backup-pitr, charset-timezone, int-pk-exhaustion, jpa-list-api, replica-promotion-loss,
uber-write-amplification.

**지금 다시 찍어도 그 실행의 장비라는 보장이 없습니다.** 그래서 채우지 않고, 대신 각 글에
"이 절대값을 다른 세션의 절대값과 비교하면 안 된다"를 적어 두었습니다. 재측정을 하면
그때 기록이 남습니다. 즉 C4(반복 측정)를 하면 자동으로 해소됩니다.

### B4. 커널·디스크 조건 (5건)

batch-cache-pollution의 회전 디스크와 스토리지 상한, buffer-pool-sizing의 콜드 스타트,
replication-slot-wal의 디스크 포화.

Docker Desktop이 컨테이너별 블록 장치 쿼터를 지원하지 않고, 페이지 캐시를 비우는
`drop_caches`도 macOS 호스트에서 게스트 커널에 닿지 않습니다. **Linux 호스트에 loop
장치로 작은 파일 시스템을 만들면 가능합니다.** 장비가 바뀌면 B에서 C로 옮겨야 합니다.

### B5. 버전 비교 (3건)

A19의 PG16 대 17, A14의 PG13 대 17입니다. 이미지로 돌리는 것 자체는 되지만 문제가
버전마다 다른 GUC와 없어진 뷰라서 조건을 맞출 수 없습니다. 소스를 고쳐 빌드해야 합니다.

### B6. 상용 엔진 (1건) — 2026-07-30 정정

**이 항목의 원래 서술이 틀렸습니다.** "SQL Server 는 PITR 실습에 Enterprise 기능이
걸린다"고 적었는데 그렇지 않습니다. Developer 에디션이 `mcr.microsoft.com/mssql/server` 로
무료 공개돼 있고 `STOPAT` 시점 복구가 그 에디션에 들어 있습니다. **같은 날 실행해
A23 6절로 넣었습니다.**

남은 것은 Oracle 하나입니다. Oracle Database Free 23ai 컨테이너가 공개돼 있어 실행 자체는
가능해 보이므로 이것도 B 가 아니라 **C** 입니다. `RMAN` 의 `UNTIL TIME` 실습에 아카이브
로그 모드 전환이 필요해 아직 안 했습니다.

### B7. 나머지 (10건)

perf-insights-clone의 실제 PI 화면 대조(계정 필요), 원 사건 수치와의 직접 비교(규모가
다름) 등입니다.

**index-not-used 의 "두 호스트 값 비교"는 2026-07-30 에 C 로 옮겼습니다.** 장비가 이미
다르다는 것은 과거 실행의 사실이고, 한 장비에서 다시 재면 되는 일입니다.

## A: 원리적으로 불가 (7건)

| 세션 | 항목 | 왜 |
|---|---|---|
| B01 hikaricp-pool-deadlock | 원 사례의 Hibernate 버전 | 원문에 없습니다 |
| charset-timezone | 타임존 사고의 E1 사례 | 두 차례 조사에서 못 찾았습니다. 없는 것을 만들 수는 없습니다 |
| replica-promotion-loss | 원 사건의 43초 분단, 954건 유실과 직접 비교 | 규모와 구성이 다릅니다. 비율만 볼 수 있습니다 |
| index-not-used | LINE 사례의 805행 → 31행과 직접 비교 | 같음 |
| perf-insights-clone | 미분류 이벤트의 정체 | 대기 이벤트 이름이 소스에 없으면 추정만 가능합니다 |
| buffer-pool-sizing | 블록 I/O 가 InnoDB 카운터보다 2.0배인 이유 | 파일 시스템과 가상화 계층을 가르려면 게스트 커널 계측이 필요합니다 |
| bigdecimal-money | 1982년 1차 보도 원문 | 재인용밖에 없습니다 |

## D: 범위 밖 (33건)

다른 세션의 주제이거나 이 세션이 물은 질문이 아닌 것들입니다. 대표적으로 A19의
Multixact 경로, A14의 멀티XID wraparound, websocket의 브로커 경로, mdl-storm의 복제,
replica-promotion-loss의 쿼럼입니다. 지우지 않고 남기는 이유는 독자가 "이건 왜 안
다뤘나"를 물을 자리에 답을 두기 위해서입니다.

## E: 이미 해결됨 (6건)

| 세션 | 항목 | 처리 |
|---|---|---|
| A19 | 대기 샘플 파일 누적 | `run-primary.sh`에 초기화 추가 |
| B01 | 회차 2·3의 시작 부하 | `settle` 대기 추가. 다만 현재 표의 값은 결함이 있는 상태로 잰 것이라 문장은 남김 |
| A23 | PostgreSQL PITR | 2026-07-30 완료 |
| A01 | PostgreSQL 대조 | 2026-07-30 완료 |
| A06 | 기업 사례 없음 | KINTO Technologies 확보. E2 → E1·축소 |
| R04 | 기업 근거 없음 | GitLab 변경 요청 확보 |

## 처리 순서

1. **C1 남은 두 건** (index-not-used, jpa-list-api의 PostgreSQL 대조). 엔진 차이가 결론을
   바꿀 수 있는 자리라 값이 가장 큽니다.
2. **C3 + C2의 A14 failsafe**. 둘을 묶어야 성립합니다.
3. **C2의 A19 `RELEASE SAVEPOINT`**. 그 세션의 결론을 직접 보강합니다.
4. **C5**. 10편에 "못 한 것" 절 채우기. 실행이 아니라 정직성 문제라 빨리 됩니다.
5. **C4**. 반복 측정. 원본 보존을 먼저 해야 합니다.
6. **C6**. 도구 실행. Debezium 쪽이 결론을 바꿀 여지가 가장 큽니다.

## 2026-07-30 2차: "할 수 있는데 못 한다고 단정지은" 항목 재분류

145건을 다시 훑어 **불가로 읽히는 어법**(할 수 없다, 불가능, 못 합니다, 지원하지 않는다,
만들 수 없다)이 든 항목 23건을 뽑고, 그중 진짜 불가와 실제로는 안 한 것을 갈랐습니다.

### 정당한 단정 (11건, 그대로 둠)

축소 재현의 원리적 한계이거나 원문에 없는 사실입니다. 규모와 구성이 다른 재현을 원 사건
수치와 직접 비교할 수 없다는 서술, 공개 기록만으로 확정할 수 없다는 서술, 인용의 귀속을
밝히는 서술이 여기 들어갑니다.

### 실제로는 안 한 것 (12건, 문구 교정 + 일부 실행)

| 세션 | 원래 문구 | 판정 | 조치 |
|---|---|---|---|
| A23 backup-pitr | "라이선스가 걸려 이 랩에서 실행할 수 없었다" (Oracle·SQL Server) | **틀림.** SQL Server Developer 에디션이 무료 공개 | **실행 완료 (2026-07-30).** 6절 신설. Oracle 은 "아직 안 했다"로 고침 |
| buffer-pool-sizing | "이 서버에서 잴 수 없습니다" | 2코어라 안 보이는 것 | 문구 교정. 코어 많은 장비에서 재면 됨 |
| A19 subtransaction-slru | "16의 실제 동작과 같다고 단정할 수 없습니다" | PG16 이미지가 있음 | 문구 교정 |
| timeseries-partition | "같은 조건의 값으로 비교할 수 없습니다" | 관측 창을 맞추면 됨 | 문구 교정 |
| A22 index-not-used | "두 호스트의 값을 나란히 비교하지 못합니다" | 한 장비에서 다시 재면 됨 | 문구 교정 |
| A09 planner-stats-flip | "이 세션이 답하지 못합니다" | ANALYZE 수백 회로 경험 확률 산출 가능 | 문구 교정 |
| perf-insights-clone | "무엇이었는지 확인할 수 없습니다" | 샘플러가 이름을 남기게 고치면 됨 | 문구 교정 |
| F03 market-open | "이 모형으로는 답할 수 없습니다" | 풀 크기 스윕과 모형 교체 둘 다 가능 | 문구 교정 |
| uuid-page-split | "이 데이터로 주장할 수 없습니다" | 점을 더 찍으면 됨 | 문구 교정 |
| batch-cache-pollution | "이 호스트에서는 만들 수 없었습니다" | Linux 호스트라면 loop + `dm-delay` 로 가능 | 문구 교정. 장비가 바뀌면 C |
| 호스트 사양 미기록 4건 | "비교할 수 없습니다" | 재측정하면 기록이 남음 | 문구 교정. 반복 측정과 함께 해소된다고 명시 |

### 이 회차에 실행까지 마친 것

| 세션 | 항목 | 결과 |
|---|---|---|
| A23 | SQL Server `STOPAT` 시점 복구 | 복구 모델 `SIMPLE` 이면 로그 백업 거부, `NORECOVERY` 누락 시 Msg 3117, `STOPAT` 이 로그 끝보다 뒤면 `RESTORING` 에 남음 |
| R13 | 복제 대조 | 슬롯 64 는 원본 처리량 3.0배인 대신 복제본 따라잡기 79배(0.53초 대 41.83초) |
| R13 | 자동 슬롯 | 방송별 쓰기 200건마다 두 배. 행 수 11.4배 감소, 처리량 92.5% 유지 |
| R13 | 힙 혼입 제거 | `TOTAL_HEAP_MB` 고정. 결론 동일, 처리량 16.9% 증가가 읽을 수 있는 값이 됨 |
| A14 | `vacuum_failsafe_age` 대조 + 거대 테이블 | VACUUM 2.45초→0.67초, 그 뒤 조회 247배 |
| A06 | `SKIP LOCKED`/`NOWAIT`/재시도/`INSERT IGNORE` | 최종금액 2000 을 만든 것은 재시도뿐 |
| A02 | 커넥션 풀 캐스케이드 + 쓰기 부하 | 무관한 엔드포인트가 43% 실패 |
| A01 | PostgreSQL 대조, `INT UNSIGNED` | 고갈 에러 셋으로 갈림, 사전 거부는 MySQL 만 |
| A22 | PostgreSQL 대조 | 다섯 조건 중 하나만 재현 |
| B52 | PostgreSQL 커서 대조 | 처방이 두 엔진에서 정반대(117배) |
| 32편 | "못 한 것" 절 없던 10편 채움 | 구조 통일 완료 |

### 남은 C

C1 없음. C2 는 위 문구 교정 대상 대부분이 실행 대기입니다. C4(반복 측정 12건)와
C6(gh-ost, pt-osc, Debezium)은 손대지 않았습니다. Oracle 도 남았습니다.

## 2026-07-31 3차: C2·C3·C6 실행분

| 세션 | 항목 | 결과 |
|---|---|---|
| A22 index-not-used | `COLLATE` 임시 처방 | **에러 1253.** `COLLATE` 는 같은 문자셋 안에서만 콜레이션을 바꾸므로 문자셋이 다르면 문법이 성립하지 않습니다. `CONVERT` 는 통과하지만 함수 적용이라 이득 0. 스키마를 맞추는 것만이 답이고 61배 |
| A22 index-not-used | 결과 집합 크기별 배수 곡선 | LIMIT 1 에서 1,034.5배, 50만에서 1.2배. 스캔 타입은 내내 `index`/`range` 로 같습니다. **이 세션의 배수를 인용할 때 결과 집합 크기를 함께 적어야 합니다** |
| A17 uuid-page-split | 조회 비용 | 전체 스캔 2.9~4.9배. 순차 PK 는 범위 스캔에서 디스크 미스 0, uuid7 은 1,233 |
| A17 uuid-page-split | 페이지 충전율 직접 측정 | `INNODB_BUFFER_PAGE` 로 순차 92.1%, uuid4 66.1%, uuid7 63.0%. uuid4 가 50~60% 구간에 4,588 페이지를 쌓아 둔 것이 분할의 흔적. 버퍼 풀이 테이블보다 작아 표본(커버리지 74.9~99.9%) |
| R17 timeseries-partition | 파티션 수가 조회에 물리는 비용 | 프루닝 질의는 파티션 수와 무관(0.95~1.06ms). 단건 조회가 11.2배, 적재가 2.7배. **파티션의 이득은 삭제 하나** |
| R17 timeseries-partition | 관측 창 맞추기 | 480초로 맞추니 삭제 후 p95 가 5.0ms 와 5.1ms 로 같습니다. 차이는 삭제 중에 있고 관측 건수 29,971 대 203 |
| B52 jpa-list-api | 삽입 세 방식 같은 테이블 | 네 방식을 20,000행씩 빈 테이블에 |
| B52 jpa-list-api | `rewriteBatchedStatements` 끈 `batchUpdate` | 20,010 쿼리. **배치 API 를 써도 드라이버가 안 합치면 왕복이 그대로** 20.5배 손해 |
| B52 jpa-list-api | `Persistable.isNew()` 변형 | 구현해 12.63초 → 0.53초(24배), 쿼리 20,092 → 87. merge 의 SELECT 가 사라지자 배치가 묶임 |
| A01 int-pk-exhaustion | `pt-online-schema-change` | 2.6배 오래 걸리는 대신 p95 4,576ms → 16ms. 도구를 붙일 때 `caching_sha2_password` 와 **8.4 에서 제거된** `mysql_native_password` 로 두 번 걸림 |
| A06 gap-lock-deadlock | 반복 측정 4회 | 최종금액이 네 회차 모두 같음. `INSERT IGNORE` 의 성공 건수만 흔들리는데(59~60) 금액은 어차피 1000 |

### 이 회차에 밟은 결함

- **Docker VM 이 7.7GB 뿐입니다.** SQL Server 6g 를 띄운 채 A22 MySQL(4g)을 올리자 OOMKilled
  됐고 시드가 "Lost connection" 으로 죽었습니다. `cpus: 4`/`mem_limit: 4g` 세션을 동시에
  여러 개 못 띄웁니다. 세션을 하나씩 돌려야 합니다.
- **R17 파티션 실험의 날짜 폭이 파티션 수를 따라갔습니다.** 하루치 행 수가 365배 차이 나
  프루닝 이득처럼 보인 286ms → 0.87ms 가 사실은 결과 집합이 줄어든 것이었습니다.
  날짜 폭을 365일로 고정해 고쳤습니다.
- **A17 의 `INNODB_BUFFER_PAGE` 집계가 `Decimal` 이라 JSON 직렬화가 죽었습니다.**
- **A22 의 EXPLAIN 컬럼 인덱스를 잘못 읽어** `type` 과 `key` 가 전부 `None` 으로 나왔습니다.
  `partitions` 를 `type` 으로, `possible_keys` 를 `key` 로 읽고 있었습니다.
- **B52 의 `/insert` 는 POST 인데 GET 으로 준비 확인**을 해 앱이 뜬 뒤에도 405 만 받고
  90초를 기다렸습니다.
- **R17 재실행 첫 회가 빈 테이블에서 돌았습니다.** DELETE 가 0.11초로 끝나 무효였는데,
  시드를 먼저 돌려야 한다는 것을 소요 시간이 알려 줬습니다.

### 남은 것

- **`gh-ost`**: 공개 컨테이너 이미지를 못 찾았습니다(`ghcr.io/github/gh-ost` 접근 거부).
  소스를 받아 빌드하면 됩니다.
- **Debezium**: Kafka 스택이 필요해 7.7GB VM 에서 부담이 큽니다. Debezium Server 단독
  구성으로 줄이면 가능합니다.
- **Oracle** `RMAN UNTIL TIME`.
- **반복 측정 나머지**: A06 만 4회로 올렸습니다. backup-pitr, buffer-pool-sizing,
  int-pk-exhaustion, jpa-list-api, mdl-storm, reader-endpoint-skew, replication-slot-wal,
  uuid-page-split 이 남았습니다.
- **C7 나머지**: charset-timezone 의 `utf8mb4` 전환과 DST, replica-promotion-loss 의
  `AFTER_COMMIT` 비교와 복구 실행, websocket 의 재접속 폭풍, perf-insights-clone 의
  top SQL 분해.
