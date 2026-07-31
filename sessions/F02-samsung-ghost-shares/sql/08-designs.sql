-- README 의 "못 한 것" 세 개를 잡는다.
--
--   1) 합계 컬럼을 물질화하는 대안을 구현하지 않았습니다
--      company 에 잔고 합계 컬럼을 두고 total_shares <= issued_shares 를 CHECK 로 걸면
--      교차행 불변식이 한 행 안으로 들어와 CHECK 범위가 된다. 대신 모든 입출고가
--      그 한 행을 갱신하므로 직렬화된다. 그 대가를 재는 것이 이 절이다.
--
--   2) 트리거가 증감을 구분하지 않습니다
--      지금 트리거는 AFTER INSERT OR UPDATE OF shares 라 매도 차감도 검증 함수를
--      지나간다. 매도는 합계를 줄이므로 검증이 필요 없는데 매번 전체 SUM 을 돈다.
--      두 방법을 다 구현한다. 행 단위 트리거와 전이 테이블이다.
--
--   3) 직렬화 비용을 재지 않았습니다
--      advisory lock 해소는 모든 매도가 잠금 하나에 줄을 서게 만든다.
--      네 설계의 매도 비용과 매수 비용을 나란히 잰다.
--
-- 네 설계:
--   A. 현재(문장 단위 트리거 + advisory lock)
--   B. 행 단위 트리거. 늘어나는 경우에만 검증한다
--   C. 전이 테이블. 문장 단위이면서 증감을 구분한다
--   D. 물질화 합계 컬럼 + CHECK

\timing off
\set ON_ERROR_STOP on

\echo ''
\echo '=================================================================='
\echo '설계 넷을 나란히: 매도 비용, 매수 비용, 직렬화'
\echo '=================================================================='

-- 재는 방법을 한 곳에 둔다. 같은 문장을 N 번 돌리고 총 소요를 밀리초로 남긴다.
CREATE TABLE IF NOT EXISTS bench (
    design text, op text, n int, ms numeric, note text
);
TRUNCATE bench;

CREATE OR REPLACE FUNCTION bench_run(p_design text, p_op text, p_n int, p_sql text)
RETURNS void AS $$
DECLARE t0 timestamptz; t1 timestamptz; i int; note text := '';
BEGIN
    t0 := clock_timestamp();
    FOR i IN 1..p_n LOOP
        BEGIN
            EXECUTE p_sql;
        EXCEPTION WHEN others THEN
            note := left(SQLERRM, 60);
        END;
    END LOOP;
    t1 := clock_timestamp();
    INSERT INTO bench VALUES (p_design, p_op,
        p_n, round(extract(epoch FROM (t1 - t0)) * 1000, 1), note);
END $$ LANGUAGE plpgsql;

-- 설계를 갈아 끼울 때마다 원장을 같은 상태로 되돌린다.
CREATE OR REPLACE FUNCTION reset_ledger() RETURNS void AS $$
BEGIN
    DROP TRIGGER IF EXISTS trg_total_cap ON holdings;
    DROP TRIGGER IF EXISTS trg_total_cap_row ON holdings;
    DROP TRIGGER IF EXISTS trg_total_cap_trans ON holdings;
    DROP TRIGGER IF EXISTS trg_sync_total ON holdings;
    ALTER TABLE company DROP CONSTRAINT IF EXISTS chk_total_within_issued;
    ALTER TABLE company DROP COLUMN IF EXISTS total_shares;
    TRUNCATE holdings;
    -- 00-seed-holdings.sql 과 같은 분포를 쓴다. holder 가 NOT NULL 이라 반드시 채운다.
    -- 예탁 합계 970,000주로 발행총수 1,000,000주의 97%다. 여유분 30,000주가
    -- 매수 조건에서 트리거가 걸리지 않고 지나갈 여지를 만든다.
    INSERT INTO holdings (account_id, holder, shares)
    SELECT i, format('조합원-%s', i), 5 + (i % 51)
    FROM generate_series(1, 999) AS i;
    INSERT INTO holdings (account_id, holder, shares)
    SELECT 1000, '기관-수탁', 970000 - coalesce(sum(shares), 0) FROM holdings;
END $$ LANGUAGE plpgsql;

