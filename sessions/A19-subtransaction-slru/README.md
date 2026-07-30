# A19 SAVEPOINT 하나가 만드는 성능 절벽, 그리고 PostgreSQL 17에서 달라진 것

## 1. 유명한 이유

GitLab이 2021년 9월에 쓴 글이 널리 읽힙니다. 2020년 6월부터 GitLab.com의 데이터베이스가 몇 분씩 멈추는 일이 반복됐습니다.

> Since last June, we noticed the database on GitLab.com would mysteriously stall for minutes, which would lead to users seeing 500 errors during this time.

일주일 멀쩡하다가 15분 터지고 며칠 사라지는 패턴이라 재현이 안 됐고, GitLab은 이 현상에 네스호 괴물을 따 **Nessie**라는 이름을 붙였습니다. 가장 크게 맞은 엔드포인트는 CI 러너가 작업을 받아 가는 `POST /api/v4/jobs/request`였습니다.

원인은 `SAVEPOINT`였습니다. 관측된 패턴이 두 가지였습니다.

> Only the replicas were affected; the primary remained unaffected.
> There was a long-running transaction, usually relating to PostgreSQL's autovacuuming, during the time.

수치는 이렇습니다. 복제본의 처리량이 초당 36만에서 5만으로 떨어졌습니다. 7.2배입니다. 그리고 이 글에서 가장 많이 인용되는 계산이 나옵니다.

> 8192/4 = 2048 transaction IDs can be stored in each page
> There are 32 (`NUM_SUBTRANS_BUFFERS`) pages, which means up to 65K transaction IDs
> it took about 18 seconds to fill up all 65K entries

8KB 페이지에 4바이트 XID가 2,048개, 32페이지면 65,536개. 이 65,536이 절벽의 위치입니다.

가장 무서운 문장은 따로 있습니다.

> To our surprise, our experiments also demonstrated that a single `SAVEPOINT` during a long-transaction could initiate this problem if many writes also occurred simultaneously. That is, it wasn't enough just to reduce the frequency of `SAVEPOINT`; we had to eliminate them completely.

GitLab의 애플리케이션은 중첩이 10을 넘은 적이 없었습니다. 64개를 넘겨야 생기는 문제가 아니라는 뜻입니다. 결국 GitLab은 `SAVEPOINT`를 빈도만 줄이는 대신 전부 없앴습니다.

### 애플리케이션에 SAVEPOINT라는 단어가 없어도 생깁니다

이게 이 사례가 무서운 두 번째 이유입니다. 다음은 모두 `SAVEPOINT`를 발행합니다.

| 경로 | SAVEPOINT 발행 |
|---|---|
| PL/pgSQL의 `EXCEPTION` 블록 | 예 |
| Rails `transaction(requires_new: true)`, `create_or_find_by` | 예 |
| Spring `@Transactional(propagation = NESTED)` + `DataSourceTransactionManager` | 예 |
| Spring `NESTED` + `JpaTransactionManager` | 아니요(예외로 막힘) |
| Django 중첩 `atomic()` | 예 |
| SQLAlchemy `begin_nested()` | 예 |

PL/pgSQL 쪽은 공식 문서가 유난히 불친절합니다. 제어 구조 문서에는 "`EXCEPTION` 절이 있는 블록은 없는 블록보다 진입과 탈출이 훨씬 비싸다"고만 적혀 있고 서브트랜잭션이라는 말이 없습니다. 서브트랜잭션을 명시한 곳은 별도 페이지입니다.

> Also, a block containing an EXCEPTION clause effectively forms a subtransaction that can be rolled back without affecting the outer transaction.

## 2. 재현

### 환경

전부 `reproduce.md`에 있습니다. PostgreSQL 17.5 프라이머리 + 핫 스탠바이, 각 4코어 4GB, `shared_buffers=1GB`, `autovacuum=off`입니다.

### 왜 17로 재는가

이 세션은 두 가지를 동시에 봅니다.

16 이하에서 subtrans SLRU 크기는 `src/include/access/subtrans.h`의 컴파일 타임 상수였습니다.

