# 근거 등급과 1차 출처 전수 점검

2026-07-30 작성. 블로그 `incident` 카테고리 32편의 "유명한 이유" 절을 전수 점검했습니다.
등급이 본문 주장과 맞는지 보고, E2 가운데 실제 기업 사례를 붙일 수 있는 것을 골라내는 것이 목적입니다.

## 판정 기준

- **E1**: 사건 당사자나 규제기관의 1차 문서가 있고 그것을 직접 인용
- **E1·축소**: 사건은 실재하고 1차 문서도 있으나 재현이 축소판
- **E2**: 특정 회사의 공개 사고가 아니라 벤더 문서가 조건을 명시해 경고하는 함정

회사 사례 열에서 벤더 문서와 표준(RFC), 개인 기술 블로그, GitHub 이슈는 제외했습니다.
기업이 자기 사고나 자기 시스템의 문제를 공개한 기록만 셉니다.

## 전수 표

| 글 | 등급 | 회사 사례 출처 | 벤더·표준 | 출처 줄 |
|---|---|---|---|---|
| [backup-pitr](/blog/incident/backup-pitr) | `E1·축소` | about.gitlab.com | 2개 | 있음 |
| [batch-cache-pollution](/blog/incident/batch-cache-pollution) | `E2` | 없음 | 3개 | 있음 |
| [bigdecimal-money](/blog/incident/bigdecimal-money) | `E1·축소` | 없음 | 3개 | 본문 |
| [buffer-pool-sizing](/blog/incident/buffer-pool-sizing) | `E2` | 없음 | 1개 | 있음 |
| [charset-timezone](/blog/incident/charset-timezone) | `E2` | 없음 | 3개 | 있음 |
| [expand-contract](/blog/incident/expand-contract) | `E2` | 없음 | 3개 | 본문 |
| [failover-dns-cache](/blog/incident/failover-dns-cache) | `E2` | 없음 | 1개 | 있음 |
| [gap-lock-deadlock](/blog/incident/gap-lock-deadlock) | `E2` | 없음 | 1개 | 있음 |
| [hanmac-divide-by-zero](/blog/incident/hanmac-divide-by-zero) | `E1·축소` | 없음 | 1개 | 본문 |
| [hikaricp-pool-deadlock](/blog/incident/hikaricp-pool-deadlock) | `E1·축소` | techblog.woowahan.com | 2개 | 있음 |
| [index-not-used](/blog/incident/index-not-used) | `E2` | techblog.lycorp.co.jp | 1개 | 있음 |
| [int-pk-exhaustion](/blog/incident/int-pk-exhaustion) | `E1·축소` | 없음 | 2개 | 있음 |
| [jpa-list-api](/blog/incident/jpa-list-api) | `E2` | helloworld.kurly.com, shopify.engineering, techblog.woowahan.com | 2개 | 있음 |
| [market-open-connection-storm](/blog/incident/market-open-connection-storm) | `E1·축소` | www.goodkyung.com, www.mt.co.kr, www.nspna.com | 1개 | 본문 |
| [matching-engine-priority](/blog/incident/matching-engine-priority) | `E2` | 없음 | 2개 | 본문 |
| [mdl-storm](/blog/incident/mdl-storm) | `E2` | 없음 | 1개 | 있음 |
| [nasdaq-ipo-livelock](/blog/incident/nasdaq-ipo-livelock) | `E1·축소` | www.nasdaqtrader.com, www.sec.gov | 1개 | 본문 |
| [negative-price](/blog/incident/negative-price) | `E1` | www.cftc.gov | 1개 | 본문 |
| [perf-insights-clone](/blog/incident/perf-insights-clone) | `E2` | 없음 | 3개 | 있음 |
| [planner-stats-flip](/blog/incident/planner-stats-flip) | `E1` | clerk.com, gocardless.com | 1개 | 본문 |
| [reader-endpoint-skew](/blog/incident/reader-endpoint-skew) | `E2` | 없음 | 2개 | 있음 |
| [replica-promotion-loss](/blog/incident/replica-promotion-loss) | `E1·축소` | github.blog | 2개 | 있음 |
| [replication-slot-wal](/blog/incident/replication-slot-wal) | `E2` | 없음 | 2개 | 있음 |
| [samsung-ghost-shares](/blog/incident/samsung-ghost-shares) | `E1·축소` | 없음 | 1개 | 본문 |
| [slotted-counter](/blog/incident/slotted-counter) | `E2` | 없음 | 1개 | 있음 |
| [subtransaction-slru](/blog/incident/subtransaction-slru) | `E1·축소` | about.gitlab.com | 2개 | 있음 |
| [threadlocal-classloader-leak](/blog/incident/threadlocal-classloader-leak) | `E2` | 없음 | 3개 | 본문 |
| [timeseries-partition](/blog/incident/timeseries-partition) | `E2` | 없음 | 1개 | 있음 |
| [uber-write-amplification](/blog/incident/uber-write-amplification) | `E1` | www.uber.com | 5개 | 있음 |
| [uuid-page-split](/blog/incident/uuid-page-split) | `E2` | 없음 | 3개 | 있음 |
| [websocket-slow-consumer](/blog/incident/websocket-slow-consumer) | `E2` | 없음 | 3개 | 있음 |
| [xid-wraparound](/blog/incident/xid-wraparound) | `E1·축소` | blog.sentry.io | 1개 | 있음 |