\echo ''
\echo '--- A. 현재 설계: 문장 단위 트리거 + advisory lock ---'
SELECT reset_ledger();
CREATE OR REPLACE FUNCTION assert_total_within_issued() RETURNS trigger AS $$
DECLARE v_issued bigint; v_total bigint;
BEGIN
    PERFORM pg_advisory_xact_lock(20180406);
    SELECT issued_shares INTO v_issued FROM company WHERE company_id = 1;
    SELECT coalesce(sum(shares), 0) INTO v_total FROM holdings;
    IF v_total > v_issued THEN
        RAISE EXCEPTION '원장 불변식 위반: 잔고 합계 %주가 발행총수 %주를 초과', v_total, v_issued;
    END IF;
    RETURN NULL;
END $$ LANGUAGE plpgsql VOLATILE;
CREATE TRIGGER trg_total_cap AFTER INSERT OR UPDATE OF shares ON holdings
    FOR EACH STATEMENT EXECUTE FUNCTION assert_total_within_issued();
SELECT bench_run('A. 문장 단위 + advisory lock', '매도(합계 감소)', 200,
    'UPDATE holdings SET shares = shares - 1 WHERE account_id = (random()*999)::int + 1 AND shares > 0');
SELECT bench_run('A. 문장 단위 + advisory lock', '매수(합계 증가)', 200,
    'UPDATE holdings SET shares = shares + 1 WHERE account_id = (random()*999)::int + 1');

\echo ''
\echo '--- B. 행 단위 트리거: 늘어나는 경우에만 검증 ---'
SELECT reset_ledger();
CREATE OR REPLACE FUNCTION assert_row_increase() RETURNS trigger AS $$
DECLARE v_issued bigint; v_total bigint;
BEGIN
    PERFORM pg_advisory_xact_lock(20180406);
    SELECT issued_shares INTO v_issued FROM company WHERE company_id = 1;
    SELECT coalesce(sum(shares), 0) INTO v_total FROM holdings;
    IF v_total > v_issued THEN
        RAISE EXCEPTION '원장 불변식 위반: 잔고 합계 %주가 발행총수 %주를 초과', v_total, v_issued;
    END IF;
    RETURN NULL;
END $$ LANGUAGE plpgsql VOLATILE;
-- WHEN 절이 핵심이다. 잔고가 늘어난 행에서만 함수를 부른다.
-- 매도는 여기서 걸러져 SUM 을 아예 돌지 않는다.
CREATE TRIGGER trg_total_cap_row AFTER UPDATE OF shares ON holdings
    FOR EACH ROW WHEN (NEW.shares > OLD.shares)
    EXECUTE FUNCTION assert_row_increase();
CREATE TRIGGER trg_total_cap_row_ins AFTER INSERT ON holdings
    FOR EACH ROW EXECUTE FUNCTION assert_row_increase();
SELECT bench_run('B. 행 단위 + WHEN', '매도(합계 감소)', 200,
    'UPDATE holdings SET shares = shares - 1 WHERE account_id = (random()*999)::int + 1 AND shares > 0');
SELECT bench_run('B. 행 단위 + WHEN', '매수(합계 증가)', 200,
    'UPDATE holdings SET shares = shares + 1 WHERE account_id = (random()*999)::int + 1');

\echo ''
\echo '--- C. 전이 테이블: 문장 단위이면서 증감을 구분 ---'
SELECT reset_ledger();
-- REFERENCING NEW TABLE / OLD TABLE 은 그 문장이 바꾼 행 전체를 임시 관계로 준다.
-- 두 합계를 비교하면 그 문장이 총량을 늘렸는지 한 번에 알 수 있다.
-- 행 단위 트리거처럼 행마다 부르지 않으므로 대량 갱신에서 유리하다.
CREATE OR REPLACE FUNCTION assert_transition() RETURNS trigger AS $$
DECLARE v_issued bigint; v_total bigint; v_delta bigint;
BEGIN
    SELECT coalesce((SELECT sum(shares) FROM newtab), 0)
         - coalesce((SELECT sum(shares) FROM oldtab), 0) INTO v_delta;
    IF v_delta <= 0 THEN
        RETURN NULL;                        -- 총량이 안 늘었으면 검증할 것이 없다
    END IF;
    PERFORM pg_advisory_xact_lock(20180406);
    SELECT issued_shares INTO v_issued FROM company WHERE company_id = 1;
    SELECT coalesce(sum(shares), 0) INTO v_total FROM holdings;
    IF v_total > v_issued THEN
        RAISE EXCEPTION '원장 불변식 위반: 잔고 합계 %주가 발행총수 %주를 초과', v_total, v_issued;
    END IF;
    RETURN NULL;
