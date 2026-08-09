# incident-lab

공개된 장애 사례와 널리 알려진 함정을 **로컬에서 재현하고, 고치고, 전후를 측정한** 기록입니다.

읽고 아는 것과 직접 터뜨려 본 것은 다릅니다. GitLab이 데이터베이스를 지운 사건, Cloudflare가 정규식 하나로 27분 멈춘 사건, 도요타 공장 14곳이 디스크 부족으로 선 사건을 글로만 읽으면 "백업을 검증하자", "정규식을 조심하자"는 교훈만 남습니다. 직접 재현하면 그 교훈이 어떤 조건에서 성립하고 무엇으로 막을 수 있는지가 수치로 남습니다.

이 저장소는 그 재현 기록을 모읍니다.

## 원칙

**하나. 사건을 먼저, 원리는 그 안에서.**
교과서 개념을 실습하는 저장소가 아닙니다. 실제로 터진 일을 재현하고, 그 과정에서 필요한 만큼만 내부 원리(격리수준, B-Tree, MVCC 등)를 설명합니다.

**둘. 근거 등급을 명시합니다.**
"유명한 사건"과 "널리 알려진 함정"은 다릅니다. 세션마다 등급을 붙여 과장을 막습니다.

| 등급 | 뜻 |
|---|---|
| `E1` | 기업 포스트모템·규제기관 문서 원문이 존재하는 공개 사건 |
| `E2` | 특정 사건은 아니나 벤더 공식 문서·CVE·업계 통계가 경고하는 함정 |
| `E1·축소` | 사건은 실재하나 물리·관리형 인프라가 원인이라 같은 메커니즘만 축소 재현 |