## 집계

| 등급 | 편수 |
|---|---|
| E1 | 3 |
| E1·축소 | 11 |
| E2 | 18 |
| 합계 | 32 |

## 보강 대상: E2인데 회사 사례가 없는 16편

벤더 문서만으로 근거를 세우고 있는 글들입니다. 같은 메커니즘의 기업 공개 사례를 찾아 붙이면
"실무에서 반복된다"는 주장이 튼튼해집니다.

- batch-cache-pollution
- buffer-pool-sizing
- charset-timezone
- expand-contract
- failover-dns-cache
- gap-lock-deadlock
- matching-engine-priority
- mdl-storm
- perf-insights-clone
- reader-endpoint-skew
- replication-slot-wal
- slotted-counter
- threadlocal-classloader-leak
- timeseries-partition
- uuid-page-split
- websocket-slow-consumer

## 보강 규칙

**메커니즘이 같지 않으면 붙이지 않습니다.** 도메인이 비슷하다는 이유로 갖다 붙이는 것이
이 저장소에서 가장 경계하는 일입니다. 사례 원문이 같은 인과를 그 인과로 명시해야 하고,
원문이 다른 원인을 지목하면 제외합니다. 관련은 있으나 원문이 인과를 명시하지 않으면
"보류"로 두고 본문에 넣지 않습니다.

이미 회사 사례가 붙어 있는 E2 글이 둘 있습니다. `index-not-used`는 LINE의 함수형 인덱스
사례, `jpa-list-api`는 컬리와 우아한형제들과 Shopify입니다. 이 둘은 등급을 E2로 유지하되
사례를 실무 근거로만 씁니다. 회사가 자기 사고로 공개한 것이 아니라 개선 경험을 공개한
것이기 때문입니다.

## 형식 불일치: `> 출처:` 줄이 없는 10편

32편 가운데 아래 글들은 인용 블록으로 출처를 모으는 관례를 쓰지 않고 본문 문장 안에
링크를 둡니다. 링크 자체는 있으므로 근거가 없는 것은 아니지만, 독자가 출처를 한눈에
보지 못하고 자동 점검도 어렵습니다. 통일하는 편이 낫습니다.

- bigdecimal-money
- expand-contract
- hanmac-divide-by-zero
- market-open-connection-storm
- matching-engine-priority
- nasdaq-ipo-livelock
- negative-price
- planner-stats-flip
- samsung-ghost-shares
- threadlocal-classloader-leak

## 2026-07-30 근거 조사 결과 반영

E2 18편 가운데 12편에 대해 기업 1차 기록을 찾는 조사를 돌렸습니다. 채택 7건, 못 찾음 5건입니다.
못 찾은 것을 함께 적는 이유는 다음 회차에 같은 조사를 반복하지 않기 위해서입니다.

### 채택 (7건)

