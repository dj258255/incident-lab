# A22 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| 호스트 | Linux 5.14.0-570.33.2.el9_6.aarch64 (Rocky Linux 9.6), 2코어 ARM Neoverse-N1, 메모리 11GB |
| MySQL | 8.4.3 (컨테이너, `cpus: 2` / `mem_limit: 4g`, 버퍼 풀 2GB) |
| 데이터 | orders 300만 행 579MB (적재 직후), order_legacy(latin1)·order_legacy_fixed(utf8mb4) 각 30만 행 |
| 일시 | 2026-07-29 재측정 |

호스트 사양 원문은 `results/host.txt`에 있습니다.

```console
$ uname -srm
Linux 5.14.0-570.33.2.el9_6.aarch64 aarch64

$ nproc
2

$ free -g
               total        used        free      shared  buff/cache   available
Mem:              11           3           0           0           6           7
Swap:              7           0           7
```

`compose.yml`은 원래 `cpus: 4`였는데 이 호스트에서는 컨테이너가 뜨지 않습니다.

```console
$ docker compose up -d
 Container a22-mysql Error response from daemon: range of CPUs is from 0.01 to 2.00, as there are only 2 CPUs available
```

코어가 둘뿐이라 4를 줄 수 없습니다. 뒤집어 말하면 **처음 측정에 쓴 `cpus: 4`는 이 장비에서 애초에 뜰 수 없으므로, 그 실행은 다른 호스트였습니다.** 이 저장소에 기록된 나머지 한 종류는 12코어 32GB 맥(R13·R16·R17)입니다. 재측정은 위 2코어 리눅스에서 `cpus: 2`로 돌렸고, 그래서 절대 시간은 이전 기록의 약 2배로 나옵니다. 아래 수치는 같은 실행 안에서만 비교해야 합니다.

## 실행

호스트에 pymysql이 없어 A08 세션의 스크립트 이미지를 그대로 씁니다.

```console
$ docker build -t incident-lab-py sessions/A08-buffer-pool-sizing/scripts

$ docker compose up -d
$ docker run --rm --network host -u $(id -u):$(id -g) -v "$PWD":/s -w /s incident-lab-py \
    python -u scripts/seed.py | tee results/seed-run.txt        # 300만 행 적재 + 분포 감사
$ docker run --rm --network host -u $(id -u):$(id -g) -v "$PWD":/s -w /s incident-lab-py \
    python -u scripts/bench.py results/bench.json | tee results/bench-run.txt

$ docker run --rm -u $(id -u):$(id -g) -v "$PWD/../..":/work -w /work/sessions/A22-index-not-used \
    incident-lab-plot python scripts/report.py | tee results/report-run.txt
```

`bench.py`가 시작할 때 선행 와일드카드 해소용 생성 컬럼과 인덱스를 먼저 겁니다. 예전에는 손으로 치던 단계였는데, 손으로 친 단계가 빠지면 재현이 안 되므로 스크립트에 넣었습니다.

## 적재 데이터 감사 (results/seed-run.txt)

```console
  0/3,000,000 (0초)
  300,000/3,000,000 (20초)
  600,000/3,000,000 (41초)
  900,000/3,000,000 (64초)
  1,200,000/3,000,000 (84초)
  1,500,000/3,000,000 (109초)
  1,800,000/3,000,000 (134초)
  2,100,000/3,000,000 (158초)
  2,400,000/3,000,000 (183초)
  2,700,000/3,000,000 (209초)
레거시 테이블 적재
order_legacy: 299,269행 추정, 16MB
order_legacy_fixed: 299,595행 추정, 16MB
orders: 2,985,200행 추정, 579MB
총 3,000,000건 / 유저 145,696 / 이름 100종
선물 주문 90,543건 (3.0%), 공개 1,799,808건 (60.0%)
1위 유저 주문 393,890건
완료 (254초)
```

의도한 분포(선물 3%, 공개 60%, Zipf 쏠림)가 실제로 들어간 것을 원장 집계로 확인했습니다. `seed.py`가 `random.seed(20260729)`로 고정돼 있어 분포 수치는 이전 실행과 한 자리도 다르지 않습니다.

## 조회 대상이 실재하는지 확인 (재측정의 이유)

이전 실행은 형변환과 함수 적용 케이스에서 **테이블에 없는 값**을 조회했습니다. 양쪽 다 0건이라 배수가 성립하지 않았습니다. 이번에는 쿼리를 고치기 전에 값이 실재하는지 원장에서 먼저 확인했습니다.

