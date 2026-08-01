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

## 2026-07-31 4차: C6·C7·C4 실행분

| 세션 | 항목 | 결과 |
|---|---|---|
| R14 charset-timezone | utf8mb4 전환 실행 | `INPLACE` 를 에러 1846 으로 거부하고 COPY 로만. 100만 행 4.6초, 크기 불변(선언 상한만 바뀜). `VARCHAR(191)` 이 767÷4 라는 것도 확인 |
| R14 charset-timezone | DST 결손·중복 시각 | 결손 `02:30` 이 에러도 NULL 도 아니고 `03:00` 과 같은 순간을 반환. 중복 `01:30` 은 EDT 쪽만 나오고 EST 쪽은 도달 불가. 저장 뒤에는 구별 불가(3,600초 차이) |
| R14 charset-timezone | 낡은 tzdata | 멕시코 하계 시간제 폐지로 2022 년 여름 오프셋 5시간, 2023 년 6시간. tzdata 2022b 이전이면 둘 다 5 |
| R01 replica-promotion | `AFTER_COMMIT` 대조 | 매달린 커밋을 다른 세션이 1건 읽었고 승격 후 사라짐. `AFTER_SYNC` 는 애초에 안 읽힘. **유실량이 아니라 성격이 다름** |
| R01 replica-promotion | 평상시 커밋 지연 | 세 조건이 구별되지 않음(5.17/5.29/5.16ms). 같은 호스트라 복제 왕복이 커밋 비용에 묻힘. **이 환경에서는 못 잼** |
| R01 replica-promotion | 복구 경로 | 유실 50행 전부 회수. 다만 옛 소스가 떠야 하고 id 가 안 겹쳐야 하고 순서가 뒤섞여도 되는 데이터여야 함 |
| F15 websocket | 재접속 폭풍 | 정상 구독자 p95 가 세 조건 모두 1ms. **절단은 재접속에도 버팀.** 다만 느린 구독자 수신량이 재접속 횟수에 비례(173KB→511KB→1,250KB) |
| R12 perf-insights | top SQL 분해 | 핫 로우 UPDATE 하나가 AAS 2.41 로 전체의 81%. 대기 이벤트만으로는 "무엇이"까지이고 SQL 축이 "어느 질의가"를 답함 |
| R12 perf-insights | 미분류 이벤트 이름 | 이름을 남기도록 고쳤으나 재실행에서 0건. 처음 실행의 21% 는 재현 못 함 |
| A01 int-pk | `gh-ost` | 소스에서 빌드해 실행. 27.5초로 가장 느리지만 p95 7ms 로 가장 낮음. 트리거 대신 binlog 를 읽기 때문 |
| R04 replication-slot | Debezium | 기동은 성공, **하트비트 효과는 못 쟀음**(action.query 가 안 돎, 싱크가 병목). 건진 것은 "컨슈머가 살아 있음 ≠ 슬롯 전진" |
| R04 replication-slot | 반복 측정 4회 | 무효화 53~60초. 그때 `pg_wal` 이 128MB 와 224MB 로 갈려 최악을 상한의 3.5배로 봐야 함 |
| A23 backup-pitr | Oracle `RMAN UNTIL TIME` | 사고 전 1,500행 복구 성공. `RESETLOGS` 가 인케네이션을 만들고 옛 아카이브 로그를 새 계보에 못 씀. 네 엔진 대조표 완성 |
| A23 backup-pitr | 반복 측정 4회 | PostgreSQL PITR 네 조건이 4회 모두 동일 |
| A17 uuid-page-split | 반복 측정 3회 | 충전율은 안정(92.1% 셋), 전체 스캔은 2.5배 범위. **절대 시간 인용 금지** |

### 이 회차에 밟은 결함

- **`sqlplus` 는 한 줄에 두 문장을 두면 뒤엣것을 놓칩니다.** `DELETE ...; COMMIT;` 을
  한 줄에 써서 커밋이 안 됐고 "사고 후 1500행"이라는 틀린 값이 나왔습니다.
- **Oracle `UNTIL TIME` 은 리두가 아카이브돼야 그 시점까지 갑니다.** 안 그러면 백업
  시점까지만 되돌아갑니다. `ALTER SYSTEM ARCHIVE LOG CURRENT` 를 먼저 넣어야 합니다.
- **Debezium 의 설정 경로는 `/debezium/config` 입니다.** `/debezium/conf` 에 넣으면
  기동은 되고 설정만 안 읽힙니다.
- **앞 실험의 GUC 가 다음 실험을 오염시킵니다.** R04 에서 `max_slot_wal_keep_size=64MB`
  가 남아 Debezium 조건의 슬롯이 무효화됐고 지연이 리셋됐습니다.
