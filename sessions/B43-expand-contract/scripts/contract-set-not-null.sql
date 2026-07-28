-- 해소 2, 마지막. 검증된 CHECK 제약이 있는 상태에서 컬럼에 NOT NULL을 붙인다.
-- 여기서 다시 300만 행을 훑는지 아닌지가 이 단계의 값어치를 가른다. 직접 잰다.
\timing on
ALTER TABLE orders_v2 ALTER COLUMN trace_id SET NOT NULL;
\timing off

SELECT attname AS "컬럼", attnotnull AS "NOT NULL"
  FROM pg_attribute WHERE attrelid = 'orders_v2'::regclass AND attname = 'trace_id';
