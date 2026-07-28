-- 불변식이 없는 원장 스키마.
-- CHECK는 전부 행 단위다. '잔고 합계 <= 발행총수' 같은 교차행 불변식은 어디에도 없다.
DROP TABLE IF EXISTS share_credits;
DROP TABLE IF EXISTS holdings;
DROP TABLE IF EXISTS company;

CREATE TABLE company (
    company_id    int    PRIMARY KEY,
    name          text   NOT NULL,
    issued_shares bigint NOT NULL CHECK (issued_shares > 0)   -- 행 단위 CHECK
);

CREATE TABLE holdings (
    account_id int    PRIMARY KEY,
    holder     text   NOT NULL,
    shares     bigint NOT NULL DEFAULT 0 CHECK (shares >= 0), -- 행 단위 CHECK: 음수 잔고 금지
    cash_krw   bigint NOT NULL DEFAULT 0 CHECK (cash_krw >= 0)
);

INSERT INTO company VALUES (1, '가상증권(축소 모형)', 1000000);
\ir 00-seed-holdings.sql

\echo '초기 원장 상태:'
SELECT c.issued_shares                    AS "발행총수(주)",
       (SELECT count(*) FROM holdings)    AS "계좌 수",
       (SELECT sum(shares) FROM holdings) AS "잔고 합계(주)",
       round((SELECT sum(shares) FROM holdings)::numeric / c.issued_shares, 2)
                                          AS "합계/발행총수"
FROM company c;