- **`gh-ost` 는 Go 1.25.12 이상을 요구합니다.** 1.24 로는 빌드가 안 됩니다.
- **R12·R04·A22 의 테이블이 비어 있었습니다.** 컨테이너를 정리하면서 볼륨 없는 세션의
  데이터가 사라졌고, 시드를 먼저 돌려야 한다는 것을 소요 시간이 알려 줬습니다.

### 남은 것

- **반복 측정**: buffer-pool-sizing, int-pk-exhaustion, jpa-list-api, mdl-storm,
  reader-endpoint-skew 가 남았습니다.
- **Debezium 하트비트**: 싱크를 제대로 된 것으로 바꾸고 `heartbeat.action.query` 가 왜
  안 도는지부터 밝혀야 합니다.
- **Oracle 아카이브 로그 모드 전환**: 이미지가 `ARCHIVELOG` 로 출고돼 끄고 켜는 과정을
  못 밟았습니다.
- **B 등급 항목들**: 클라우드 실계정, TB급 규모, Linux 호스트가 필요한 커널·디스크 조건.

---

## 2026-07-31 5차: 하트비트·반복 측정·Oracle 전환

### R04 Debezium 하트비트 (앞 회차의 "못 쟀음"을 답으로 바꿈)

4차에서 "하트비트가 한 번도 안 돌았다"고 적었는데 **두 겹으로 틀렸습니다.**

**첫째, 하트비트는 돌고 있었습니다.** 유휴 데이터베이스에 같은 설정으로 60초를 돌리니
19행이 들어왔습니다. exp3 의 조건 A 가 `watch_log` 에 90초 동안 초당 4천 행을 넣었고,
조건 B 는 컨테이너를 새로 띄우므로 오프셋 파일이 비어 초기 스냅샷부터 다시 시작합니다.
하트비트는 스트리밍 단계에 들어가야 발동하는데, 느린 싱크 때문에 스냅샷이 관측 창
90초를 다 잡아먹었습니다. **안 돈 것이 아니라 그 단계에 닿지 못했습니다.**

**둘째, 스냅샷을 걷어 내니 하트비트가 90초에 29번 도는데도 지연이 그대로 자랐습니다.**
`pg_publication_tables` 를 열어 보니 `watch_log` 한 줄뿐이었습니다.
`publication.autocreate.mode=filtered` 는 `table.include.list` 의 테이블만으로
publication 을 만들고, 하트비트 테이블은 거기 없습니다. 그러면 `action.query` 의 INSERT 를
pgoutput 이 걸러 내고, Debezium 은 자기가 만든 쓰기를 받지 못하고, `restart_lsn` 이
제자리입니다. **하트비트 테이블에는 행이 쌓이고 로그에도 경고가 없어 정상으로 보입니다.**

90초 관측, 슬롯 지연 증가분:

| 조건 | 하트비트 | `action.query` | publication | 증가 | 하트비트 행 |
|---|---|---|---|---|---|
| A. 기준선 | 없음 | 없음 | `watch_log` | 325.3MB | 0 |
| B. 주기만 | 3초 | 없음 | `watch_log` | 324.2MB | 0 |
| C. 주기와 질의 | 3초 | 있음 | `watch_log` | 325.7MB | 29 |
| E. publication 안으로 | 3초 | 있음 | 둘 다 | **33.5MB** | 29 |
| D. 대조: 대상이 바쁨 | 없음 | 없음 | `watch_log` | 39.7MB | 0 |

A·B·C 가 구별되지 않고, E 가 대조군 D 와 같은 수준입니다.

### 이 회차에 밟은 결함

- **슬롯을 지웠다고 믿으면 앞 조건이 다음 조건으로 샙니다.** `docker rm -f` 뒤에도
  PostgreSQL 이 walsender 의 죽음을 알아채기까지 잠깐 걸려 `pg_drop_replication_slot` 이
  실패합니다. 반환값을 안 보면 옛 슬롯이 남고, 다음 조건의 시작 지연이 344.5MB 로 찍힙니다.
  성공할 때까지 재시도하고 사라진 것을 확인한 뒤 넘어가도록 고쳤습니다.
- **조건 간 비교는 시작값이 아니라 증가분으로 합니다.** 시작값이 오염돼도 관측 창 안의
  증가분은 살아남습니다. 1차 실행의 C 도 증가분으로 보면 결론이 같았습니다.
- **CSV 라벨에 쉼표를 넣으면 열이 밀립니다.** 라벨을 `/` 로 바꾸고 다시 돌렸습니다.
- **결과 파일이 있어도 데이터는 없을 수 있습니다.** A08 은 컨테이너 정리로 700만 행이
  사라진 상태였고, 시드부터 다시 돌려야 했습니다(38초).