```c
/* Number of SLRU buffers to use for subtrans */
#define NUM_SUBTRANS_BUFFERS	32
```

바꾸려면 재컴파일해야 했습니다. GitLab이 검토했다가 포기한 것이 이 값을 키우는 Andrey Borodin의 패치였습니다. 그 패치가 17에서 `subtransaction_buffers` GUC로 정식 반영됐습니다. 즉 GitLab이 2021년에 원했던 조치를 17에서는 설정 한 줄로 할 수 있습니다.

그래서 17을 쓰되 16 시절의 크기(32블록 = 256kB)로 고정한 조건과 키운 조건을 나란히 재면, 같은 이미지 안에서 해소책의 효과가 분리됩니다.

17에서 이름도 두 개 바뀌었습니다. `pg_stat_slru`의 name이 `Subtrans`에서 `subtransaction`으로, 그리고 대기 이벤트는 이미 13에서 `SubtransControlLock`이 `SubtransSLRU`로 바뀌어 있었습니다. 버전별로 계측 쿼리를 분기해야 합니다.

### 두 개의 경계

절벽이 한 군데가 아닙니다.

**64**는 `src/include/storage/proc.h`의 값입니다.

```c
#define PGPROC_MAX_CACHED_SUBXIDS 64	/* XXX guessed-at value */
```

백엔드는 자기 트랜잭션의 서브트랜잭션 XID를 이 배열에 광고합니다. 주석이 넘칠 때 무슨 일이 생기는지 직접 말해 줍니다.

> If none of the caches have overflowed, we can assume that an XID that's not listed anywhere in the PGPROC array is not a running transaction. **Else we have to look at pg_subtrans.**

**65,536**은 위의 32페이지 × 2,048입니다. 여기를 넘으면 `pg_subtrans` 조회마저 SLRU 캐시에서 빗나갑니다.

그래서 조건을 이 두 경계 아래위로 뒀습니다. 갱신 대상(50만 행)과 리더 부하(동시 64, 20초)를 전부 고정하고, 그 50만 건을 몇 개의 서브트랜잭션으로 나눌지만 바꿉니다.

## 3. 재계측

### 프라이머리

4회 반복의 중앙값이고 괄호는 최소에서 최대입니다. 기준선 대비는 회차마다 따로 계산했습니다.
회차별 원문은 `results/run0-*`부터 `results/run3-*`에 있습니다.

| 조건 | 서브트랜잭션 | SLRU 버퍼 | TPS | 기준선 대비 | 조회 | 빗나감 | SubtransSLRU 대기 |
|---|---|---|---|---|---|---|---|
| `none` | 0 | 256kB | 94,741 (94,017~101,383) | 100% | 0 | 0 | 0% |
| `sub64` | 64 | 256kB | 91,936 (90,774~98,383) | 97% | 0 | 0 | 0% |
| `sub10k` | 10,000 | 256kB | 88,242 (87,779~95,112) | 93~94% | 705만~762만 | 6 (네 번 다) | 0% |
| `sub500k` | 500,000 | 256kB | **66,026 (63,431~70,049)** | **67~71%** | 508만~561만 | **113만~126만** | **44~57%** |
| `none-buf` | 0 | 4MB | 94,507 (92,661~101,315) | 99~100% | 0 | 0 | 0% |
| `sub500k-buf` | 500,000 | 4MB | **89,470 (89,036~97,146)** | **94~96%** | 712만~778만 | **0 (네 번 다)** | 0% |

절대 처리량은 회차 간 1.08배 안쪽으로 흔들립니다. run0이 가장 조용한 상태에서 측정돼
모든 조건에서 7% 정도 높습니다. 그래서 기준선 대비는 회차마다 따로 계산해야 하고,
그렇게 계산하면 조건별 비율이 위 표처럼 좁게 모입니다.

세 구간이 성격이 다릅니다.

**0에서 64까지는 아무 일도 없습니다.** `pg_subtrans` 조회가 네 회차 모두 정확히 0건입니다. 64개는 PGPROC 배열에 그대로 들어가므로 리더가 디스크 구조를 볼 이유가 없습니다. 소스 주석의 "넘치지 않았으면 pg_subtrans를 볼 필요가 없다"가 그대로 측정됩니다.

