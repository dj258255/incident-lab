-- 초기 잔고 시드. 01-schema.sql과 각 리셋 구간이 \ir로 공유한다.
-- 우리사주 조합원 999계좌(5~55주, 결정적 분포)와 기관 수탁 1계좌.
-- 이 원장의 예탁 합계는 970,000주로 발행총수 1,000,000주의 97%다. 여유분은 30,000주.
INSERT INTO holdings (account_id, holder, shares)
SELECT i, format('조합원-%s', i), 5 + (i % 51)
FROM generate_series(1, 999) AS i;

INSERT INTO holdings (account_id, holder, shares)
SELECT 1000, '기관-수탁', 970000 - coalesce(sum(shares), 0)
FROM holdings;
