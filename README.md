# incident-lab

공개된 장애 사례와 널리 알려진 함정을 **로컬에서 재현하고, 고치고, 전후를 측정한** 기록입니다.

읽고 아는 것과 직접 터뜨려 본 것은 다릅니다. GitLab이 데이터베이스를 지운 사건, 삼성증권이 없는 주식을 입고한 사건, 한맥투자증권이 0으로 나눈 값으로 주문을 낸 사건을 글로만 읽으면 "백업을 검증하자", "검증 로직을 넣자"는 교훈만 남습니다. 직접 재현하면 그 교훈이 **어떤 조건에서 성립하고 무엇으로 막을 수 있는지**가 수치로 남습니다.

| | |
|---|---|
| 재현 완료 | **40세션** (A 19 · B 4 · F 8 · R 9) |
| 근거 등급 | `E1` 7 · `E1·축소` 10 · `E2` 23 |
| 문서 분량 | 약 30,000줄 (README · reproduce · RUNBOOK) |
| 발행 | [블로그 3편](#발행) |

> ### SQL Server 를 먼저 보실 분께
> 40세션 중 **SQL Server 를 직접 만진 여덟**을 한 줄씩 추린 **[→ SQLSERVER.md](SQLSERVER.md)** 가 있습니다.
> 무엇을 물었고, 무엇이 나왔고, 그래서 운영에서 무엇을 정했는지만 적어 **90초에 훑을 수 있습니다.**

---

## 원칙

**하나. 사건을 먼저, 원리는 그 안에서.**
교과서 개념을 실습하는 저장소가 아닙니다. 실제로 터진 일을 재현하고, 그 과정에서 필요한 만큼만 내부 원리(격리수준·B-Tree·MVCC 등)를 설명합니다.

**둘. 근거 등급을 명시합니다.**
"유명한 사건"과 "널리 알려진 함정"은 다릅니다. 세션마다 등급을 붙여 과장을 막습니다.

| 등급 | 뜻 |
|---|---|
| `E1` | 기업 포스트모템·규제기관 문서 원문이 존재하는 공개 사건 |
| `E1·축소` | 사건은 실재하나 물리·관리형 인프라가 원인이라 같은 메커니즘만 축소 재현 |
| `E2` | 특정 사건은 아니나 벤더 공식 문서·CVE·업계 통계가 경고하는 함정 |

출처를 확인하지 못한 항목은 카탈로그에 올리지 않거나 폐기했습니다. 그 판단 기록은 [CATALOG.md의 근거 검증 로그](CATALOG.md#12-근거-검증-로그-2026-07-28-브라우저-직접-확인)에 남겼습니다.

**셋. 재현되지 않으면 쓰지 않습니다.**
모든 세션은 `docker compose up` 한 번으로 같은 결과가 나와야 합니다. 실제 명령과 출력 원문을 `reproduce.md`에 그대로 남깁니다.

**넷. 예상과 달랐던 점을 반드시 적습니다.**
재현해 보면 문서와 다른 동작을 만납니다. 그 한 줄이 이 저장소에서 가장 값진 부분입니다. 틀린 결론도 지우지 않고 정정 기록을 남깁니다.

---

## 세션 40

각 줄은 **그 세션이 남긴 가장 중요한 발견 하나**입니다. 상세는 링크에 있습니다.

### 트랙 A. DB 내부·운영·복제 (19)

| 세션 | 발견 | 등급 |
|---|---|---|
| **[A01 정수 PK 고갈](sessions/A01-int-pk-exhaustion/)** | 상한에 닿으면 범위 초과가 아니라 **중복 키 에러(1062)** 로 나타난다. 한 방 ALTER는 실패 0건인데 초당 통과가 66.5건에서 **0.9건**으로 주저앉고 한 건은 12.6초를 매달렸다. expand-contract는 초당 70.6건에 p95 3.8ms | `E1·축소` |
| **[A02 MDL 스톰](sessions/A02-mdl-storm/)** | 0.09초짜리 ADD COLUMN이 롱 트랜잭션과 겹치자 **20초간 조회가 한 건도 완료되지 않는다** | `E2` |
| **[A04 락 승격](sessions/A04-mssql-lock-escalation/)** · [절차서](sessions/A04-mssql-lock-escalation/RUNBOOK.md) | 문서의 "5,000행"은 문장이 아니라 **인덱스 하나**를 가리키는 값이었다. 경계는 6,232행이고, 보조 인덱스가 하나 붙으면 2,907행으로 내려간다 | `E2` |
| **[A06 갭 락 데드락](sessions/A06-gap-lock-deadlock/)** | "없으면 넣는다" 한 패턴이 만드는 교착. 30회 데드락이 `ON DUPLICATE KEY UPDATE`로 **0회** | `E2` |
| **[A08 버퍼 풀 사이징](sessions/A08-buffer-pool-sizing/)** | 무릎 위치는 용량이 아니라 **접근 분포**가 정한다(핫셋 512M, 균등 1536M). `flush_method`만 바꿔 같은 히트율에 처리량 2.6배 | `E2` |
| **[A09 통계 표본](sessions/A09-planner-stats-flip/)** | 표본 300행이 `null_frac`을 1로 적어 1,200만 행을 100% NULL로 단정. 7,734ms가 statistics target 1000으로 **164ms(47배)** | `E1` |
| **[A14 XID 소진](sessions/A14-xid-wraparound/)** | 원인은 vacuum을 끈 것이 아니라 **버려진 prepared transaction**. 정지 지점은 300만이고 Sentry가 인용한 100만은 PG13 이하 값 | `E1` |
| **[A17 UUIDv7 페이지 분할](sessions/A17-uuid-page-split/)** | 밀리초 안 카운터가 없는 UUIDv7은 충전율 54.7%로 **UUIDv4와 같다**. 카운터를 넣으면 91.4%로 순차 BIGINT와 같아진다 | `E2` |
| **[A18 Uber 쓰기 증폭](sessions/A18-uber-write-amplification/)** | WAL은 인덱스 수에 비례하지 않고 **고정비 위에 인덱스당 32~34MB**. 헤드라인이던 1.4배는 조건 불일치가 드러나 철회 | `E1` |
| **[A19 서브트랜잭션 SLRU](sessions/A19-subtransaction-slru/)** | 64개까지 `pg_subtrans` 조회가 정확히 0건, 1만 개는 761만 건이 전부 캐시 적중, **50만 개에서 미스율 22.4%에 TPS 31% 하락** | `E1` |
| **[A22 인덱스 미사용](sessions/A22-index-not-used/)** | 다섯 조건에서 인덱스는 그대로 두고 쿼리만 고쳐 **최대 1,969배**. EXPLAIN 추정이 아니라 `Handler_read` 카운터로 실측 | `E2` |
| **[A23 백업과 시점 복구](sessions/A23-backup-pitr/)** | **복원을 에러 없이 통과하고도 데이터가 없는 백업이 넷 중 둘.** 백업만이면 500건 유실, binlog를 사고 직전까지 이으면 0건 | `E1·축소` |
| **[A24 이상 지급 탐지](sessions/A24-currency-anomaly-detection/)** · [절차서](sessions/A24-currency-anomaly-detection/RUNBOOK.md) | 원장 2,000만 행에서 세 방식을 정답지와 대조. 짝 맞추기는 오탐 0, **통계 이탈은 정상 헤비 이용자 40명을 함께 지목**하고 5시그마에서도 53.8%가 무고 | `E1·축소` |
| **[A25 재화 회수 절차](sessions/A25-currency-reclaim-procedure/)** · [절차서](sessions/A25-currency-reclaim-procedure/RUNBOOK.md) | 4,000행 배치로 승격 0회, 다섯째 배치에서 죽여도 **이중 회수 0·누락 0**. 데드락을 엔진에 맡기면 9회 모두 게임 트래픽 쪽이 희생된다 | `E1·축소` |
| **[A26 진단 순서](sessions/A26-mssql-diagnosis/)** · [절차서](sessions/A26-mssql-diagnosis/RUNBOOK.md) | 대기 통계는 인스턴스 기동 이후 누적이라 **두 번 떠서 차분**으로 봐야 하고, 블로킹의 뿌리는 sleeping이라 `dm_exec_requests`에 안 나온다 | `E2` |
| **[A27 조인 연산자](sessions/A27-mssql-physical-join/)** | 논리 읽기가 셋 다 3,119로 같은데 **`OPTION (MERGE JOIN)`은 메모리를 Hash의 17배 요구**한다. 통계를 408배 어긋나게 해도 연산자는 안 뒤집혔다 | `E2` |
| **[A28 페이지 손상과 페이지 복원](sessions/A28-mssql-corruption-page-restore/)** | 데이터 페이지 32바이트를 0으로 덮어도 **아무 오류가 없다.** 페이지 한 장만 복원하면 손실 0, `REPAIR_ALLOW_DATA_LOSS`는 77행이 사라지고 어디에도 안 남는다 | `E2` |
| **[A29 로그 전달·페일오버](sessions/A29-mssql-log-shipping-failover/)** | 유실을 정하는 것은 기종이 아니라 **절차**다. 꼬리 로그를 뜨면 유실 0이고, 승격이 끝나도 로그인 SID가 달라 앱은 못 들어온다 | `E2` |
| **[A30 유상·무상 분리](sessions/A30-currency-paid-free-split/)** | 총 잔액은 세 모델이 같고 갈리는 것은 **답할 수 있는 질문의 수**(5개 중 단일 잔액은 1개). 소모 순서만 뒤집어도 환불 노출액이 23,333,000에서 19,333,000으로 | `E1` |

### 트랙 R. 클라우드 관리형 DB (9)

| 세션 | 발견 | 등급 |
|---|---|---|
| **[R01 승격 커밋 유실](sessions/R01-replica-promotion-loss/)** | 성공 응답을 받은 927건 중 **555건이 승격본에 없음**을 GTID 차집합으로 특정. 반동기도 타임아웃 강등 창에서는 유실이 되살아난다 | `E1·축소` |
| **[R02 페일오버 DNS 캐시](sessions/R02-failover-dns-cache/)** | DB는 살아 있는데 JVM이 옛 주소를 30초 더 붙잡아 복구가 **49.5초**. `sun.net.inetaddr.ttl=0`으로 5.9초. 커넥션 풀 설정은 이 구간에서 효과가 없다 | `E2` |
| **[R03 리더 엔드포인트 쏠림](sessions/R03-reader-endpoint-skew/)** | 분산 단위가 쿼리가 아니라 **커넥션**이라, DNS 캐시 기본값에서 풀 12개가 최대 100% 한 인스턴스로 몰린다 | `E2` |
| **[R04 복제 슬롯 WAL](sessions/R04-replication-slot-wal/)** | 죽은 CDC 컨슈머의 슬롯이 붙잡은 WAL이 120초에 7.0MB → 125.8MB로 단조 증가. `max_slot_wal_keep_size`는 **디스크를 지키는 대신 CDC를 버린다** | `E2` |
| **[R12 Performance Insights 클론](sessions/R12-perf-insights-clone/)** | 행 락 대기가 `lock`이 아니라 **`wait/io/table/sql/handler`로 표면화**된다(AAS 7.52 중 io_table 6.50, lock 0.00) | `E2` |
| **[R13 슬롯 카운터](sessions/R13-slotted-counter/)** | 갱신 아홉 변형의 처리량·정합성 동시 측정. **실패율 0%인데 후원의 30.9%가 사라지는** 갱신 유실 | `E2` |
| **[R14 문자셋·타임존](sessions/R14-charset-timezone/)** | utf8mb3 이모지가 8.4에서는 절단이 아니라 **`?` 치환**, `CONVERT_TZ`가 일별 집계를 NULL 한 줄로 만드는 것까지 6종 | `E2` |
| **[R16 버퍼 풀 오염](sessions/R16-batch-cache-pollution/)** | 히트율이 7%까지 떨어져도 **NVMe에서는 p95가 안 무너진다.** midpoint 방어의 실효는 워킹셋 회복 시간(15.2초 대 0.7초)에서 갈린다 | `E2` |
| **[R17 파티션 삭제](sessions/R17-timeseries-partition/)** | 같은 350만 행에 DELETE는 20.5초에 **파일이 회수는커녕 8MiB 증가**, DROP PARTITION은 0.12초에 0.35GB 회수 | `E2` |

### 트랙 F. 금융·증권 도메인 (8)

| 세션 | 발견 | 등급 |
|---|---|---|
| **[F01 한맥 0으로 나누기](sessions/F01-hanmac-divide-by-zero/)** | 주문 120건 중 **NaN 10건이 상하한 비교를 뚫고 접수**된다(Infinity는 걸린다). 유한성 가드 단독으로 비정상 접수 0건 | `E1·축소` |
| **[F02 삼성증권 유령주식](sessions/F02-samsung-ghost-shares/)** | 발행총수 **30.66배** 착오 입고가 제약 없이 커밋. 행 단위 CHECK는 잔고 합계를 막지 못하고, 동시 입고 2세션은 총량 트리거마저 뚫는다 | `E1·축소` |
| **[F03 장 시작 접속 폭주](sessions/F03-market-open-connection-storm/)** | 풀 고갈로 응답 중앙값이 3.38초. 부하 차단(load shedding)으로 **51ms** | `E1·축소` |
| **[F07 나스닥 IPO 라이브락](sessions/F07-nasdaq-ipo-livelock/)** | 72회 시도 중 24회가 크로스 확정 실패인데 **블로킹 스레드는 0개**. 스냅샷 동결로 0/72, 대가는 반영되지 않은 취소 수십 건 | `E1·축소` |
| **[F09 IB 음수 유가](sessions/F09-negative-price/)** | 음수 틱이 CHECK 제약에 막혀 최종가가 0.01에 멈추자 평가액이 **3,764만 달러 과대계상**되고 자동 청산이 발동하지 않는다 | `E1` |
| **[F13 매칭엔진 우선순위](sessions/F13-matching-engine-priority/)** | 원자 구간이 없는 조건은 체결의 **27~75%가 시간우선 위반**, 넣은 세 조건은 153회 전부 0건. 원자 구간의 순수 비용은 1.06~1.78배 | `E2` |
| **[F15 느린 구독자](sessions/F15-websocket-slow-consumer/)** | 무제한 큐는 86초에 OOM. 그런데 **큐 없는 직접 전송은 힙이 멀쩡한 채 발행량만 2,909에서 142/s로 주저앉는다** | `E2` |
| **[F17 BigDecimal](sessions/F17-bigdecimal-money/)** | 밴쿠버 증권거래소 1982 절삭 재현 — **60,000회에 -29.9포인트.** 절삭은 한 방향으로만 깎인다 | `E1·축소` |

### 트랙 B. 애플리케이션 코드·설정 (4)

| 세션 | 발견 | 등급 |
|---|---|---|
| **[B01 커넥션 풀 데드락](sessions/B01-hikaricp-pool-deadlock/)** | `@GeneratedValue(AUTO)`가 MySQL에서 **`save()` 한 줄에 커넥션 두 개를 요구**한다. 실패율 0.5%인데 1초 초과 16건이 워커 시간의 89.1%를 먹어 p95로는 안 보인다 | `E1` |
| **[B31 ThreadLocal 누수](sessions/B31-threadlocal-classloader-leak/)** | 재배포 300회에 폐기됐어야 할 클래스로더 **300개가 전부 생존**, `try/finally`의 `remove()` 한 줄로 0개 | `E2` |
| **[B43 expand-contract](sessions/B43-expand-contract/)** | 300만 행에 3ms로 끝나는 ADD COLUMN이 12초 트랜잭션 뒤에 줄 서면 **뒤따르는 SELECT를 7~9초 막는다.** 최대 락 보유 11,316ms → 3.4ms | `E2` |
| **[B52 JPA 목록 API](sessions/B52-jpa-list-api/)** | N+1(쿼리 21개→1개) 외에, **커서 페이지네이션의 표준 문법이 MySQL에서 OFFSET보다 느리다**(range 최적화를 못 받는다) | `E2` |

---

## 발행

세션과 발행 편이 1:1이 아닙니다. A24와 A25는 한 사고의 앞뒤(A24의 산출물이 A25의 입력)라 **한 편으로 묶어 발행**했습니다.

| 발행 편 | 세션 | 다루는 것 |
|---|---|---|
| [1편 통계로는 못 찾고 찾아도 뺄 잔액이 없다](https://dj258255.github.io/IT-Oasis/blog/incident/currency-reclaim) | A24 + A25 | 이상 지급을 찾는 것부터 실제로 되돌리기까지 |
| [2편 수만 건을 한 번에 고쳤더니 상관없는 이용자까지 멈췄다](https://dj258255.github.io/IT-Oasis/blog/incident/mssql-lock-escalation) | A04 | 1편의 배치 크기(4,000행)가 어디서 나왔는지 |
| [3편 느리다는 신고는 왔는데 느린 쿼리 목록은 멀쩡하다](https://dj258255.github.io/IT-Oasis/blog/incident/mssql-diagnosis) | A26 | 앞 두 편이 전제한 "원인을 아는 상태"를 걷어낸 진단 순서 |

---

## 구조

```
sessions/<트랙><번호>-<슬러그>/
├── README.md        사건 요약 → 재현 → 내부 원리 → 해소 → 재계측 → 예상과 달랐던 점
├── RUNBOOK.md       운영 절차서 (사고 대응 세션)
├── reproduce.md     실행한 명령과 출력 원문
├── compose.yml      재현 환경
└── results/         전후 측정 데이터·그래프
```

트랙은 A(DB 내부·운영) · B(애플리케이션) · F(금융·증권) · R(클라우드 관리형 DB) 넷이 진행됐습니다.
I(인프라·SRE) · S(검색엔진) · V(벡터·RAG) · L(LLM 서빙) · M(모바일 연동) · X(물리 사건 축소)는 설계만 되어 있고, 전체 목록과 재현 설계는 **[CATALOG.md](CATALOG.md)** 에 있습니다.

## 실행 환경

미들웨어는 세션마다 `compose.yml`에 담았으므로 Docker만 있으면 뜹니다.

- Docker / Docker Compose
- 장애 주입: Toxiproxy, Pumba, tc(netem), libfaketime
- 관측: Prometheus, Grafana

다만 호스트에서 도는 것들이 있어 세션에 따라 추가 설치가 필요합니다. 부하 생성기(k6, sysbench)와 애플리케이션 런타임이 그렇습니다. 예를 들어 R13은 Spring Boot 앱을 호스트에서 띄우므로 Java 21과 Gradle, k6가 필요합니다. 무엇이 필요한지는 각 세션의 `reproduce.md` 첫 절에 적었습니다.

**SQL Server 세션은 ARM 맥 에뮬레이션이라 실행 시간을 근거로 쓰지 않습니다.** 락 개수·행 수·논리 읽기·오류 번호·상태 전이처럼 하드웨어와 무관한 값만 인용합니다.

## 문서

| 문서 | 내용 |
|---|---|
| [SQLSERVER.md](SQLSERVER.md) | SQL Server 세션 여덟의 90초 요약 |
| [CATALOG.md](CATALOG.md) | 전체 세션 설계와 근거 검증 로그 |
| [CONVENTIONS.md](CONVENTIONS.md) | 세션 작성 규약과 문서 템플릿 |
| [audit/LIMITS.md](audit/LIMITS.md) | 재현의 한계를 스스로 전수 점검한 기록 |

## 주의

보안 세션(Log4Shell, SSRF, 역직렬화, 공급망)은 **격리된 로컬 환경에서만** 실행합니다. 외부 대상 테스트나 실제 익스플로잇 공개는 하지 않습니다. 해당 세션은 방어 검증에 필요한 최소 범위까지만 다룹니다.

## 라이선스

MIT