**64를 넘으면 조회가 시작되지만 그것만으로는 안 느려집니다.** `sub10k`에서 조회가 700만 건 넘게 발생했는데 빗나간 것은 6건이고, 네 회차에서 이 6이 어긋나지 않았습니다. XID 1만 개는 약 5페이지라 32페이지 캐시에 여유롭게 들어갑니다. TPS는 기준선의 93~94%입니다. 캐시 초과 자체의 비용은 작습니다.

**65,536을 넘으면 무너집니다.** `sub500k`에서 XID 50만 개는 약 244페이지입니다. 32페이지 캐시로는 못 덮으니 조회 500만 건 중 110만 건 넘게 빗나갔습니다. 미스율은 네 회차에서 22.2~22.4%로 거의 고정입니다. TPS가 기준선의 67~71%가 되고, 대기 샘플의 44~57%가 `LWLock/SubtransSLRU`입니다. 원인 지표와 결과 지표가 같은 조건에서 함께 움직입니다.

**해소는 SLRU를 키우는 것입니다.** `subtransaction_buffers`를 4MB(512블록)로 올리자 같은 50만 서브트랜잭션에서 조회 700만 건이 **전부 적중**하고 빗나감이 네 회차 모두 0이 됐습니다. TPS는 기준선의 94~96%까지 돌아옵니다. `SubtransSLRU` 대기도 사라집니다. GitLab이 100MB 캐시면 2,620만 개를 담는다고 계산했던 그 조치입니다.

### 17의 기본값은 이미 완화되어 있습니다

17에서 `subtransaction_buffers`의 기본값은 0이고, 이는 자동 산정을 뜻합니다.

> The default value is `0`, which requests `shared_buffers`/512 up to 1024 blocks, but not fewer than 16 blocks.

`shared_buffers=1GB`면 131,072블록 ÷ 512 = 256블록입니다. 16 이하의 고정 32블록보다 8배 큽니다. 위 표의 절벽은 그 기본값을 일부러 32로 되돌려서 만든 것입니다. 17을 기본값으로 쓰면 같은 부하에서 이 절벽은 훨씬 얕습니다.

## 4. 스탠바이 절벽은 재현하지 못했습니다

GitLab이 겪은 것은 위와 다릅니다. 원문이 "복제본만 영향을 받았고 프라이머리는 멀쩡했다"고 명시합니다. postgres.ai의 후속 분석도 프라이머리 단일 노드에서는 이 문제가 없어 보인다고 적었습니다.

그래서 프라이머리 + 핫 스탠바이를 붙이고 postgres.ai의 검증된 레시피를 규모만 줄여 시도했습니다. 결과는 실패입니다.

| 조건 | 프라이머리 쓰기 | 롱TX | 스탠바이 TPS | 스탠바이 pg_subtrans | WAL의 ASSIGNMENT 레코드 |
|---|---|---|---|---|---|
| `sb-sp3` | SAVEPOINT 3개 + 쓰기 3건 | 있음 | 60,769 | 0 | 0 |
| `sb-plain3` | SAVEPOINT 없이 쓰기 3건 | 있음 | 51,931 | 0 | 0 |
| `sb-sp70` | 쓰기 서브트랜잭션 70개 | 있음 | 72,983 | 0 | 0 |
| `sb-sp70-nolong` | 같음 | 없음 | 76,225 | 0 | 0 |

스탠바이의 `pg_stat_slru`에서 `subtransaction` 행이 모든 조건에서 정확히 0입니다. 같은 시점 `transaction` 행은 2만~46만 건씩 잡히므로 통계 수집이 죽은 것은 아닙니다. 복제 지연도 0~1초였고, 스탠바이 스냅샷의 xmin은 긴 트랜잭션에 제대로 붙잡혀 있었습니다.

### 왜 안 됐는지 알아낸 것까지

