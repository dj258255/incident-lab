# A22 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| MySQL | 8.4.3 (컨테이너, cpus 4 / mem 4g, 버퍼 풀 2GB) |
| 데이터 | orders 300만 행 579MB, order_legacy(latin1)·order_legacy_fixed(utf8mb4) 각 30만 행 |
| 일시 | 2026-07-29 |

## 실행

```console
$ docker compose up -d
$ python3 scripts/seed.py        # 300만 행 적재 + 분포 감사, 약 75초
$ python3 scripts/bench.py results/bench.json
$ python3 scripts/report.py      # 표 + 차트 + 증거 카드
```

## 적재 데이터 감사 (results/seed.log)

```console
orders: 2,985,200행 추정, 579MB
총 3,000,000건 / 유저 145,696 / 이름 100종
선물 주문 90,543건 (3.0%), 공개 1,799,808건 (60.0%)
1위 유저 주문 393,890건
```

의도한 분포(선물 3%, 공개 60%, Zipf 쏠림)가 실제로 들어간 것을 원장 집계로 확인했습니다.

## 측정 결과 (results/bench.json)

```console
케이스                      못 탈 때         탈 때      배수       읽은 행(전)      읽은 행(후)
암묵적 형변환                829.6ms      0.42ms   1969배     3,000,001            0
문자셋 불일치 조인            1436.0ms     22.04ms     65배       600,000        6,000
인덱스 컬럼에 함수 적용          294.6ms      0.52ms    564배     3,000,000            0
선행 와일드카드 LIKE          328.3ms     67.16ms      5배     3,000,000      300,309
비트 연산 조건               351.3ms     20.05ms     18배       393,890       11,922
```

측정 방법: 워밍업 3회 후 10회 실행의 중앙값. 읽은 행은 `Handler_read_next` + `Handler_read_rnd_next` 세션 카운터 증가분을 실행 횟수로 나눈 값입니다(EXPLAIN의 rows 추정이 아님).

## 선행 와일드카드 해소용 생성 컬럼

```console
$ ALTER TABLE orders
    ADD COLUMN buyer_name_rev VARCHAR(64) AS (REVERSE(buyer_name)) STORED,
    ADD KEY idx_buyer_rev (buyer_name_rev);

$ docker exec a22-mysql mysql ... --default-character-set=utf8mb4 -e "..."
buyer_name  buyer_name_rev
최도윤       윤도최
강건우       우건강

ending_with  300309      -- LIKE '%민준'
via_rev      300309      -- buyer_name_rev LIKE CONCAT(REVERSE('민준'),'%')
```

두 방식의 결과 건수가 같아 동치임을 확인했습니다. `--default-character-set=utf8mb4`를 빼면 한글 리터럴이 깨져 0건이 나옵니다.

## 함수형 인덱스 문법 오류 원문

```console
$ ALTER TABLE orders ADD KEY idx_gift ((user_id), ((status_flag & 0x0100)));
ERROR 3762: Functional index on a column is not supported. Consider using a regular index instead.

$ ALTER TABLE orders ADD KEY idx_gift (user_id, ((status_flag & 0x0100)));   -- 성공
```

## 원문 파일 위치

| 내용 | 경로 |
|---|---|
| 케이스별 EXPLAIN·실측 원본 | `results/bench.json` |
| 적재 로그와 분포 감사 | `results/seed.log` |
| 차트·증거 카드 | `results/chart-index.png`, `results/fig-explain.png` |
