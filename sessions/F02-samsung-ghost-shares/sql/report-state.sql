-- 원장 상태 리포트. 여러 장면이 \ir로 공유한다.
SELECT c.issued_shares                    AS "발행총수(주)",
       (SELECT sum(shares) FROM holdings) AS "잔고 합계(주)",
       round((SELECT sum(shares) FROM holdings)::numeric / c.issued_shares, 2)
                                          AS "합계/발행총수"
FROM company c;
