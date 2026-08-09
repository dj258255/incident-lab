# 운영 절차서: 재화 이상 신고부터 회수 대상 확정까지

대상: 게임 재화·아이템의 비정상 지급이 의심될 때의 조사 절차
근거: 같은 디렉토리의 [README.md](README.md) 실측. 수치는 전부 그 실험에서 나온 값입니다.

회수 실행은 이 문서 밖입니다. 뽑은 대상을 안전하게 되돌리는 절차는
[A04 운영 절차서](../A04-mssql-lock-escalation/RUNBOOK.md)를 따릅니다.

---

## 0. 한 줄 요약

**셀 수 있으면 선별 회수, 못 세면 롤백.** 조사 쿼리의 정확도가 대응 방식을 정한다.
통계적 이상 탐지는 조사 범위를 좁히는 데만 쓰고 회수 근거로는 쓰지 않는다.

---

## 1. 즉시 (신고 접수 ~ 15분)

| # | 할 일 | 비고 |
|---|---|---|
| 1 | **확산을 먼저 막는다** | 조사보다 먼저다. 해당 기능·아이템 사용 제한 |
| 2 | 사고 창의 시작과 끝을 잠정 확정 | 첫 이상 지급 시각과 차단 시각. 뒤에 넓힌다 |
| 3 | 원장 표의 행 수와 크기 확인 | 조사 쿼리가 얼마나 읽을지 가늠 |
| 4 | 조사용 인덱스가 있는지 확인 | 없으면 4번 항목의 판단이 필요 |

```sql
-- 표 규모
SELECT SUM(p.rows) AS rows,
       SUM(a.total_pages) * 8 / 1024 AS mb
  FROM sys.partitions p
  JOIN sys.allocation_units a ON a.container_id = p.hobt_id
 WHERE p.object_id = OBJECT_ID('<원장표>') AND p.index_id IN (0,1);

-- 조사에 쓸 인덱스가 있는가
SELECT i.name, i.filter_definition,
       STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal) AS cols
  FROM sys.indexes i
  JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
  JOIN sys.columns c ON c.object_id = i.object_id AND c.column_id = ic.column_id
 WHERE i.object_id = OBJECT_ID('<원장표>')
 GROUP BY i.name, i.filter_definition;
```

---

## 2. 조사 인덱스 판단

인덱스가 없으면 조사 쿼리가 표 전체를 읽습니다. 실측에서 4시간 창을 보는 데 30일치를
두 번 읽었습니다(논리 읽기 229,614). 조건 컬럼을 담은 인덱스가 있으면 482까지 내려갑니다.

| 상황 | 선택 |
|---|---|
| 조사용 인덱스가 이미 있다 | 그대로 조사한다 |
| 없고 표가 작다 | 그냥 전체를 읽는다. 인덱스 만드는 비용이 더 크다 |
| 없고 표가 크다 | 아래 표로 판단한다 |

**인덱스 생성이 라이브에 주는 영향은 실측했습니다.** 2,000만 행 표에서 조사용 인덱스를
만드는 동안 원장에 계속 INSERT 를 던졌습니다.

| `ONLINE` | 막힌 쓰기 | 최대 지연 | 빌드가 잡은 테이블 락 |
|---|---|---|---|
| `OFF` (기본) | 1/2회 | 13,757ms | `S` (공유) |
| `ON` | 0/97회 | 408ms | `IS` (의도 공유) |

**막히는 것은 조회가 아니라 쓰기입니다.** 오프라인 빌드가 잡는 공유 락은 읽기와는 함께
서고 쓰기와는 못 섭니다. 재화 원장은 append-only 라 사고 중에도 계속 쌓이므로, 쓰기가
막히면 그 지급과 소모가 전부 줄을 섭니다.

| 상황 | 판단 |
|---|---|
| ONLINE 이 되는 에디션(Enterprise·Developer) | 만든다. 쓰기가 안 막힌다 |
| Standard 이하 | 만들지 않는다. 전체를 읽으며 조사한다 |
| 조사가 한 번으로 끝난다 | 만들지 않는다. 빌드 비용이 더 크다 |
| 같은 조사를 여러 번 돌려야 한다 | 만든다 |