---

## 2026-07-31 6차: 32편 전수 재훑기

앞 회차들이 다루지 않은 편까지 전부 열어 "이 환경에서 실제로 되는가"를 다시 나눴습니다.
아래는 **된다고 판단해 스크립트를 쓴 항목**과 **되는데 아직 안 쓴 항목**입니다.

### 이 회차에 찾은 잘못된 항목

- **F07 nasdaq-ipo-livelock**: "취소를 큐에 모아 라운드 사이에만 반영하는 설계 같은 대안은
  구현하지 않았습니다"라고 적혀 있었는데, **해소 A(스냅샷 동결)의 구현이 정확히 그것입니다.**
  코드 주석이 "계산 중 도착한 취소는 접수만 하고 다음 라운드로 이월"이라 적고 결과 표에
  `이월취소` 열까지 있습니다. **이미 한 것을 안 했다고 적어 둔 항목**입니다.
  실제로 안 한 것(검증을 유지한 채 재계산 상한으로 확정하는 설계, 취소 우선순위 큐)으로
  문구를 바꿨습니다.

- **호스트 사양 미기록 7편**: 소급해 채우려다 `index-not-used` 가 Rocky Linux 9.6 /
  ARM Neoverse-N1 을 기록하고 있는 것을 봤습니다. 이 랩은 최소 두 장비를 오갔습니다.
  원 회차의 호스트를 이 맥으로 단정하면 틀립니다. "2026-07-31 재측정 회차는 이 호스트,
  그 이전은 기록 없음"으로 갈라 적었습니다. `tools/capture-env.sh` 를 새로 만들어
  `nproc`·`free` 부재(macOS)에서 조용히 빈 값이 나오던 문제도 함께 고쳤습니다.

### 스크립트를 쓴 항목 (큐에 걸림)

| 세션 | 항목 |
|---|---|
| A08 | 콜드 출발, 쓰기 혼합 축소, 코어 수, 리드어헤드 카운터, 인스턴스 8 |
| A14 | 13 대 17 대조, 멀티XID 경로, failsafe 반복 3회 |
| A18 | `pg_waldump` 로 레코드·FPI 분해, autovacuum off, v10 분리, 압축 대조 |
| A22 | `CONVERT` 방향, 조건별 곡선, 선행 와일드카드 재설계 |
| R03 | 반복 3회, 인스턴스별 쿼리 수, `maxLifetime` 분리 |
| R17 | MDL 대조군, `LOCK=NONE`, `OPTIMIZE TABLE` |
| F02 | 설계 넷(문장/행/전이 테이블/물질화) 비용과 직렬화 |
| F07 | 상한 1초·10초·60초 스윕 |

### 되는데 아직 스크립트를 안 쓴 항목

**없습니다.** 2026-07-31 에 전부 작성해 큐에 걸었습니다. 아래가 그 목록입니다.

