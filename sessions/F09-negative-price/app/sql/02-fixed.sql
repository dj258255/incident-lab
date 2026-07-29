-- F09 저장 계층 해소.
--
-- 제약을 없애는 것이 해소가 아니다. 'price > 0' 은 도메인이 아니라 가정이었으므로,
-- 도메인에 맞는 하한과 상한으로 바꾼다. 하한 -1000 은 우리가 고른 값이다.
-- CHECK (price IS NOT NULL) 로 바꾸는 선택지도 있지만 그건 NOT NULL 이 이미 하는 일이라
-- 오타나 단위 오류 같은 진짜 이상치를 걸러 낼 방어가 남지 않는다.

\echo ''
\echo '== [해소 1] 제약을 도메인 하한·상한으로 바꾸고 같은 틱을 다시 넣는다 =='
\echo ''

ALTER TABLE tick DROP CONSTRAINT tick_price_check;
ALTER TABLE tick ADD CONSTRAINT tick_price_domain
    CHECK (price >= -1000.00 AND price <= 100000.00);

INSERT INTO tick (seq, symbol, price) VALUES (7, 'WTI', 0.00);
INSERT INTO tick (seq, symbol, price) VALUES (8, 'WTI', -1.00);
INSERT INTO tick (seq, symbol, price) VALUES (9, 'WTI', -10.00);
INSERT INTO tick (seq, symbol, price) VALUES (10, 'WTI', -37.63);

\echo ''
\echo '-- 바꾼 제약이 진짜 이상치는 여전히 막는가 (단위를 100배 틀린 틱)'
INSERT INTO tick (seq, symbol, price) VALUES (99, 'WTI', -3763.00);

\echo ''
\echo '-- 다시 센 저장 결과'
SELECT count(*) AS stored, 10 - count(*) AS rejected FROM tick WHERE seq <= 10;

\echo ''
\echo '-- 시세 화면과 증거금 엔진이 읽어 가는 최종가'
SELECT seq, price AS last_price_system_sees FROM tick WHERE seq <= 10 ORDER BY seq DESC LIMIT 1;
