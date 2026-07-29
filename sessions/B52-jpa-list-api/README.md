# B52 JPA로 목록 API를 만들 때 밟는 세 함정

> 근거 등급: `E2`
> 출처: [Hibernate, N+1 selects problem](https://docs.hibernate.org/orm/3.6/reference/en-US/html/performance.html) · [Vlad Mihalcea, The N+1 query problem](https://vladmihalcea.com/n-plus-1-query-problem/) · 실무 사례: [우아한형제들, Spring Batch와 Querydsl(NoOffset)](https://techblog.woowahan.com/2662/) · [컬리, BULK 처리 Write 개선](https://helloworld.kurly.com/blog/bulk-performance-tuning/) · [Shopify, Pagination with Relative Cursors](https://shopify.engineering/pagination-relative-cursors)

## 1. 유명한 이유

목록 API는 백엔드에서 가장 많이 만드는 화면이고, JPA로 만들면 같은 자리에서 같은 문제를 만납니다.

**N+1.** 방송 20건을 가져와 각 방송의 후원을 보여주면 쿼리가 21개 나갑니다. Hibernate 공식 문서가 기본 페치 전략을 두고 "N+1 selects 문제에 극도로 취약하다"고 적습니다. 개별 쿼리는 1ms도 안 걸려서 슬로우 쿼리 로그에 안 잡히고, 그래서 트래픽이 늘 때까지 아무도 모릅니다.

**대량 삽입.** `saveAll()`은 이름이 벌크처럼 생겼지만 행마다 INSERT를 보냅니다. 컬리는 회원 1만 + 게시글 3만 건 적재에서 JPA 78초를 JDBC 1.7초로 줄인 사례를 공개했습니다.

**깊은 페이지네이션.** OFFSET은 건너뛸 행을 전부 읽고 버립니다. Shopify는 offset 10만 지점에서 2,221.60ms가 커서 방식으로 5.24ms가 됐다고 공개했고(99.76% 개선), 우아한형제들은 배치의 마지막 페이지가 5초에서 0.08초가 됐다고 적었습니다.

셋 다 잘 알려진 문제이고 해법도 잘 알려져 있습니다. 이 세션이 확인하려는 것은 **그 해법이 실제로 듣는가**입니다. 결과부터 말하면 셋 중 둘은 교과서대로 들었고, 하나는 교과서대로 했는데 듣지 않았습니다.

## 2. 재현

### 환경

| 항목 | 값 |
|---|---|
| 앱 | Spring Boot 3.4.1, Java 21, Spring Data JPA |
| DB | MySQL 8.4.3 (컨테이너 `--cpus=4`, 버퍼 풀 1GB) |
| 데이터 | 방송 20만 건, 후원 200만 건 (방송당 평균 10.4건, Zipf 쏠림) |
| 측정 | 워밍업 3회 후 5회, 중앙값. **응답 시간과 함께 서버가 받은 쿼리 수를 센다** |

쿼리 수는 `SHOW GLOBAL STATUS LIKE 'Com_select'`의 요청 전후 차이로 셉니다. N+1은 응답 시간만 보면 안 보이고 쿼리 수로만 드러나기 때문에, 이 지표가 없으면 재현이 성립하지 않습니다.

비교하는 방송 20건은 목록 앞이 아니라 중간 구간(id 100000~100019)에서 뽑았습니다. 앞 20건은 후원 쏠림이 심해(200만 건 중 17만 건) 변형 간 차이가 데이터 편중에 묻힙니다.

## 3. 재계측

![세 함정](results/chart-jpa.png)

### 함정 1: N+1

| 방식 | 응답 시간 | 서버가 받은 SELECT |
|---|---|---|
| 지연 로딩 그대로 | 25ms | **21개** |
| `@EntityGraph` (fetch join) | 7ms | 1개 |
| 집계 프로젝션 (JdbcTemplate) | **4ms** | 1개 |

교과서대로 들었습니다. 다만 목록 화면이 필요한 게 후원 **합계**뿐이라면 엔티티를 가져올 이유가 없습니다. 집계로 한 방에 가져오는 쪽이 fetch join보다 빠릅니다. 페치 전략을 고치기 전에 "이 화면이 정말 엔티티를 필요로 하는가"를 먼저 묻는 편이 낫습니다.

### 함정 2: 깊은 페이지네이션

| 건너뛴 행 | OFFSET | 커서 (행값 비교) | 커서 (풀어쓴 조건) |
|---|---|---|---|
| 0 | 4ms | 3ms | 3ms |
| 10,000 | 5ms | 5ms | 4ms |
| 100,000 | 16ms | 17ms | **4ms** |
| 199,980 | 28ms | 31ms | **3ms** |

여기가 이 세션의 핵심입니다. 커서 페이지네이션의 표준 문법으로 널리 소개되는 **행값 비교 `(created_at, id) > (?, ?)`가 전혀 빨라지지 않았습니다.** 오히려 OFFSET보다 느립니다(31ms 대 28ms).

실행계획을 보면 이유가 나옵니다.

```
WHERE (created_at, id) > ('2026-01-07 22:39:00.000', 199981)
  → type: index    (전체 인덱스 스캔)

WHERE created_at > '2026-01-07 22:39:00.000'
   OR (created_at = '2026-01-07 22:39:00.000' AND id > 199981)
  → type: range    (인덱스 구간 탐색)
```

MySQL 8.4.3은 행값 비교에 범위 최적화를 적용하지 않습니다. 파라미터를 리터럴로 바꿔도 같습니다. 같은 조건을 `OR`로 풀어써야 `type=range`가 되고, 그때 9.3배(28ms → 3ms)가 나옵니다. 그리고 풀어쓴 쪽은 깊이가 깊어져도 시간이 늘지 않습니다. 건너뛰는 게 아니라 인덱스에서 시작점을 바로 찾기 때문입니다.

### 함정 3: 대량 삽입

같은 1만 건 삽입인데 세 방식이 서로 다른 이유로 느립니다.

![삽입 쿼리 수](results/fig-insert.png)

| 방식 | 소요 | SELECT | INSERT |
|---|---|---|---|
| `saveAll` + `IDENTITY` | 4,620ms | 2 | **10,000** |
| `saveAll` + 직접 부여 ID | 4,555ms | **10,022** | 20 |
| JDBC `batchUpdate` | **141ms** | 3 | **1** |

- **IDENTITY**: `hibernate.jdbc.batch_size=500`을 켜도 INSERT가 1만 번 나갑니다. IDENTITY는 INSERT마다 생성된 키를 돌려받아야 해서 하이버네이트가 배치를 포기합니다. 설정을 켰는데 아무 일도 안 일어나는 이유입니다.
- **직접 ID**: 이번엔 INSERT가 20번으로 묶입니다(1만 ÷ 배치 500). 그런데 SELECT가 10,022번 나갑니다. Spring Data의 `save()`는 ID가 있으면 기존 행으로 보고 `merge()`를 호출하고, `merge`는 행마다 존재 확인 SELECT를 던집니다. 배치는 성공했는데 다른 곳에서 1만 번을 씁니다.
- **JDBC batchUpdate**: `rewriteBatchedStatements=true` 덕에 INSERT가 **한 번**으로 합쳐집니다. 이 옵션을 끄면 8,544ms로 되돌아가므로, 배치 설정과 드라이버 옵션이 함께 있어야 효과가 납니다.

## 4. 해소

| 함정 | 해소 | 주의 |
|---|---|---|
| N+1 | `@EntityGraph` 또는 fetch join. 합계만 필요하면 집계 프로젝션 | 컬렉션 fetch join + 페이지네이션은 메모리 페이징 경고를 부른다 |
| 깊은 페이지네이션 | 커서 방식, 단 **조건을 풀어써야** 한다 | 행값 비교 문법은 MySQL에서 range 최적화를 못 받는다 |
| 대량 삽입 | JDBC `batchUpdate` + `rewriteBatchedStatements=true` | JPA를 고집하려면 `Persistable.isNew()` 구현으로 merge를 피해야 한다 |

측정 자체를 위한 처방도 하나 있습니다. **쿼리 수를 세는 테스트를 붙이는 것**입니다. Vlad Mihalcea가 만든 `SQLStatementCountValidator`가 그 목적이고, 목록 API 테스트에 기대 쿼리 수를 못 박아 두면 N+1이 들어오는 순간 CI가 잡습니다. 응답 시간 회귀 테스트로는 20ms 차이를 잡지 못합니다.

## 5. 예상과 달랐던 점

### 커서로 바꿨는데 안 빨라졌습니다

가장 널리 인용되는 커서 문법이 MySQL에서 듣지 않는다는 것이 이 세션에서 가장 값진 발견입니다. 커서 페이지네이션을 도입하고 "왜 그대로지"라고 하는 상황의 정확한 원인입니다. `EXPLAIN`의 `type` 컬럼이 `range`인지 `index`인지만 확인하면 즉시 드러납니다.

### 배치 설정을 켰는데 아무 일도 일어나지 않았습니다

`hibernate.jdbc.batch_size=500`을 넣고 4,896ms를 받았을 때 설정이 안 먹은 줄 알았습니다. 실제로는 설정은 적용됐고 IDENTITY 전략이 배치를 원천 봉쇄한 것이었습니다. 이걸 확인하려고 ID를 직접 부여하는 대조군을 만들었더니 INSERT가 20번으로 줄어 배치가 살아났고, 대신 merge SELECT가 1만 번 나타났습니다. **쿼리 수를 세지 않았으면 "JPA는 그냥 느리다"로 끝났을 문제입니다.**

### 집계 프로젝션이 fetch join보다 빨랐습니다

fetch join(7ms)보다 집계(4ms)가 빠릅니다. fetch join은 방송 20건과 후원 208건을 전부 엔티티로 만들어 영속성 컨텍스트에 올리는데, 화면이 필요한 건 합계 숫자 하나입니다. 페치 전략을 튜닝하기 전에 필요한 데이터의 모양을 다시 보는 편이 낫다는 뜻입니다.

## 못 한 것

- **`Persistable.isNew()` 구현으로 merge를 피하는 변형을 만들지 않았습니다.** 원인은 특정했지만 그 해법까지는 재지 않았습니다.
- **`@BatchSize` 지연 로딩 최적화를 다루지 않았습니다.** fetch join과 집계 두 갈래만 비교했습니다.
- **동시 요청 부하가 없습니다.** 단일 요청의 응답 시간과 쿼리 수만 쟀습니다. N+1의 진짜 위험은 동시 사용자가 늘 때 커넥션 풀을 소진하는 것인데, 그 구간은 F03 세션이 다룹니다.
- **PostgreSQL 대조가 없습니다.** 행값 비교의 range 최적화는 PostgreSQL에서 동작하는 것으로 알려져 있어, 같은 실험이 다르게 나올 수 있습니다.