| 세션 | 스크립트 | 잡는 항목 |
|---|---|---|
| A06 gap-lock | `scripts/exp-extra.py` | 획득 순서 엇갈림, 락 수 반복, 백오프 네 방식, `SKIP LOCKED` 가 통하는 큐 |
| A08 buffer-pool | `scripts/run-extra.sh` | 콜드 출발, 쓰기 혼합 축소, 코어 수, 리드어헤드, 인스턴스 8 |
| A09 planner-stats | `scripts/exp-probability-autoanalyze.sh` | `null_frac=1` 확률 200회, 한 컬럼만 target, 자동 analyze 방아쇠 |
| A14 xid-wraparound | `scripts/exp-version-diff.sh` | 13 대 17, 멀티XID 경로, failsafe 반복 |
| A18 write-amplification | `scripts/exp2-waldump.sh` | `pg_waldump` 분해, autovacuum off, v10 분리, 압축 대조 |
| A19 subtransaction | `scripts/exp-version-and-under64.sh` | 16 대 17, 활성 63 조건 |
| A22 index-not-used | `scripts/exp-convert-side.py` | `CONVERT` 방향, 조건별 곡선, 와일드카드 재설계 |
| A23 backup-pitr | `scripts/exp6-oracle-archivelog.sh`, `exp7-logical-vs-physical.sh` | 아카이브 로그 전환, 논리 대 물리 복원 |
| B31 threadlocal | `scripts/exp-tomcat-and-oomkill.sh` | 실제 Tomcat 재배포, 커널 OOM-Kill, 사이클 반복 |
| B43 expand-contract | `scripts/exp-backfill-evidence.sh` | 백필 지연의 양성 증거, VACUUM 회수, 비율 반복 |
| B52 jpa-list-api | `scripts/exp-insert-extra.sh` | `batch_size` 스윕, 큰 테이블 삽입, MySQL 타이브레이커 |
| F01 hanmac | `spring/` 의 `/orders/leaky`, `/orders/leaky-independent` | 가드에 구멍이 있을 때, 임계값 스윕 |
| F02 ghost-shares | `sql/08-designs.sql`, `scripts/run-designs.sh` | 설계 넷 비용, 증감 구분, 직렬화 |
| F03 market-open | `scripts/exp-pool-sweep.sh` | 풀 크기 스윕, `max-threads` 반복 |
| F07 nasdaq | `scripts/run-cap-sweep.sh` | 상한 1초·10초·60초 |
| F13 matching | `app/Principles.java` | 원칙 넷, 동시호가 예외 |
| F17 bigdecimal | `app/SeedSweep.java` | 걸음별 반올림 방향, 시드 30개 |
| R01 replica-promotion | `scripts/exp-after-commit-load.sh` | `AFTER_COMMIT` 부하 아래 |
| R02 failover-dns | `scripts/exp-permanent-and-readonly.sh` | 영구 캐시, 읽기 전용 승격 구간 |
| R03 reader-skew | `scripts/exp-repeat-load.sh` | 반복 3회, 인스턴스별 쿼리 수, `maxLifetime` 분리 |
| R04 replication-slot | `scripts/exp4-heartbeat.sh` | 하트비트 다섯 조건 |
| R12 perf-insights | `scripts/exp-lock-alternatives.py` | 락 판별 세 방법, top SQL 반복 |
| R13 slotted-counter | `scripts/exp-uniform-and-repeat.sh` | 고른 부하의 자동 슬롯, 문턱 스윕, 복제 반복 |
| R14 charset-timezone | `scripts/exp-write-and-jdbc.sh` | 전환 중 쓰기, 두 tzdata 한 서버, 자바의 DST |
| R16 batch-cache | `scripts/exp-sustained.sh` | 지속 스캔 반복 횟수 기록 |
| R17 timeseries | `scripts/exp-mdl-control.sh` | MDL 대조군, `LOCK=NONE`, `OPTIMIZE TABLE` |

실행은 Docker VM 이 7.7GB 뿐이라 순차 큐로 돕니다. 결과가 나오는 대로 각 세션의
README 와 블로그 글에 절을 붙입니다.

### 이 환경에서 안 되는 것으로 남는 것

클라우드 실계정(RDS·Aurora·CloudWatch), TB급 규모, Linux 호스트가 필요한 커널·디스크
조건(loop 장치, `dm-delay`, 블록 I/O 스로틀링), 1차 자료 확보(의결서·판결문·지면 원문),
그리고 공개된 적 없는 사내 원인 분석입니다.

## 2026-07-31 7차: 큐를 돌리며 드러난 것

6차에서 쓴 스크립트를 순차 큐로 돌렸습니다. **결과보다 실패가 많았고, 실패의 형태가
전부 같았습니다.** 에러가 안 나고 결과 파일이 정상 모양으로 남습니다. 하루에 같은
유형을 열 번 밟았고 CONVENTIONS §11 에 표로 정리했습니다.

### 결과가 앞 결론을 뒤집은 것

- **A19**: "16 이 17 보다 3.3배 느리다" 는 값이 `pgbench -d spoon` 때문이었습니다.
  PostgreSQL 16 의 pgbench 에서 `-d` 는 `--dbname` 이 아니라 `--debug` 입니다. 16 쪽만
  질의마다 로그를 뱉었고 결과 파일이 100MB 를 넘겨 GitHub 푸시까지 막혔습니다.
  dbname 을 위치 인자로 옮기니 두 버전이 **1.00배로 같습니다.** 17 의 뱅크 단위 SLRU
  락은 SLRU 읽기가 백만 건대인 조건에서만 1.16배로 벌어집니다.

- **A23**: "논리 복원 0.06초" 로 물리보다 75배 빨랐던 값은 앞 회차의 물리 복원이
  복구 인스턴스의 데이터 디렉터리를 갈아엎어 논리 복원이 0행을 돌려준 결과였습니다.
  패스를 나누고 행 수 확인을 넣으니 논리 0.88초, 물리 3.93~4.29초입니다. 방향은 같지만
  배수가 75배에서 4.5배로 바뀝니다.

- **A06**: "인덱스를 붙이면 락이 줄어든다" 가 REPEATABLE READ 에서만 맞습니다.
  READ COMMITTED 에서는 11개가 21개로 **늘어납니다.**

