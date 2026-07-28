-- A09 재현 데이터
--
-- Clerk 2026-02-19 장애의 조건을 축소해 만든다.
--   req_log.blocked_until : 요청이 레이트리밋에 걸렸을 때만 값이 채워지는 컬럼.
--                           1,200만 행 중 2,400행만 non-null(99.98% NULL)이다.
--   non-null 행을 마지막에 넣어 디스크상 테이블 끝 13페이지에 몰리게 한다.
--   ANALYZE는 페이지를 먼저 고르고 그 안에서 행을 뽑는 2단계 샘플링이라, 이 물리적 배치가
--   샘플이 non-null을 만날 확률을 그대로 결정한다.
--
--   ip_rule  : 조직별 IP 차단 규칙. org_id에만 인덱스가 있고 rule_kind에는 없다.
--              org_id 하나에 20,000행이 붙어 있어서, 중첩 루프의 안쪽이 되면
--              바깥 행마다 20,000행을 읽고 그중 1행만 남기는 구조가 된다.
--   org_plan : 조직별 요금제. org_id 하나에 1행뿐이라 중첩 루프 안쪽이 되어도 싸다.
--              같은 오추정이 어떤 표를 만나느냐에 따라 결과가 갈리는 것을 보이는 대조군이다.

\timing on

DROP TABLE IF EXISTS req_log;
CREATE TABLE req_log (
  id            bigint      NOT NULL,
  org_id        integer     NOT NULL,
  status_code   smallint    NOT NULL,
  blocked_until timestamptz
);

-- 1) 차단되지 않은 요청 11,997,600건. blocked_until은 전부 NULL이다.
INSERT INTO req_log (id, org_id, status_code, blocked_until)
SELECT g, (g % 100) + 1, 200, NULL
FROM generate_series(1, 11997600) g;

-- 2) 차단된 요청 2,400건을 마지막에 붙인다.
INSERT INTO req_log (id, org_id, status_code, blocked_until)
SELECT 11997600 + g, (g % 100) + 1, 429,
       TIMESTAMPTZ '2026-07-28 00:00:00+00' + (g || ' seconds')::interval
FROM generate_series(1, 2400) g;

CREATE INDEX req_log_blocked_until_idx ON req_log (blocked_until);

DROP TABLE IF EXISTS ip_rule;
CREATE TABLE ip_rule (
  id        bigint  NOT NULL,
  org_id    integer NOT NULL,
  rule_kind text    NOT NULL,
  cidr      text    NOT NULL
);
-- org_id 1..100, 조직마다 20,000행. 그중 rule_kind='burst'는 조직마다 1행뿐이다.
INSERT INTO ip_rule (id, org_id, rule_kind, cidr)
SELECT g,
       ((g - 1) / 20000) + 1,
       CASE WHEN g % 20000 = 1 THEN 'burst' ELSE 'static' END,
       '10.' || ((g / 65536) % 256) || '.' || ((g / 256) % 256) || '.' || (g % 256) || '/32'
FROM generate_series(1, 2000000) g;
CREATE INDEX ip_rule_org_id_idx ON ip_rule (org_id);

DROP TABLE IF EXISTS org_plan;
CREATE TABLE org_plan (
  org_id    integer NOT NULL,
  plan_code text    NOT NULL,
  rpm_limit integer NOT NULL
);
INSERT INTO org_plan (org_id, plan_code, rpm_limit)
SELECT g, 'plan_' || (g % 7), 60 * ((g % 5) + 1)
FROM generate_series(1, 200000) g;
CREATE INDEX org_plan_org_id_idx ON org_plan (org_id);

-- GoCardless 쪽(물리적 클러스터링에 의한 n_distinct 과소추정) 비교용 두 표.
-- 행 내용은 완전히 같고 디스크상 순서만 다르다.
DROP TABLE IF EXISTS payout_txn_clustered;
CREATE TABLE payout_txn_clustered (
  id        bigint  NOT NULL,
  payout_id integer NOT NULL,
  amount    integer NOT NULL
);
-- 같은 payout_id 20행이 물리적으로 붙어 있게 넣는다
INSERT INTO payout_txn_clustered (id, payout_id, amount)
SELECT g, ((g - 1) / 20) + 1, (g % 9999) + 1
FROM generate_series(1, 3000000) g;

DROP TABLE IF EXISTS payout_txn_shuffled;
CREATE TABLE payout_txn_shuffled (
  id        bigint  NOT NULL,
  payout_id integer NOT NULL,
  amount    integer NOT NULL
);
-- 같은 데이터를 흩어서 넣는다. payout_id 하나가 테이블 전역에 퍼진다
INSERT INTO payout_txn_shuffled (id, payout_id, amount)
SELECT g, ((g - 1) % 150000) + 1, (g % 9999) + 1
FROM generate_series(1, 3000000) g;

VACUUM (ANALYZE) ip_rule, org_plan;

SELECT relname,
       pg_size_pretty(pg_relation_size(oid)) AS heap,
       (pg_relation_size(oid) / 8192)        AS pages
FROM pg_class
WHERE relname IN ('req_log', 'ip_rule', 'org_plan',
                  'payout_txn_clustered', 'payout_txn_shuffled')
ORDER BY relname;

SELECT count(*) AS total_rows,
       count(blocked_until) AS non_null,
       count(*) - count(blocked_until) AS nulls,
       round(100.0 * (count(*) - count(blocked_until)) / count(*), 4) AS null_pct
FROM req_log;
