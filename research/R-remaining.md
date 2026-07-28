# 트랙 R 근거 조사: R02~R11, R15, R18 (2026-07-28)

> 진행 상태(2026-07-28): **R02~R04 조사 완료 / R05~R11, R15, R18 미조사.** 일괄 조사 배치가 중간에 끊겨 파일명이 가리키는 범위를 다 채우지 못했습니다. 이어서 조사할 때 이 파일 아래에 같은 형식으로 덧붙이고 이 줄을 갱신하세요.

대상: R02, R03, R04, R05, R06, R07, R08, R09, R10, R11, R15, R18 (R01·R12·R13·R14·R16·R17은 담당 아님)
방법: 세션당 WebSearch/WebFetch 최대 4회. 원문(AWS 공식 문서·블로그, Postgres 공식 문서) 우선. URL은 실제 접속 확인한 것만 기재.

## R02 Multi-AZ 페일오버 DNS vs JVM 캐시
- 주장: RDS Multi-AZ 페일오버는 DNS 레코드 교체 방식이라, JVM이 호스트명을 사실상 영구 캐시하면 DB 복구 후에도 앱만 계속 죽는다
- 출처: AWS SDK for Java 개발자 가이드 "Set the JVM TTL for DNS name lookups" https://docs.aws.amazon.com/sdk-for-java/latest/developer-guide/jvm-ttl-dns.html : "On some Java configurations, the JVM default TTL is set so that it will never refresh DNS entries until the JVM is restarted" — JVM 영구 캐시를 AWS가 직접 경고, TTL 5초 권장(networkaddress.cache.ttl은 security property라 -D로 설정 불가라는 함정도 명시) (원문)
- 출처: AWS RDS 문서 "Multi-AZ DB instance deployments" https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZSingleStandby.html : 동기식 스탠바이 구조 확인. 단 페일오버 절차 문구는 이 페이지 렌더링에서 잘려 직접 확인 못 함 (원문)
- 출처: docs.aws.amazon.com 검색 스니펫(Concepts.MultiAZ.Failover.html 등, 해당 URL 직접 접속은 안 함) : "The failover mechanism automatically changes the DNS record of the DB instance to point to the standby DB instance" + 애플리케이션 DNS 캐시 TTL 30초 미만 권고 (2차)
- 판정: E2 유지 : 두 축(DNS 교체 방식, JVM 영구 캐시) 모두 AWS 공식 문서로 뒷받침. 로컬 dnsmasq 재현 설계와 모순 없음
- 메모: 재현의 ttl -1 vs 30 비교는 java.security 기본 주석("any negative value: caching forever")과 정확히 대응. "DB는 1분에 복구" 수치(60~120초 문구)는 이번에 원문 재확인 못 했으니 글에서는 "수 분 내" 수준으로 완화 권장

## R03 Aurora 리더 엔드포인트 쏠림
- 주장: 리더 엔드포인트는 커넥션 단위 분산(쿼리 단위 아님)이고, HikariCP maxLifetime이 동일하면 풀 전체가 동시에 재생성돼 한 대에 몰린다(이슈 #1247)
- 출처: AWS Aurora 문서 "Amazon Aurora endpoint connections" https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Aurora.Overview.Endpoints.html : "Each connection is handled by a specific DB instance" + 리더 엔드포인트는 "Aurora automatically performs connection-balancing among all the Aurora Replicas" — 분산 단위가 커넥션임을 공식 확인. 페일오버 직후 리더 엔드포인트가 잠시 새 프라이머리로 연결을 보낼 수 있다는 부가 함정도 명시 (원문)
- 출처: HikariCP GitHub 이슈 #1247 "Connection pool mass extinction" https://github.com/brettwooldridge/HikariCP/issues/1247 : maxLifetime 30분 설정에서 풀 커넥션이 사실상 동시에 재생성되어 Aurora 리더 한 대에 ~30분간 쏠리는 현상 보고, 40세대 이상 반복 관측. 카탈로그가 인용한 이슈 번호·내용 일치 (원문)
- 판정: E2 유지 : 공식 문서(커넥션 단위 분산)와 실사용 이슈(#1247)가 행 내용과 정확히 일치
- 메모: HikariCP는 PR #480으로 최대 약 18초 variance를 넣었다고 하나 이슈 보고자는 실측에서 분산 효과가 안 보인다고 주장 — 글에서는 "지터가 부족하면"으로 서술하면 안전. 기존 검증 로그의 "리더 엔드포인트 DNS TTL 수치 인용 금지" 준수: TTL 초 수치는 어떤 문서에서도 재확인 안 했으므로 인용하지 말 것

## R04 비활성 복제 슬롯 WAL 폭증
- 주장: 컨슈머가 멈춰도 슬롯이 열려 있으면 WAL이 무한 누적되어 디스크를 채운다. max_slot_wal_keep_size가 방어책
- 출처: PostgreSQL 공식 문서 26.2.6 Replication Slots https://www.postgresql.org/docs/current/warm-standby.html : Caution 원문 "replication slots can cause the server to retain so many WAL segments that they fill up the space allocated for pg_wal" + 슬롯은 스탠바이가 끊겨 있어도(even when the standby is disconnected) WAL 제거를 막는다고 명시 (원문)
- 출처: PostgreSQL 공식 문서 runtime-config-replication https://www.postgresql.org/docs/current/runtime-config-replication.html : max_slot_wal_keep_size 기본값 -1(무제한 보존), 초과 시 필요한 WAL이 제거되어 해당 슬롯 복제가 지속 불가하게 됨 (원문)
- 판정: E2 유지 : 메커니즘·방어책 모두 공식 문서에 Caution 수준으로 명시. 재현 설계(pg_recvlogical kill → restart_lsn 정지 → pg_wal 증가 → max_slot_wal_keep_size 전후)와 정확히 대응
- 메모: "CDC가 프로덕션 DB를 죽이는 가장 흔한 경로"라는 표현은 업계 통설 성격의 수사이므로 글에서는 인용 형태가 아니라 서술로. 기본값 -1(무제한)이 함정의 핵심 근거이니 본문에 쓰기 좋음