`ONLINE = ON` 의 대가는 에디션 제약과, 빌드 중 변경분을 모으느라 tempdb·트랜잭션 로그를
더 쓰는 것입니다. 그 양은 재지 않았습니다.

**인덱스를 만든다면 조건 컬럼을 하나도 빠뜨리지 않습니다.** 조사 쿼리의 `WHERE` 에 있는
컬럼이 하나라도 인덱스 밖에 있으면 인덱스 전체가 안 쓰입니다. 실측에서 `reason` 하나가
빠져 640MB 인덱스가 한 번도 안 쓰였습니다.

```sql
-- 조사용 인덱스 예. 조건에 쓰는 컬럼을 전부 키에 두고, 출력 컬럼을 포함 열에 둔다.
CREATE INDEX IX_ledger_investigate
    ON <원장표> (reason, created_at, ref_id)
    INCLUDE (account_id);

-- 특정 사유만 조사한다면 필터드가 절반 크기로 더 빠르다.
SET QUOTED_IDENTIFIER ON;   -- 필터드 인덱스는 이 옵션이 없으면 만들 수도 쓸 수도 없다
SET ANSI_NULLS ON;
CREATE INDEX IX_ledger_investigate_f
    ON <원장표> (created_at, ref_id) INCLUDE (account_id)
    WHERE reason = <지급 사유>;
```

> **필터드 인덱스를 만들었다면 조회 쪽 SET 옵션을 함께 못 박습니다.** 옵션이 안 맞으면
> 에러 없이 그냥 안 쓰입니다. 접속 도구마다 기본값이 달라 "여기서는 빠른데 저기서는
> 느리다"가 여기서 나옵니다.

---

## 3. 탐지 (회수 근거를 만드는 단계)

### 우선순위

| 순위 | 방법 | 쓰는 곳 |
|---|---|---|
| 1 | **참조 대사** — 같은 참조에 지급이 여러 건 | 회수 근거 |
| 2 | **원장 대사** — 원인 로그와 지급 건수를 조인 | 회수 근거, 1번의 교차 검증 |
| 3 | 통계 이탈 — 획득량이 분포에서 벗어남 | **조사 범위 좁히기 전용** |

```sql
-- 1. 참조 대사
SELECT DISTINCT account_id
  FROM <원장표>
 WHERE reason = <지급 사유>
   AND created_at >= @win_start AND created_at < @win_end
   AND ref_id IN (SELECT ref_id FROM <원장표>
                   WHERE reason = <지급 사유>
                     AND created_at >= @win_start AND created_at < @win_end
                   GROUP BY ref_id HAVING COUNT(*) > 1);

-- 2. 원장 대사 (원인 1건에 지급 1건이라는 불변식)
SELECT DISTINCT b.account_id
  FROM <원인로그> b
  JOIN (SELECT ref_id, COUNT(*) AS c FROM <원장표>
         WHERE reason = <지급 사유>
           AND created_at >= @win_start AND created_at < @win_end
         GROUP BY ref_id) l ON l.ref_id = b.<원인키>
 WHERE b.<원인시각> >= @win_start AND b.<원인시각> < @win_end
   AND l.c <> 1;
```

**1과 2의 결과가 다르면 멈추고 이유를 찾습니다.** 같은 불변식을 다른 각도에서 본 것이라
일치해야 합니다. 다르면 사고의 모양을 아직 모르는 것입니다.

### 참조가 없는 사고라면

1과 2가 **둘 다 0건**을 내면 사고가 참조를 안 남기는 유형입니다. 지급 경로를 우회해
재화만 꽂힌 경우가 그렇습니다. 실측에서 그런 사고를 심었더니 참조 대사와 개봉 대사가
40계정 중 한 건도 못 잡았고, 통계 이탈만 40/40 을 잡았습니다.

그때 순서는 이렇습니다.