- **R13**: 자동 슬롯의 판정 지표가 슬롯 합이 아니라 방송당 최대 슬롯입니다. 합으로 보면
  zipf 2,115 대 uniform 2,010 으로 0.95배라 "조절이 안 된다" 로 읽히는데, 방송당 최대는
  64 대 4 입니다. 분포가 완전히 다른데 합이 우연히 가깝습니다.

### 조건이 안 선 채로 "성공" 이 나온 것

- **R01**: 반동기가 안 켜진 채로 돌아 "유실 0건" 이 나왔습니다. 성공처럼 읽히는 실패입니다.
  확인을 넣었더니 이번엔 조건마다 `RESET REPLICA ALL` 이 다음 조건의 복제를 끊는 것이
  드러났습니다.

- **R02**: `read_only=1` 을 확인까지 하고 돌렸는데 페일오버 +5.5초에 쓰기가 성공했습니다.
  해제는 +25초였습니다. **`read_only` 는 SUPER 나 CONNECTION_ADMIN 을 가진 계정에
  적용되지 않고, 이 랩의 앱은 root 로 붙습니다.** 설정값 확인은 통과하고 조건만 안 섰습니다.
  `super_read_only` 로 바꾸고 앱과 같은 계정의 쓰기 탐침을 넣었습니다.
  이건 실패한 측정이 아니라 그 자체로 운영 함정입니다. 승격 절차가 `read_only` 만 켜면
  관리 권한으로 붙는 앱은 스탠바이에 계속 씁니다.

- **F03**: 호스트 상태를 기록하는 한 줄의 `nproc` 이 macOS 에 없어 `set -e` 가 실행을
  끊었습니다. k6 가 아예 안 돌았고 결과 표는 모든 조건 0.0ms 였습니다.

### 이 회차에 새로 쓴 스크립트

| 세션 | 스크립트 | 잡는 항목 |
|---|---|---|
| A01 int-pk | `scripts/exp6-size-bytes.sh` | INT 와 BIGINT 크기 차이를 바이트로, 세컨더리 인덱스 몫 |
| A17 uuid-page-split | `scripts/exp-charset-and-secondary.py` | 세컨더리 인덱스 비용, CHAR(36) 문자셋 분리 |
| R17 timeseries | `scripts/exp-mdl-repeat-and-optimize.sh` | MDL 대조군 3회, 데이터가 든 OPTIMIZE TABLE |

앞의 둘은 "크다" 고 적어 놓고 얼마나 큰지는 안 잰 자리이고, R17 은 빈 표를 재구축한
205밀리초를 회수 비용으로 쓰고 있던 자리입니다.

### 7차 큐를 다 돌린 결과 (2026-07-31 19:41 종료)

23단계 전부 완료입니다. 아래 열여섯 편에 절이 붙었고 블로그까지 반영·배포했습니다.

| 편 | 새로 답한 것 |
|---|---|
| A01 int-pk | INT 대 BIGINT 가 행당 4.21바이트, 세컨더리 인덱스가 있으면 4.91바이트 추가. INT 와 INT UNSIGNED 는 바이트까지 동일 |
| A06 gap-lock | 순서 엇갈림은 RC 로 내려도 남음. 인덱스가 RC 에서는 락을 늘림(11→21). 백오프 여덟 조건 차이 3%. `SKIP LOCKED` 는 큐에서 최고 |
| A17 uuid | 세컨더리 인덱스 하나가 `CHAR(36)` PK 에서 3.1배. `CHAR(36)` 대가는 폭 87%, 문자셋 13% |
| A19 subtransaction | 16 과 17.5 가 네 조건에서 동일. 뱅크 락은 SLRU 읽기 백만 건대에서만 값을 함 |
| A22 index-not-used | `CONVERT` 를 큰 쪽에 붙이면 109배 빨라짐(조인 순서가 뒤집힘). 콜레이션은 곡선이 없음. 와일드카드 재설계 17.2배 |
| A23 backup-pitr | 논리 복원이 물리보다 4.5배 빠름. Oracle ARCHIVELOG 전환 11~12초 |
| F03 market-open | 집계 p95 가 평평한 뒤에 풀 10 이 48%를 버리고 있었음. 스레드 800에서 p95 6.7배 |
| F15 websocket | `direct` 는 느린 구독자 한 명에서 포화. 절단은 넷까지 견딤 |
| R01 replica-promotion | `AFTER_COMMIT` 이 읽힌 8건 전부 유실. `AFTER_SYNC` 는 0 |
| R02 failover-dns | 영구 캐시는 관측 창 안에 못 넘어감. 읽기 전용 구간 20.9초 |
| R12 perf-insights | 대기가 0 이어도 판별 비용 1.3~2.8ms |
| R13 slotted-counter | 슬롯 합이 방향을 뒤집음. 원본 3.15배의 값을 복제본이 40.85초로 치름 |
| R17 timeseries | `DATA_FREE` 4MB 인데 `OPTIMIZE` 가 243MB 회수 |