출처를 확인하지 못한 항목은 카탈로그에 올리지 않거나 폐기했습니다. 그 판단 기록은 [CATALOG.md의 검증 로그](CATALOG.md#12-근거-검증-로그-2026-07-28-브라우저-직접-확인)에 남겼습니다.

**셋. 재현되지 않으면 쓰지 않습니다.**
모든 세션은 `docker compose up` 한 번으로 같은 결과가 나와야 합니다. 실제 명령과 출력 원문을 `reproduce.md`에 그대로 남깁니다.

**넷. 예상과 달랐던 점을 반드시 적습니다.**
재현해 보면 문서와 다른 동작을 만납니다. 그 한 줄이 이 저장소에서 가장 값진 부분입니다.

## 구조

```
sessions/<트랙><번호>-<슬러그>/
├── README.md        사건 요약 → 재현 → 내부 원리 → 해소 → 재계측 → 예상과 달랐던 점
├── reproduce.md     실행한 명령과 출력 원문
├── compose.yml      재현 환경
└── results/         전후 측정 데이터·그래프
```

## 트랙

| 트랙 | 개수 | 다루는 것 |
|---|---|---|
| A | 21 | DB 내부·운영·복제 |
| B | 50 | 애플리케이션 코드·설정이 원인인 문제 |
| I | 11 | 컨테이너·커널·네트워크·배포 |
| R | 18 | 클라우드 관리형 DB(RDS·Aurora) 운영 |
| S | 12 | 검색엔진(Elasticsearch·Lucene) |
| V | 8 | 벡터 검색·RAG 품질 |
| L | 10 | LLM 서빙·에이전트·비용·보안 |
| M | 14 | 백엔드가 모바일 클라이언트를 상대할 때 |
| F | 21 | 금융·증권 도메인 |
| X | 4 | 물리 사건의 축소 재현 |

전체 목록과 재현 설계는 [CATALOG.md](CATALOG.md)에 있습니다.

## 진행 현황

| 상태 | 수 |
|---|---|
| 완료 | 35 |
| 진행 중 | 0 |
| 대기 | 134 |

<!-- 세션이 완료되면 아래에 추가 -->
- [F01 한맥 0으로 나눈 값이 주문 검증을 뚫다](sessions/F01-hanmac-divide-by-zero/) — 주문 120건 중 NaN 10건이 상하한 비교를 뚫고 접수(Infinity 10건은 상한에 걸려 거부). 킬스위치를 끄고 재니 유한성 가드 단독으로 Infinity 10 + NaN 10을 전부 거부해 비정상 접수 0건, 킬스위치는 섞은 배치에서 19건째에 발동해 정상 84건을 함께 차단. 최소 재현과 Spring 주문접수 API 재현
- [F02 삼성증권 유령주식, 원장 불변식 부재](sessions/F02-samsung-ghost-shares/) — 발행총수 30.66배 착오 입고가 제약 없이 커밋, 총량 검증 트리거와 maker-checker로 차단. 동시 입고 2세션이 트리거를 뚫는 것까지 실측
- [F03 장 시작 9시 접속 폭주](sessions/F03-market-open-connection-storm/) — HikariCP 풀 고갈로 응답 지연 폭증, 부하 차단(load shedding)으로 중앙값 3.38초를 51ms로
- [F13 매칭엔진 가격우선·시간우선 동시성](sessions/F13-matching-engine-priority/) — 변수를 하나씩만 바꾼 조건 8개를 각 51회 측정(2 vCPU). 원자 구간이 없는 조건은 체결의 27~75%가 시간우선 위반, 원자 구간을 넣은 세 조건은 153회 전부 0건. 원자 구간의 순수 비용은 1.06~1.78배이고 함께 바꾼 큐 교체가 1.4~1.8배 이득이라 해소판 전체는 기준보다 빨랐음
- [F17 부동소수점 금지, BigDecimal](sessions/F17-bigdecimal-money/) — 밴쿠버 1982 절삭 재현(60,000회에 -29.9포인트)과 double 100만 건 누적 오차, scale·RoundingMode 명시와 최소 화폐단위 long으로 해소
- [R14 문자셋·타임존 지뢰밭](sessions/R14-charset-timezone/) — utf8mb3 이모지 처리(8.4는 절단이 아니라 ? 치환), 767바이트 인덱스, CONVERT_TZ가 일별 집계를 NULL 한 줄로 만드는 것, latin1 접속의 이중 인코딩 착시까지 6종 재현
- [B52 JPA 목록 API의 세 함정](sessions/B52-jpa-list-api/) — N+1(쿼리 21개→1개), 커서 페이지네이션의 표준 문법이 MySQL에서 range 최적화를 못 받아 OFFSET보다 느린 것, saveAll이 IDENTITY와 merge 때문에 각각 다른 이유로 느린 것(INSERT 1만 회 대 SELECT 1만 회)
- [A23 백업은 있는데 복구가 안 된다](sessions/A23-backup-pitr/) — GitLab 2017의 백업 5중 실패를 앵커로 MySQL PITR을 실행. 백업만 복원하면 500건 유실, binlog를 사고 직전까지 이으면 0건. 복구를 막는 다섯 함정 중 넷을 만들면서 직접 밟았다
- [A01 정수 PK 고갈과 무중단 전환](sessions/A01-int-pk-exhaustion/) — 상한에 닿으면 범위 초과가 아니라 중복 키 에러(1062)로 나타난다. 한 방 ALTER는 실패 0건인데 12.8초 동안 쓰기가 12건만 통과(최대 12.6초 대기), expand-contract는 119초에 8,427건이 p95 3.8ms로 통과
- [A06 갭 락 데드락](sessions/A06-gap-lock-deadlock/) — "없으면 넣는다" 한 패턴이 만드는 교착. 갭 락 둘이 공존하고 그 위의 insert intention이 서로를 막는 순간을 data_locks로 포착. 원래 방식 30회 데드락이 ON DUPLICATE KEY UPDATE로 0회
- [A22 인덱스는 있는데 쿼리가 못 쓴다](sessions/A22-index-not-used/) — 형변환·문자셋·함수·선행 와일드카드·비트 연산 다섯 조건에서 인덱스를 그대로 두고 쿼리만 고쳐 최대 1,969배. 읽은 행을 EXPLAIN 추정이 아니라 Handler_read 카운터로 실측
- [A18 Uber의 PostgreSQL 쓰기 증폭](sessions/A18-uber-write-amplification/) — 인덱스 수 x fillfactor x 갱신 컬럼 9조건의 WAL·HOT 실측. 꽉 찬 페이지의 WAL이 인덱스 0·3·6·10에서 267·364·462·595MB로, 인덱스 수에 비례하지 않고 고정비 위에 인덱스당 32~34MB가 더해지는 구조. HOT 45.2%는 페이지 정원 45행 대 적재 31행의 기하학으로 설명됨. 초고 헤드라인이던 정상 상태 1.4배는 두 조건의 갱신 이력이 달라 철회
- [R03 리더 엔드포인트가 돌려줘도 한 대로 몰린다](sessions/R03-reader-endpoint-skew/) — 분산 단위가 쿼리가 아니라 커넥션이라, JVM DNS 캐시 기본값에서 풀 12개가 최대 100% 한 인스턴스로. ttl=0으로 최대 점유 83.5%가 47.9%로
- [R04 CDC 컨슈머가 죽으면 프로덕션 디스크가 찬다](sessions/R04-replication-slot-wal/) — 슬롯이 붙잡은 WAL이 120.5초에 7.0MB에서 125.8MB로 단조 증가(초당 0.99MB), 슬롯 삭제와 체크포인트로 128MB가 96MB로 즉시 회수. max_slot_wal_keep_size 64MB는 디스크를 지키는 대신 CDC를 버린다(reserved→unreserved→lost까지 41.7초, 그사이 슬롯 지연은 상한의 2.2배인 138MB까지)
- [R02 페일오버 후 DB는 살아 있는데 앱만 못 붙는다](sessions/R02-failover-dns-cache/) — DNS는 바뀌었는데 JVM이 옛 주소를 30초 더 붙잡아 복구가 49.5초. sun.net.inetaddr.ttl=0으로 5.9초. 커넥션 풀 설정은 이 구간에서 효과가 없다는 것까지 실측
- [R01 복제 지연 중 승격의 커밋 유실](sessions/R01-replica-promotion-loss/) — 성공 응답을 받은 후원 927건 중 555건이 승격본에 없음을 GTID 차집합으로 특정. 반동기는 유실 0이지만 타임아웃 강등 창에서 유실이 되살아남. Seconds_Behind_Source가 분단 후 19초간 0을 표시하는 것까지
- [R16 정산 배치의 버퍼 풀 오염](sessions/R16-batch-cache-pollution/) — 풀 스캔이 히트율을 7%까지 떨어뜨려도 NVMe에서는 p95가 안 무너짐을 실측. midpoint 방어의 실효는 워킹셋 회복 시간(15.2초 대 0.7초)에서 분리 계측
- [R17 시계열 로그 보존 삭제](sessions/R17-timeseries-partition/) — 같은 350만 행을 DELETE(20.5초, 파일은 회수는커녕 8MiB 증가)와 DROP PARTITION(0.12초, 0.35GB 회수)으로 비교. 삭제 후 p95는 방향이 뒤집혀 DELETE가 기준선 복귀, DROP이 기준선의 1.8배. 열린 트랜잭션 하나가 DDL을 막아 세우는 MDL 행렬과 프루닝 깨지는 조건 실측
- [R12 Performance Insights 클론](sessions/R12-perf-insights-clone/) — PI의 1초 샘플링·wait 분해 루프를 직접 구현. 행 락 대기가 lock이 아니라 wait/io/table/sql/handler로 표면화되고(핫 로우 구간 AAS 7.52 중 io_table 6.50, lock 0.00), data_lock_waits를 함께 세면 갈린다는 것을 실측(락 구간 평균 26.1, 콜드 IO 구간 29샘플 전부 0). CPU 구간은 부하 생성기가 DB를 못 채워(8스레드에 AAS 0.55) 검증하지 못했고 활성 세션의 21%가 미분류로 남음
- [R13 라이브 후원 카운터의 핫 로우](sessions/R13-slotted-counter/) — 카운터 갱신 아홉 변형의 처리량·정합성 동시 측정. 실패율 0%로 후원 30.9%가 사라지는 갱신 유실을 슬롯 카운터로 해소
- [A09 300행짜리 표본이 1,200만 행을 100% NULL이라고 단정했다](sessions/A09-planner-stats-flip/) — 표본 300행이 null_frac을 1로 적어 추정 1행 대 실제 2,400행, 중첩 루프로 7,734ms. statistics target 1000으로 164ms(47배)에 버퍼는 27분의 1이고, 기본값 100에서도 10회 중 1회 오판
- [B31 지우지 않은 ThreadLocal 하나가 클래스로더를 통째로 붙잡는다](sessions/B31-threadlocal-classloader-leak/) — 재배포 300회에 폐기됐어야 할 클래스로더 300개가 전부 생존, try/finally의 remove() 한 줄로 0개. Metaspace 24MB에서 3,773 사이클에 OOM, 워커 스레드를 갱신하자 이미 샌 300개도 전부 회수
- [B43 빠른 DDL과 안전한 DDL은 다르다](sessions/B43-expand-contract/) — 300만 행에 상수 기본값 ADD COLUMN은 3ms에 재작성 없이 끝나지만, 12초 트랜잭션 뒤에 줄 서면 뒤따르는 SELECT 세 건을 7~9초 막는 락 큐잉. 3단계 expand-contract로 최대 락 보유 11,316ms를 3.436ms로
- [F07 IPO 크로스가 확정되지 않는다, 데드락이 아니라 라이브락](sessions/F07-nasdaq-ipo-livelock/) — 취소가 라운드보다 촘촘히 들어오면 72회 시도 중 24회가 크로스 확정 실패, 재계산을 백 번 가까이 돌면서도 블로킹 스레드는 0개. 스냅샷 동결과 접수 컷오프로 실패 0/72, 대가는 취소가 반영되지 않은 주문 수십 건
- [F09 IB 음수 유가 가격은 양수라는 가정이 계층마다 다르게 깨지다](sessions/F09-negative-price/) — 음수 틱이 CHECK 제약에 막혀 최종가가 0.01에 멈추자 계좌 평가액이 3,764만 달러 과대계상되고 자동 청산이 발동하지 않음. 요구증거금 붕괴는 8.00달러부터 시작해 0.10달러에서 1,000계약, 하우스 증거금 고정으로 12계약
- [A08 버퍼 풀 사이징과 리사이즈의 값](sessions/A08-buffer-pool-sizing/) — 128M~2G 스윕에서 무릎 위치가 접근 분포로 갈리는 것(핫셋 512M, 균등 1536M), 히트율 77%가 실제로는 조회당 0.889페이지 디스크행이라는 것, flush_method만 바꿔 같은 히트율에 처리량 2.6배가 갈리는 것
- [A17 UUIDv7로 바꿨는데 테이블이 안 줄었다](sessions/A17-uuid-page-split/) — PK 다섯 가지로 120만 행 적재. 밀리초 안 카운터가 없는 UUIDv7은 충전율 54.7%로 UUIDv4(56.7%)와 같고, 카운터를 넣으면 91.4%로 순차 BIGINT(91.9%)와 같아짐. 대가가 공간과 시간으로 갈라져 카운터 없는 UUIDv7은 적재 중 디스크 읽기 115쪽, UUIDv4는 12,613쪽
- [A25 이미 써 버린 재화를 어떻게 회수하는가](sessions/A25-currency-reclaim-procedure/) ([운영 절차서](sessions/A25-currency-reclaim-procedure/RUNBOOK.md)) — 회수 대상 6만 계정 중 2만은 잔액이 회수액보다 적다. CHECK 제약이 Msg 547 로 회수를 막고, 음수 잔액과 빚 컬럼 두 설계가 회수액 1,839,974,000 으로 같되 상계 방식이 갈린다. 4,000행 배치로 승격 0회, 다섯째 배치에서 죽여도 같은 batch_id 로 이어 돌려 이중 회수 0·누락 0, 동시 사용 중에도 회수액이 대상과 정확히 일치. 잘못된 목록으로 회수한 뒤 BEGIN TRAN WITH MARK 지점으로 복원해 잔액 합계가 보정 전과 일치
- [A24 셀 수 없으면 롤백 말고는 선택지가 없다](sessions/A24-currency-anomaly-detection/) ([운영 절차서](sessions/A24-currency-anomaly-detection/RUNBOOK.md)) — 재화 원장 2,000만 행에서 이상 지급 탐지 3안을 정답지와 대조. 참조 대사와 개봉 대사는 이상 계정 60개를 오탐 0으로 적발, 통계 이탈은 같은 60개를 다 잡으면서 정상 헤비 이용자 40개를 함께 지목해 오회수를 만든다. 회수 대상을 계정·금액까지 정확히 산정(360,000). 조사 쿼리 논리 읽기는 인덱스 없이 229,614인데 조건 컬럼 reason이 빠진 640MB 인덱스는 228,399로 그대로였고, reason을 넣자 496, 필터드는 크기 절반에 482. 필터드는 조회 쪽 SET 옵션이 안 맞으면 에러 없이 무시돼 229,614로 돌아간다
- [A04 5,000이라고 적힌 임계값이 6,250에서 발동했다](sessions/A04-mssql-lock-escalation/) ([운영 절차서](sessions/A04-mssql-lock-escalation/RUNBOOK.md)) — 문서가 말하는 5,000행에서 승격이 안 일어나고 이분 탐색으로 찾은 경계는 테이블 락 6,249개(확장 이벤트가 적은 escalated_lock_count 와 일치). 승격하면 보정 대상이 아닌 계정 조회가 18.5초 정지(LCK_M_IS), 4,000행 배치 분할은 승격 0회에 정지 0회. 유지 락은 5개 대 4,015개 대 200,548개. 규모를 40만행으로 키우면 엔진이 페이지 락을 골라 승격 자체가 사라지고, 통계가 없으면 같은 6,231행이 승격. 갱신 컬럼에 보조 인덱스가 하나 붙으면 행당 KEY 락이 2개 더 붙어(옛 자리 삭제 + 새 자리 삽입) 경계가 2,907행으로 내려가므로, 배치 처방은 인덱스 수를 세고 정해야 함
- [A02 0.09초짜리 DDL이 20초 동안 조회를 세웠다](sessions/A02-mdl-storm/) — 롱 트랜잭션 단독은 정지 0초, ADD COLUMN 단독은 0.09초에 완료. 둘이 겹치면 20초 동안 조회가 한 건도 완료되지 않고 최대 대기 20,021ms. lock_wait_timeout 2초로 정지가 2초로 줄고 DDL은 1205로 실패. metadata_locks에 EXCLUSIVE:PENDING 뒤로 SHARED_READ:PENDING이 줄 선 것까지
- [F15 느린 구독자 하나가 시세를 멈춘다](sessions/F15-websocket-slow-consumer/) — 팬아웃 구현 11가지를 각 3회. 무제한 큐는 86초에 OOM(힙 128MB 중 95.6MB가 느린 구독자 몫)이지만, 큐 없는 직접 전송은 힙이 45.5MB로 멀쩡한 채 발행량만 2,909에서 142/s로 주저앉고 정상 구독자 5명의 수신도 40분의 1이 됨. conflation+절단으로 2,936/s에 느린 구독자도 유지
- [A19 SAVEPOINT 하나가 만드는 성능 절벽](sessions/A19-subtransaction-slru/) — GitLab 2021의 Nessie 장애. 프라이머리에서 두 경계를 분리 계측했다. 서브트랜잭션 64개까지는 pg_subtrans 조회가 정확히 0건, 1만 개면 조회 761만 건이 전부 캐시 적중해 TPS는 6%만 떨어지고, XID 범위가 SLRU 32페이지(65,536개)를 넘긴 50만 개에서 미스율 22.4%에 TPS 31% 하락·대기의 47%가 SubtransSLRU. PG17의 subtransaction_buffers를 4MB로 올리면 조회 778만 건이 전부 적중해 기준선의 96%로 복귀. GitLab이 겪은 스탠바이 절벽은 재현 실패로 남기고, XLOG_XACT_ASSIGNMENT가 서브트랜잭션 64개마다만 기록된다는 것까지 pg_waldump로 확인
- [A14 트랜잭션 ID가 바닥나 읽기 전용이 된다](sessions/A14-xid-wraparound/) — Sentry 2015 사고를 앵커로 PG17에서 실제 정지 지점까지 도달. 원인은 vacuum을 끈 것이 아니라(autovacuum=off여도 wraparound 방지 vacuum은 돈다) 버려진 prepared transaction이 동결을 막은 것. 경고는 4,000만 개 지점, 정지는 300만 개 지점으로 Sentry가 인용한 100만은 PG13 이하 값. 정지 상태에서 SELECT와 VACUUM은 되고 txid_current()는 거부되며, 원인 제거 후 40초 만에 긴급 autovacuum이 template0까지 자가 복구(PG14 vacuum_failsafe_age 발동 로그 확인). 단일 사용자 모드 권고가 PG17에서 삭제된 것과 문서·소스 문구 불일치까지
- [B01 커넥션 풀 데드락, DB는 한가한데 앱만 멈춘다](sessions/B01-hikaricp-pool-deadlock/) — @GeneratedValue(AUTO)가 MySQL에서 시퀀스 테이블을 별도 커넥션으로 잠가 save() 한 줄이 커넥션 두 개를 요구한다. Hibernate 6의 allocationSize 50이 채번을 50건에 한 번으로 줄여 완전한 정지 대신 처리량이 4분의 1로 떨어지는 형태로 나타남(TPS 35.8 대 138.2). 실패율 0.5%인데 1초 초과 16건이 워커 시간의 89.1%를 먹어 p95 61ms로는 안 보인다. 널리 인용되는 위키 공식과 우아한형제들의 자체 확장을 구분

## 실행 환경

미들웨어는 세션마다 `compose.yml`에 담았으므로 Docker만 있으면 뜹니다.

- Docker / Docker Compose
- 장애 주입: Toxiproxy, Pumba, tc(netem), libfaketime
- 관측: Prometheus, Grafana

다만 호스트에서 도는 것들이 있어 세션에 따라 추가 설치가 필요합니다. 부하 생성기(k6, sysbench)와 애플리케이션 런타임이 그렇습니다. 예를 들어 R13은 Spring Boot 앱을 호스트에서 띄우므로 Java 21과 Gradle, k6가 필요합니다. 무엇이 필요한지는 각 세션의 `reproduce.md` 첫 절에 적었습니다.

## 주의

보안 세션(Log4Shell, SSRF, 역직렬화, 공급망)은 **격리된 로컬 환경에서만** 실행합니다. 외부 대상 테스트나 실제 익스플로잇 공개는 하지 않습니다. 해당 세션은 방어 검증에 필요한 최소 범위까지만 다룹니다.

## 규약

세션 작성 규약과 문서 템플릿은 [CONVENTIONS.md](CONVENTIONS.md)에 있습니다.

## 라이선스

MIT