```console
$ SELECT id, order_no, amount FROM orders WHERE order_no = 'ORD000001500000';
id       order_no          amount
1500000  ORD000001500000   5000

$ SELECT COUNT(*) FROM orders WHERE order_no = 1500000;
matched_by_number
0

$ SELECT MIN(created_at), MAX(created_at) FROM orders;
mn                       mx
2026-01-01 00:00:00.000  2026-01-04 11:19:59.000

$ SELECT COUNT(*) FROM orders WHERE DATE(created_at) = '2026-01-02';
by_date_fn
864000

$ SELECT COUNT(*) FROM orders WHERE created_at >= '2026-01-02' AND created_at < '2026-01-03';
by_range
864000
```

- 형변환: `seed.py`가 만드는 주문번호는 `ORD` + 12자리라 150만 번째는 `ORD000001500000`입니다. 이전 쿼리의 `'ORD001500000'`(ORD + 9자리)은 없는 값이었습니다. 고친 뒤 두 쿼리가 **같은 한 행(id 1500000)을 찾습니다.** 다만 숫자와 비교하는 쪽은 그 행을 찾지 못하고 0건을 돌려줍니다. 그것이 이 케이스의 사고입니다.
- 함수 적용: 적재 구간은 2026-01-01부터 01-04 11:19:59까지입니다. 이전 쿼리의 2026-03-15는 구간 밖이었습니다. 구간 안에 온전히 들어가는 하루인 2026-01-02로 바꾸자 두 쿼리가 같은 864,000건을 돌려줍니다.

## 측정 결과 (results/bench-run.txt, results/report-run.txt)

```console
  사전 DDL: ALTER TABLE orders ADD COLUMN buyer_name_rev VARCHAR(64) AS (REVERSE(b
  사전 DDL: ALTER TABLE orders ADD KEY idx_buyer_rev (buyer_name_rev)
암묵적 형변환               1763.3ms →    0.45ms (3923.7배)  스캔  3,000,001 →         1  결과 0행 / 1행
문자셋 불일치 조인            3120.6ms →   41.38ms (  75.4배)  스캔    600,000 →     6,000  결과 600 / 600
인덱스 컬럼에 함수 적용          647.9ms →  274.96ms (   2.4배)  스캔  3,000,000 →   864,000  결과 864,000 / 864,000
선행 와일드카드 LIKE          763.2ms →  140.38ms (   5.4배)  스캔  3,000,000 →   300,309  결과 300,309 / 300,309
  인덱스 생성(bit-op): ALTER TABLE orders ADD KEY idx_gift (user_id, ((status_flag & 0x0100))
비트 연산 조건               910.5ms →   40.65ms (  22.4배)  스캔    393,890 →    11,922  결과 11,922 / 11,922
저장: results/bench.json
```

```console
케이스                      못 탈 때         탈 때       배수       읽은 행(전)      읽은 행(후)             결과(전/후)
------------------------------------------------------------------------------------------------
암묵적 형변환               1763.3ms      0.45ms  3923.7배     3,000,001            1             0행 / 1행
문자셋 불일치 조인            3120.6ms     41.38ms    75.4배       600,000        6,000           600 / 600
인덱스 컬럼에 함수 적용          647.9ms    274.96ms     2.4배     3,000,000      864,000   864,000 / 864,000
선행 와일드카드 LIKE          763.2ms    140.38ms     5.4배     3,000,000      300,309   300,309 / 300,309
비트 연산 조건               910.5ms     40.65ms    22.4배       393,890       11,922     11,922 / 11,922
저장: /work/sessions/A22-index-not-used/results/chart-index.png
저장: /work/sessions/A22-index-not-used/results/fig-explain.png
```

측정 방법: 워밍업 3회 후 10회 실행의 중앙값. 읽은 행은 `Handler_read_next` + `Handler_read_rnd_next` 세션 카운터 증가분을 실행 횟수로 나눈 값입니다(EXPLAIN의 rows 추정이 아님). 결과 칸은 그 쿼리가 실제로 돌려준 건수이고, 이번에 새로 남겼습니다. 이 칸이 없어서 지난번에 빈 결과끼리의 비교를 못 알아봤습니다.

형변환의 3,923.7배는 결과가 다른 두 쿼리를 나란히 잰 값입니다. **한쪽은 300만 행을 훑고 0건, 다른 쪽은 1행을 읽고 1건입니다.** 같은 행을 찾는 두 방식의 접근 비용 차이로 읽어야 하고, 두 쿼리가 같은 답을 준다는 뜻이 아닙니다.