| 세션 | 출처 | 등급 변화 | 인용 범위 |
|---|---|---|---|
| A06 갭 락 데드락 | KINTO Technologies, Aurora MySQL 결제 데드락 | **E2 → E1·축소** | 인과는 문장 단위로 일치. 다만 실린 InnoDB 덤프는 로컬 재현본이고, 그들의 해소는 이 세션의 두 방법이 아닌 설계 변경 |
| A02 MDL 폭풍 | Railway 2025-12-08, GoCardless | E2 유지 | **엔진이 PostgreSQL이고 락 이름이 `AccessExclusive`임을 명시할 때만 사용.** Railway 자체 문구는 큐 규칙까지 가지 않아 그 부분은 GoCardless로 보충 |
| R04 복제 슬롯 WAL | GitLab, `max_slot_wal_keep_size` 변경 요청 | E2 유지 | **장애 회고가 아니라 변경 요청.** 다운타임 없음으로 적혀 있음. "GitLab에서 터졌다"로 쓰면 안 됨 |
| slotted-counter | GitLab `project_daily_statistics` | E2 유지 | 문제 쪽만. GitLab의 해소는 Redis 버퍼링이라 슬롯 분할 해법의 근거는 아님 |
| uuid-page-split | 라쿤홀딩스 기술 블로그 | E2 유지 | 메커니즘 대조용. 사고 보고서가 아니고, 10~20배 수치는 자체 측정이 아니라 외부 글 요약 |
| timeseries-partition | GitLab `web_hook_logs` | E2 유지 | 삭제가 삽입을 못 따라간다는 대목과 파티션 드롭 비용이 사실상 0이라는 대목까지. 디스크 반환은 이 출처에 없음 |
| websocket-slow-consumer | Discord Elixir 500만 동시 접속 | E2 유지 | 상한 없는 큐가 OOM으로 전체를 죽이는 절반만. 넘친 큐는 Erlang 메일박스이고 멈춘 원인은 느린 클라이언트가 아니라 내부 호출 타임아웃 |

### 채택 없음 (5건)

| 세션 | 조사 범위 | 판단 |
|---|---|---|
| buffer-pool-sizing | 국내외 기술 블로그, 벤더 문서 | 없음. 벤더 문서가 근거의 전부 |
| R02 failover-dns-cache | 같음 | 없음. 다만 AWS가 자바 SDK 문서에 **전용 항목을 따로 둘 만큼** 알려진 함정이라는 사실 자체를 근거로 세우는 편이 정직함. 기업 사례가 없다는 것을 약점으로 적기보다 벤더가 별도 절을 배정했다는 쪽을 쓰는 구도 |
| B31 threadlocal-classloader-leak | Apache/Atlassian/Jenkins 트래커 REST 직접 조회, danluu/post-mortems 전문 | 없음. Apache 트래커에 인과를 문장 단위로 적은 항목 넷(HIVEMIND-161, IBATIS-540, GERONIMO-4868, WW-3768)이 있으나 모두 개인 OSS 버그 보고이고 장애가 아님. **현행 README가 이미 "공개 포스트모템은 찾지 못했다"고 명시해 둔 상태라 고칠 것이 없음** |
| A02 (MySQL MDL로) | GitHub gh-ost 글 포함 | 없음. gh-ost 글의 정지는 유발자가 롱 트랜잭션이 아니라 `DROP TRIGGER` 자신이고, 같은 글의 "complete lock downs" 문장은 트리거의 행 락 경합이라 MDL이 아님. **두 문장을 붙여 쓰면 원문 왜곡** |
| A06 (국내 사례로) | 우아한형제들 저장소 자체 검색 | 없음. 검색이 "검색 결과가 없습니다"를 돌려주므로 카탈로그가 언급했던 우형 갭 락 글은 **존재하지 않는 것으로 본다** |

### 정정 1건

`research/A-01-11.md`가 A06의 2차 근거로 적어 둔 Tecoble "데드락 해결 모험기"는 원문을 직접
열어 보니 갭 락도 삽입 의도 락도 나오지 않습니다. 공유락·배타락·비관적락·낙관적락만 다루고
해소는 `@Lock(LockModeType.PESSIMISTIC_WRITE)`입니다. 검색 결과만 보고 "실무 사례 글"로 판단한
것이 틀렸습니다. 근거에서 제외하고 조사 기록에 정정을 적었습니다.

### 조사의 한계

두 회차 모두 도중에 웹 검색 한도가 소진돼 이후로는 원문 URL 직접 열람과 공개 API 조회로만
확인했습니다. 인용문은 전부 원문 대조를 거쳤으므로 신뢰할 수 있지만 **후보 발굴의 폭은 좁습니다.**
특히 카카오·컬리·토스처럼 사이트 검색 질의를 노출하지 않는 국내 블로그는 제대로 훑지 못했습니다.
위의 "없음"은 "이번 범위에서 못 찾았다"로 읽어야 합니다.