스탠바이가 서브트랜잭션 오버플로를 알게 되는 경로는 WAL의 `XLOG_XACT_ASSIGNMENT` 레코드뿐입니다. 이 레코드가 언제 나오는지 `pg_waldump`로 직접 셌습니다.

한 트랜잭션에 쓰기 서브트랜잭션 10만 개를 만들자 이 레코드가 **1,562개** 나왔습니다. 100,000 ÷ 64 = 1,562.5입니다. 트랜잭션 하나 안에서 서브트랜잭션 64개마다 한 번씩 기록된다는 뜻입니다.

그리고 `SAVEPOINT` 3개짜리 트랜잭션에서는 이 레코드가 한 건도 나오지 않았습니다. 64에 닿을 일이 없으니 당연합니다. 스탠바이는 오버플로가 있었다는 사실 자체를 통보받지 못하고, 통보받지 못하면 스냅샷을 `suboverflowed`로 표시하지 않고, 표시하지 않으면 `pg_subtrans`를 볼 이유가 없습니다.

이것만 보면 GitLab의 "SAVEPOINT 하나로도 생긴다"와 어긋납니다. 하지만 제 실험이 그것을 반박한다고 말할 수는 없습니다. 이유는 아래에 적었습니다.

### 이 실패를 반박으로 읽으면 안 되는 이유

세 가지가 걸립니다.

첫째, `sb-sp70` 조건은 쓰기 처리량이 **초당 0.68건**이었습니다. 4개 클라이언트가 한 트랜잭션에서 70개 행 락을 잡으니 서로 막고 데드락까지 났습니다(WAL에 ABORT 레코드 확인). GitLab이 요구한 "동시에 많은 쓰기"와는 거리가 멉니다. 즉 이 조건은 ASSIGNMENT 레코드가 나올 수 있는 유일한 조건이었는데, 정작 쓰기량이 없어서 조건을 못 만들었습니다.

둘째, GitLab이 관측한 버전은 12대입니다. 블로그 본문에 버전 명시는 없지만, 본문이 링크한 이슈 제목이 "Benchmark 10-30 concurrent transactions with 3 nested savepoints on PostgreSQL 12.7/12.8"입니다. 관측한 대기 이벤트 이름이 `SubtransControlLock`(13 이전 명칭)인 것과도 맞습니다. postgres.ai가 검증한 버전은 12, 13, 14입니다. 17에서 같은 경로가 그대로 남아 있는지는 확인하지 않았습니다.

셋째, 제 스탠바이는 프라이머리와 같은 호스트의 컨테이너입니다. postgres.ai는 별도 인스턴스 2대(c5a.4xlarge)를 썼습니다. 자원 경쟁 구조가 다릅니다.

정직한 결론은 이것입니다. **프라이머리 쪽 절벽은 두 경계와 해소책까지 재현했고, GitLab이 겪은 스탠바이 쪽 절벽은 재현하지 못했습니다.** 못 한 이유의 일부(ASSIGNMENT 레코드가 64마다만 나온다)는 밝혔지만, 그것이 GitLab의 서술과 어긋나는 이유는 밝히지 못했습니다.

## 5. 예상과 달랐던 점

### 긴 트랜잭션과 캐시 초과만으로는 아무 일도 안 일어납니다

조건을 다 갖췄다고 믿고 여러 번 쟀는데 `pg_subtrans` 조회가 계속 0이었습니다. 원인은 스냅샷의 xmax였습니다.

긴 트랜잭션이 유일한 쓰기 주체이면 `pg_current_snapshot()`이 `2218:2218:`처럼 나옵니다. xmin과 xmax가 같습니다. 서브트랜잭션 XID는 2219부터인데 전부 xmax 이상입니다. `XidInMVCCSnapshot`은 xid가 xmax 이상이면 "진행 중"이라고 즉시 판정하고 끝냅니다. `pg_subtrans`를 볼 이유가 없습니다.

그래서 조건이 셋입니다. 긴 트랜잭션, 서브트랜잭션 캐시 초과, 그리고 **XID 카운터를 서브트랜잭션 범위 너머로 밀어 올리는 다른 쓰기 트래픽**. 세 번째를 넣고서야 재현됐습니다.