**이 회차의 교훈은 하나로 모입니다.** 큐를 돌린 23단계 중 열두 번이 "에러 없이 정상
모양의 결과 파일" 로 실패했습니다. 그중 다섯은 **성공처럼 읽히는 숫자**였습니다.
R01 의 "유실 0건" 이 네 번, F03 의 "차단 0건" 이 한 번입니다.

**아무 일도 안 일어나면 지표가 가장 좋습니다.** 유실 0, 차단 0, 지연 0.0ms 는
조건이 안 섰을 때 나오는 값과 완벽하게 성공했을 때 나오는 값이 같습니다.
그래서 0 을 결과로 쓰려면 조건이 섰다는 증거가 반드시 함께 있어야 합니다.

## 2026-07-31 8차: 남은 192건 재훑기

32편의 "못 한 것" 을 전부 뽑아 192건을 나열하고, 이 환경에서 되는 것만 골랐습니다.
13건을 새로 잡았고 12편에 절이 붙었습니다.

| 세션 | 잡은 항목 | 결론 |
|---|---|---|
| A01 int-pk | 크기 차이를 바이트로 | 행당 4.21B, 세컨더리 인덱스가 있으면 +4.91B |
| A09 planner-stats | 플래너 시간 직접 측정 | 통계를 231배 늘려도 안 늘어남. 앞 절의 표현이 근거 없었음 |
| A17 uuid | 세컨더리 인덱스, 문자셋 분리 | 인덱스 하나가 3.1배. `CHAR(36)` 대가는 폭 87%, 문자셋 13% |
| A18 write-amp | 압축 넷, FPI 분해 | **`on`(=pglz) 이 최악.** lz4 가 같은 압축률을 +2% 에 |
| A22 index-not-used | OR 과 index merge | `UNION` 이 전체 스캔 대비 24.2배 |
| A23 backup-pitr | MySQL 세 구간 5회 | 복원이 RTO 의 79.3% |
| B31 threadlocal | 터지기 전 GC 압박 | **그 구간이 없음.** 전조 없이 터짐 |
| B52 jpa-list | 무작위 id 삽입 | 시간은 15% 차이인데 크기가 26배 |
| F02 ghost-shares | 동시 세션 스윕 | (스크립트 작성, 스키마 가드 추가) |
| F07 nasdaq | 상한 하나씩 갈라 재기 | 두 상한이 같은 지점. 하나만 풀면 다른 하나가 잡음 |
| F15 websocket | 느린 구독자 1·2·4 | `direct` 는 한 명에서 포화, 절단은 넷까지 견딤 |
| F17 bigdecimal | 곱셈·나눗셈 반올림 | 곱셈에서 `HALF_EVEN` = `HALF_UP`. `divide` 94.9% 예외 |
| R03 reader-skew | `maxLifetime` 다섯 점 | 캐시를 끄면 축이 아님 |
| R04 replication-slot | 물리 복제 슬롯 | 논리 35배, 물리 36배로 같음(9차에서 51배·52배는 CSV 컬럼 밀림으로 판명) |
| R12 perf-insights | 대기 없는 구간 | 대기가 0 이어도 1.3~2.8ms |
| R14 charset-tz | JDBC 왕복 | 왕복만으로는 안 보임. 결손 시각은 TIMESTAMP 가 거부 |
| R17 timeseries | MDL 3회, `OPTIMIZE` | `DATA_FREE` 4MB 인데 243MB 회수 |

### 예상이 틀린 것 셋

이 회차의 값 중 셋이 만들 때 세운 가설을 반박했습니다.

- **B31**: "터지기 전에 GC 압박으로 느려진다" 를 재려고 만들었는데 그 구간이 없습니다.
  Metaspace 가 42배 늘어 터지는데 응답 시간이 끝까지 평평합니다. Metaspace 가 차면
  GC 가 클래스 언로드를 시도하고, 누수면 언로드할 게 없어 바로 OOM 으로 갑니다.
- **F17**: "곱셈은 복리로 더 벌어진다" 가 틀렸습니다. 29.984 대 29.960 으로 같습니다.
- **A09**: 2절에 "그것을 읽는 플래너의 시간" 을 아낀다고 근거 없이 적었는데, 실측은
  target 1000 까지 차이가 없습니다.

### 남은 것