1. 통계 이탈로 이상한 계정을 좁힌다 (이 상황에서는 이것뿐이다)
2. 그 계정의 원장을 **사람이 직접 열어** 사고의 모양을 알아낸다
3. 그 모양에 맞는 결정론적 쿼리를 새로 만든다 (예: `ref_id IS NULL` 인 지급)
4. 그 쿼리를 회수 근거로 삼는다

**3번을 건너뛰고 통계 이탈 결과를 그대로 회수하지 않습니다.** 사고의 모양을 알아낸
뒤에야 정확한 쿼리를 쓸 수 있고, 그 전까지 통계 이탈은 조사 대상 목록일 뿐입니다.

### 통계 이탈을 회수 근거로 쓰지 않는 이유

실측에서 3시그마 기준이 어뷰저 60개를 다 잡았지만 **정상 고활동 계정 40개를 함께
지목**했습니다. 어뷰저(5회 이용에 지급 20건)와 정상 헤비 이용자(20회 이용에 지급 20건)는
합계가 같아 구분되지 않습니다.

거짓 음성은 회수 누락이고 거짓 양성은 오회수입니다. 놓친 어뷰저는 나중에 잡을 수 있지만,
잘못 뺏은 재화는 이미 신뢰를 깎은 뒤입니다.

---

## 4. 회수 대상 표 만들기

계정 목록만으로는 보정이 시작되지 않습니다. **얼마를 되돌릴지**가 나와야 합니다.

```sql
-- 같은 참조 안에서 첫 지급은 정상, 두 번째부터가 회수 대상
SELECT account_id,
       COUNT(*)   AS extra_rows,
       SUM(delta) AS extra_amount
  INTO reclaim_target
  FROM (SELECT account_id, delta,
               ROW_NUMBER() OVER (PARTITION BY ref_id ORDER BY ledger_id) AS rn
          FROM <원장표>
         WHERE reason = <지급 사유>
           AND created_at >= @win_start AND created_at < @win_end) q
 WHERE rn > 1
 GROUP BY account_id;
```

### 확정 전 확인

- [ ] 합계가 상식적인가 (계정 수 × 평균 지급액과 자릿수가 맞는가)
- [ ] **표본을 손으로 확인했는가.** 상위 몇 계정의 원장을 직접 열어 지급이 정말 중복인지 본다
- [ ] 창의 경계에 걸친 건이 있는가 (창 시작 직전·종료 직후를 넓혀 다시 세어 본다)
- [ ] 정상 헤비 이용자가 섞이지 않았는가 (통계 이탈로 뽑은 목록과 대조해 차집합을 본다)
- [ ] 회수 대상 표를 스냅샷으로 남겼는가 (나중에 이의 제기가 오면 근거가 된다)

---

## 5. 이후

회수 실행은 [A04 운영 절차서](../A04-mssql-lock-escalation/RUNBOOK.md)로 넘어갑니다.
요약하면 5,000행 미만 배치로 쪼개고, 배치마다 커밋하고, 시작 전에 통계를 갱신하고,
보정 자체가 잘못됐을 때를 대비해 `BEGIN TRAN ... WITH MARK` 로 지점을 찍어 둡니다.

잔액이 부족한 계정의 처리(음수 재화로 상계할지, 사용 내역을 취소할지)는 정책 결정이고
DBA 혼자 정하지 않습니다. 다만 **어느 쪽이든 감사 로그에 전후 값과 근거를 남깁니다.**

---

## 6. 이 절차가 답하지 못하는 것

- **값만 조작된 사고.** 지급 건수는 맞는데 금액만 부풀려진 경우는 참조 대사도 개봉
  대사도 통계 이탈도 못 잡을 수 있습니다. 그 조건은 만들지 않았습니다.
- **조사 쿼리가 몇 초 걸리는지.** 이 랩은 에뮬레이션이라 시간을 재지 않았습니다.
  실제 환경에서 한 번 재서 이 문서에 적어 두는 편이 좋습니다.
- **온라인 빌드의 tempdb·로그 사용량.** 쓰기가 안 막힌다는 것은 확인했지만 그 대가로
  무엇을 얼마나 더 쓰는지는 안 쟀습니다.