GitLab 원문의 "if many writes also occurred simultaneously"가 이 조건입니다. 처음에는 부하를 키우라는 뜻으로 읽었는데, 부하의 양이 아니라 XID 카운터를 미는 역할이 핵심이었습니다. `scripts/run-primary.sh`에 이 단계를 별도로 둔 이유입니다.

### 캐시 초과의 비용이 거의 없었습니다

64를 넘기면 느려질 것으로 예상했는데 `sub10k`에서 조회 700만 건이 전부 캐시에 적중하며 TPS가 기준선의 93~94%에 머물렀습니다. 절벽은 "캐시를 넘겼는가"가 아니라 "XID 범위가 SLRU 페이지 수를 넘겼는가"에서 생깁니다.

이 구분이 실무에서 중요합니다. 서브트랜잭션을 64개 아래로 유지하는 것만으로는 안심할 수 없고, 반대로 64를 넘겼다고 무조건 위험한 것도 아닙니다. 위험한 조건은 XID 소비 속도와 긴 트랜잭션의 길이가 함께 만듭니다.

### 스탠바이가 프라이머리보다 max_connections를 크게 가져야 합니다

스탠바이가 이 로그를 남기고 안 떴습니다.

```
FATAL:  recovery aborted because of insufficient parameter settings
DETAIL:  max_connections = 100 is a lower setting than on the primary server, where its value was 300.
```

이 값이 스탠바이의 `KnownAssignedXids` 배열 크기를 정하기 때문입니다. 이 세션의 주제와 직접 닿아 있는 제약입니다. 스탠바이는 프라이머리에서 진행 중인 XID를 이 배열로 추적하고, 바로 이 배열이 넘칠 때 `pg_subtrans`로 내려갑니다.

### 널리 인용되는 문장에 대한 정정

`SubtransControlLock`이 `SubtransSLRU`로 바뀐 것은 13입니다. 13 릴리스 노트에는 개별 이름이 없고 "Rename various wait events to improve consistency"라는 총괄 문구만 있습니다. 이름 매핑은 소스의 `lwlocknames.txt`에서 확인해야 합니다.

그리고 `https://www.postgresql.org/docs/17/wait-events.html`은 존재하지 않는 URL입니다. 대기 이벤트 표는 `monitoring-stats.html` 안에 있습니다.

## 못 한 것

- **스탠바이 절벽.** 위 4절에 적었습니다. 이 세션의 가장 큰 공백입니다.
- **대기 샘플 파일이 회차마다 누적됐습니다.** `run-primary.sh`가 초기화하지 않아
  run1~3의 waits 파일이 앞 회차를 포함합니다. 위 표의 44~57%는 차분해서 얻은 값이고
  스크립트는 고쳤지만, 이미 저장된 파일은 누적 상태로 남아 있습니다.
- **16과 17 비교.** 같은 워크로드를 16에서 돌려 17의 뱅크 단위 SLRU 락 개선이 얼마나 기여하는지 분리하지 못했습니다. 지금 표의 절벽은 17에서 버퍼만 32로 되돌린 것이라, 16의 실제 동작과 같다고 단정할 수 없습니다.
- **`RELEASE SAVEPOINT`의 효과.** postgres.ai는 활성 서브트랜잭션을 64 미만으로 유지하면 총 100개를 만들어도 열화가 없다고 했습니다. 활성 수와 누적 수를 나눠 재지 않았습니다.
- **Multixact 경로.** 서브트랜잭션과 `SELECT ... FOR UPDATE`가 겹치면 multixact가 끼어들어 별도의 열화가 생깁니다. 이 세션에서 다루지 않았습니다.
- **XID 소비 증가 자체의 위험.** 서브트랜잭션은 XID를 더 빨리 소비하므로 wraparound 위험을 키웁니다. 그쪽은 A14에서 다룹니다.
- **애플리케이션 계층 검증.** 위 표의 Spring, Rails 항목은 문서와 소스로 확인했을 뿐 이 랩에서 실행해 확인하지 않았습니다.
