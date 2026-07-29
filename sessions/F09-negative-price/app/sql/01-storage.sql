-- F09 저장 계층 재현.
--
-- CFTC Docket No. 21-19 원문이 말하는 것은 Interactive Brokers 의 'Ticker Farm' 시스템이
-- 음수 가격을 오류로 보고 거부했다는 것이다("rejected negative prices ... perceived to be erroneous").
-- 여기서는 그 '이상치 거부'를 시세 테이블의 CHECK 제약 하나로 축약해 보인다.
-- 실제 IB 시스템이 Postgres CHECK 제약을 썼다는 뜻이 아니다. 같은 모양의 가정 오류를 재현하는 것이다.
--
-- 틱 10건은 코드로 만든 하강 경로다. 마지막 -37.63 만 CFTC 문서의 수치이고 나머지는 합성값이다.

\echo ''
\echo '== [버그 1] 저장 계층: CHECK (price > 0) 테이블에 하강 틱 10건을 넣는다 =='
\echo ''

DROP TABLE IF EXISTS tick;

CREATE TABLE tick (
    seq    int           PRIMARY KEY,
    symbol text          NOT NULL,
    price  numeric(12,2) NOT NULL CHECK (price > 0)
);

INSERT INTO tick (seq, symbol, price) VALUES (1, 'WTI', 20.00);
INSERT INTO tick (seq, symbol, price) VALUES (2, 'WTI', 10.00);
INSERT INTO tick (seq, symbol, price) VALUES (3, 'WTI', 5.00);
INSERT INTO tick (seq, symbol, price) VALUES (4, 'WTI', 1.00);
INSERT INTO tick (seq, symbol, price) VALUES (5, 'WTI', 0.10);
INSERT INTO tick (seq, symbol, price) VALUES (6, 'WTI', 0.01);
INSERT INTO tick (seq, symbol, price) VALUES (7, 'WTI', 0.00);
INSERT INTO tick (seq, symbol, price) VALUES (8, 'WTI', -1.00);
INSERT INTO tick (seq, symbol, price) VALUES (9, 'WTI', -10.00);
INSERT INTO tick (seq, symbol, price) VALUES (10, 'WTI', -37.63);

\echo ''
\echo '-- 보낸 틱 10건 중 몇 건이 저장됐는가'
SELECT count(*) AS stored, 10 - count(*) AS rejected FROM tick;

\echo ''
\echo '-- 시세 화면과 증거금 엔진이 읽어 가는 최종가'
SELECT seq, price AS last_price_system_sees FROM tick ORDER BY seq DESC LIMIT 1;