190건입니다. 12건을 지웠는데 총계가 2건만 준 것은 절마다 새로 생긴 한계를 함께
적었기 때문입니다. 남은 것의 대부분은 이 환경에서 안 되는 것입니다.

- 클라우드 실계정(RDS·Aurora·CloudWatch·PI 화면)
- TB급 규모와 21억 행
- 1차 자료(의결서·판결문·지면 원문·사내 원인 분석)
- 초기 회차의 호스트 사양(그때 안 남긴 것이라 소급 불가)
- Linux 호스트가 필요한 커널·디스크 조건
- 별도 세션이 맞는 주제(gh-ost 컷오버, STOMP, Netty, Multixact, 분산 매칭)

### 이 회차에 밟은 결함

여섯입니다. 전부 "에러가 안 나고 정상 모양의 결과가 남는" 유형입니다.

| 자리 | 무엇이 조용히 어긋났나 |
|---|---|
| A22or 적재 (A22) | 적재를 다른 스크립트에 맡겼는데 단계 순서상 이쪽이 먼저 와서 항상 멈췄다 |
| F02 스키마 (F02) | 함수 존재만 확인하고 표는 안 봐서, 전 세션이 "relation does not exist" 를 찍으며 돌고 벽시계만 남았다 |
| `GTID_PURGED` (A23) | 첫 회차의 binlog 적용이 GTID 를 남기자 2회차부터 덤프 복원이 통째로 멈췄다. "복원 후 0행" |
| `mysqlbinlog` 표준입력 (A23) | 스트림은 되감을 수 없어 `--start-position` 이 안 먹는다. "적용 0행" |
| `mysqlbinlog` 부재 (A23) | `mysql:8.4` 이미지에 없다. 1절이 이미 알고 별도 컨테이너를 쓰고 있었는데 그대로 불렀고 `command not found` 가 `2>&1` 에 삼켜졌다 |
| OOM 뒤 표 출력 (B31) | 표본을 모아 끝에 찍으니 그 출력이 다시 할당을 요구해 또 OOM 이 났다. 누수 조건의 표가 통째로 안 남았다 |

---

## 2026-08-01 9차: 발행 수치와 결과 파일의 전수 대조

앞 여덟 회차는 "무엇을 더 잴 것인가"를 물었습니다. 이 회차는 **이미 발행한 값이 지금
결과 파일과 맞는가**를 물었습니다. 물음이 바뀐 이유가 있습니다. 재실행을 거듭하면서
`results/` 는 덮였는데 글의 표는 안 따라간 자리가 쌓였고, 결정적인 열(WAL 바이트, 히트율,
페이지 수)은 회차가 바뀌어도 같아서 표 전체가 멀쩡해 보였습니다.

### 찾은 것

| 세션 | 무엇이 어긋났나 |
|---|---|
| R04 | CSV 라벨의 쉼표로 `csv.DictReader` 컬럼이 밀려 WAL 증가분 자리에 종료 시점 크기가 들어갔다. 51배·52배가 아니라 **35배·36배**. 흔적은 요약표의 "상한" 칸이 `-1` 이 아니라 `logical` 인 것으로 남아 있었다 |
| R02 | 기본값 조건 첫 실행분에 30초짜리 시계 불연속이 있어 헤드라인 세 수치가 전부 그 안에 있었다. 3회 재측정(360표본 전부 시계 일치)으로 **복구 23.65~23.78초**. 재해석이 20초에 오는 것은 앱이 기동 때 이름을 풀고 10초 뒤 페일오버가 나기 때문이고, 얹히는 것은 캐시 30초 전부가 아니라 남은 몫이다 |
| R02 | "해석 실패 구간"은 없었다. `resolved` 가 빈 표본이 0건이고 실제로는 프로브 무응답 1건이었다. **"응답이 없다"와 "필드가 비었다"는 다른 사건이다** |
| R12 | 대기 분해가 전부 `cpu` 인 것을 InnoDB 행 락이 그 계층에 없기 때문이라고 적었는데 틀렸다. 그 실행에서 `%waits%` 소비자가 꺼져 있었고, **같은 세션이 앞에서 문서화한 함정을 두 번째로 밟고 그럴듯한 엔진 내부 설명으로 덮은 것**이다 |
| A08 | 쓰기 20% 조건의 79.5ms 가 결과 파일 어디에도 없다. 원자료는 27.1ms 이고 이것은 읽기 전용 회차의 4.7~49.3ms **안에** 들어간다. 방향까지 반대인 결론을 없는 숫자로 세워 뒀다 |
| F15 | 재접속 세 조건이 같은 결과 파일 이름을 써서 마지막 하나만 남아 있었다. 라벨을 갈라 재실행하니 100ms 조건이 2회가 아니라 **8회**(1,000ms 의 6회보다 많다) |
| F13 | 병렬 위반 열 열 칸이 전부 폐기 실행분. 원자료가 이미 "스케줄링 잡음이라 방향을 읽으면 안 된다"고 적어 둔 열이라 결론은 유지 |
| B43 | 백필 양성 증거 표가 재실행 전 값. read 블록이 170,528~194,692 가 아니라 185,040~194,424 |
| A09·B52·R16·R01·R03·R13·R14·R17 | 같은 유형. 재실행이 결과 파일만 덮고 글은 안 고친 자리 |
| F01 | 동시성 실험이 돌아서 결과가 있는데 글에 절이 없고 "못 한 것"에만 "측정하지 않았습니다"가 남아 있었다. 8절로 넣었다 |

