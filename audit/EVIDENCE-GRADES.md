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