## 이전 측정과 달라진 점

| 조건 | 이전(다른 호스트, 0건 조회 포함) | 재측정(2코어 리눅스) |
|---|---|---|
| 암묵적 형변환 | 829.6 → 0.42ms, 1,969배 (양쪽 0건) | 1,763.3 → 0.45ms, 3,923.7배 (0건 대 1건) |
| 문자셋 불일치 조인 | 1,436.0 → 22.04ms, 65배 | 3,120.6 → 41.38ms, 75.4배 |
| 인덱스 컬럼에 함수 적용 | 294.6 → 0.52ms, 564배 (양쪽 0건) | 647.9 → 274.96ms, 2.4배 |
| 선행 와일드카드 LIKE | 328.3 → 67.16ms, 5배 | 763.2 → 140.38ms, 5.4배 |
| 비트 연산 조건 | 351.3 → 20.05ms, 18배 | 910.5 → 40.65ms, 22.4배 |

절대 시간이 전 조건에서 약 2.1~2.3배로 늘어난 것은 호스트가 바뀐 탓입니다. 배수만 보면 셋은 거의 그대로이고, 두 조건이 크게 달라졌습니다. 함수 적용은 564배에서 2.4배로 내려앉았고, 형변환은 1,969배에서 3,923.7배로 올라갔습니다. 둘 다 이전 값이 빈 결과 집합에서 나왔기 때문입니다.

## 선행 와일드카드 해소용 생성 컬럼

`bench.py`의 사전 DDL로 걸립니다.

```console
$ ALTER TABLE orders
    ADD COLUMN buyer_name_rev VARCHAR(64) AS (REVERSE(buyer_name)) STORED;
$ ALTER TABLE orders ADD KEY idx_buyer_rev (buyer_name_rev);

$ docker exec a22-mysql mysql ... --default-character-set=utf8mb4 -e "..."
buyer_name  buyer_name_rev
최도윤       윤도최
강건우       우건강

ending_with  via_rev
300309       300309
```

두 방식의 결과 건수가 같아 동치임을 확인했습니다. `--default-character-set=utf8mb4`를 빼면 한글 리터럴이 깨져 0건이 나옵니다.

```console
$ docker exec a22-mysql mysql -uroot -plab -D spoon -e "SELECT COUNT(*) FROM orders WHERE buyer_name LIKE '%민준'"
ending_with
0
```

## 함수형 인덱스 문법 오류 원문

```console
$ ALTER TABLE orders ADD KEY idx_gift2 ((user_id), ((status_flag & 0x0100)));
ERROR 3762 (HY000) at line 1: Functional index on a column is not supported. Consider using a regular index instead.

$ ALTER TABLE orders ADD KEY idx_gift (user_id, ((status_flag & 0x0100)));   -- 성공
```

## 스키마 변경의 저장 비용

해소 셋 가운데 생성 컬럼과 함수형 인덱스는 테이블을 키웁니다.

```console
-- 적재 직후
orders: 2,985,200행 추정, 579MB
-- buyer_name_rev + idx_buyer_rev + idx_gift 를 건 뒤 ANALYZE
orders  2983050  791
```

579MB에서 791MB로 212MB, 약 37% 늘었습니다. 쿼리 재작성으로 끝나는 해소에는 없는 비용입니다.

## 그림 생성 방식이 바뀐 점

`fig-explain.png`는 예전에 R13 세션의 `termshot.py`로 만들었습니다. 그 스크립트는 크롬 경로가 `/Applications/Google Chrome.app/...`으로 박혀 있어서, macOS 밖에서는 `subprocess.run(..., check=False)` 때문에 오류도 없이 조용히 실패합니다. 리눅스에서 재현되도록 저장소가 이미 가지고 있던 Pillow 렌더러(`tools/render/render.py`의 `render_term`)를 쓰도록 `scripts/report.py`를 고쳤습니다. `chart-index.png`의 제목도 철회한 전제("인덱스는 그대로 두고 쿼리만 고쳤을 때")를 빼고 실제로 한 일에 맞췄습니다.

## 원문 파일 위치

| 내용 | 경로 |
|---|---|
| 호스트 사양 | `results/host.txt` |
| 케이스별 EXPLAIN·실측 원본 | `results/bench.json` |
| 적재 로그와 분포 감사 | `results/seed-run.txt` |
| 벤치·리포트 실행 출력 | `results/bench-run.txt`, `results/report-run.txt` |
| 차트·증거 카드 | `results/chart-index.png`, `results/fig-explain.png` |