### 고치려다 되돌린 것

**A02 는 고칠 것이 없었습니다.** 검사기가 표의 숫자를 `results/` 에서 못 찾아 후보로
올렸는데, 발행값 네 칸이 전부 `timeline` 의 0~24초 평균이고 네 회차가 일관됩니다.
`median_qps` 로 바꿨다가 원복했고, 어느 통계인지 표 위에 명시했습니다.
A19 스윕과 A08 회차 표도 같은 이유로 낡아 보였지만 원자료에서 재계산하니 정확히
일치했습니다. **문자열이 없다는 것은 낡았다는 증거가 아닙니다.** 계산값과 반올림은
파일에 그 형태로 안 남습니다.

### 남긴 도구

| 도구 | 무엇을 보는가 |
|---|---|
| `tools/check-published-numbers.py` | 표의 숫자가 그 세션 `results/` 에 있는가 |
| `tools/check-section-refs.py` | "N절이 ...라고 적었다"가 실제로 그 절을 가리키는가 |
| `tools/check-writing.py` | 문중 대시·이모지·해요체·번역투·대비 프레임 |

셋 다 **판정이 아니라 후보 목록**입니다. 파생값과 반올림은 후보로 올라오므로 사람이
원자료에서 재계산한 뒤에만 손대야 합니다. 그 이유를 각 파일 머리에 적었습니다.

### 문체

문중 대시 0건, 해요체 0건, 번역투 0건입니다. 대비 프레임 426건은 대부분 "원인은 락이
아니라 버퍼 경쟁" 처럼 발견 자체를 담고 있어 그대로 뒀고, 막연한 한정사를 낀 수사적
형태는 1건이었습니다. 굵은 선언 문단이 다섯 개 넘게 잇달아 반복되던 다섯 구간의 리듬을
흩었습니다. R02 는 이번에 클라우드 절을 넣으면서 일곱 연속이 됐던 자리입니다.

### 이 회차의 교훈

앞 회차들이 "0 은 조건이 안 섰을 때와 성공했을 때가 같은 모양" 을 배웠다면, 이 회차는
그 옆에 하나를 더 놓습니다. **재실행은 결과 파일과 글을 함께 바꿔야 하고, 안 그러면
글이 저장소에 반박당합니다.** 리뷰어가 글 마지막 줄의 링크를 따라가면 그 자리를 만납니다.
발행 전에 표의 숫자를 `results/` 에서 찾는 검사를 넣은 이유입니다.

### 남은 것

- **B43 락 보유 5회 범위**: 재실행으로 닫았습니다. 5회 전부 로그를 통째로 남겼고 폭이
  2.3%(보유)와 3.4%(대기)입니다. 호스트가 달라 절대값은 앞 표와 못 잇지만, **배수가
  35배에서 52.5배로 올라간 것이 2절의 예고("버퍼 풀이 테이블보다 큰 장비라면 분모가
  줄어 배율이 더 커진다")를 확인합니다.** 사용자가 기다리는 시간은 10.9초에서 2.6초로
  줄었으므로, **배수와 절대 시간이 장비를 바꾸면 반대로 움직입니다.**
- **Oracle 아카이브 로그 모드 전환**: 이미 `exp6-oracle-archivelog.txt` 에 있었습니다.
  12초와 11초이고 갈리는 자리는 길이가 아니라 `MOUNT` 단계입니다. 실험은 돌았는데 글이
  "밟지 못했습니다"로 남아 있어 절을 채웠습니다. **반복 측정 5건도 이미 회차 파일이
  있었습니다.** 감사 문서 쪽 기록이 낡았던 것입니다.
- 나머지 190건은 8차와 같습니다. 클라우드 실계정, TB급 규모, 1차 자료, Linux 호스트가
  필요한 커널·디스크 조건입니다.