END $$ LANGUAGE plpgsql VOLATILE;
CREATE TRIGGER trg_total_cap_trans AFTER UPDATE ON holdings
    REFERENCING OLD TABLE AS oldtab NEW TABLE AS newtab
    FOR EACH STATEMENT EXECUTE FUNCTION assert_transition();
SELECT bench_run('C. 전이 테이블', '매도(합계 감소)', 200,
    'UPDATE holdings SET shares = shares - 1 WHERE account_id = (random()*999)::int + 1 AND shares > 0');
SELECT bench_run('C. 전이 테이블', '매수(합계 증가)', 200,
    'UPDATE holdings SET shares = shares + 1 WHERE account_id = (random()*999)::int + 1');

\echo ''
\echo '--- D. 물질화 합계 컬럼 + CHECK ---'
SELECT reset_ledger();
ALTER TABLE company ADD COLUMN total_shares bigint NOT NULL DEFAULT 0;
UPDATE company SET total_shares = (SELECT coalesce(sum(shares), 0) FROM holdings)
 WHERE company_id = 1;
-- 교차행 불변식이 한 행 안으로 들어왔다. 이제 CHECK 로 표현된다.
ALTER TABLE company ADD CONSTRAINT chk_total_within_issued
    CHECK (total_shares <= issued_shares);
CREATE OR REPLACE FUNCTION sync_total() RETURNS trigger AS $$
DECLARE v_delta bigint;
BEGIN
    SELECT coalesce((SELECT sum(shares) FROM newtab), 0)
         - coalesce((SELECT sum(shares) FROM oldtab), 0) INTO v_delta;
    IF v_delta <> 0 THEN
        -- 이 한 줄이 대가다. 모든 입출고가 company 한 행을 갱신하므로
        -- 그 행의 행 잠금에 전부 줄을 선다. SUM 을 도는 비용은 사라지고
        -- 직렬화가 그 자리를 대신한다.
        UPDATE company SET total_shares = total_shares + v_delta WHERE company_id = 1;
    END IF;
    RETURN NULL;
END $$ LANGUAGE plpgsql VOLATILE;
CREATE TRIGGER trg_sync_total AFTER UPDATE ON holdings
    REFERENCING OLD TABLE AS oldtab NEW TABLE AS newtab
    FOR EACH STATEMENT EXECUTE FUNCTION sync_total();
SELECT bench_run('D. 물질화 합계 + CHECK', '매도(합계 감소)', 200,
    'UPDATE holdings SET shares = shares - 1 WHERE account_id = (random()*999)::int + 1 AND shares > 0');
SELECT bench_run('D. 물질화 합계 + CHECK', '매수(합계 증가)', 200,
    'UPDATE holdings SET shares = shares + 1 WHERE account_id = (random()*999)::int + 1');

\echo ''
\echo 'D 설계가 착오 배치를 막는지 확인:'
DO $$
BEGIN
    UPDATE holdings SET shares = shares + shares * 1000 WHERE account_id BETWEEN 1 AND 999;
    RAISE NOTICE '통과해 버렸습니다. 이 설계로는 못 막습니다';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE '거부됨(CHECK 위반): %', left(SQLERRM, 80);
END $$;

\echo ''
\echo '=================================================================='
\echo '설계별 비용 (200회씩, 1회 실행)'
\echo '=================================================================='
SELECT design AS "설계", op AS "연산", n AS "횟수",
       ms AS "총 소요(ms)", round(ms / n, 3) AS "건당(ms)"
FROM bench ORDER BY design, op;

\echo ''
\echo '매도 한 건의 비용을 A 대비 배수로:'
WITH sells AS (SELECT design, ms FROM bench WHERE op = '매도(합계 감소)'),
     base AS (SELECT ms FROM sells WHERE design LIKE 'A.%')
SELECT s.design AS "설계", s.ms AS "총 소요(ms)",
       round(s.ms / (SELECT ms FROM base), 2) AS "A 대비"
FROM sells s ORDER BY s.ms;
