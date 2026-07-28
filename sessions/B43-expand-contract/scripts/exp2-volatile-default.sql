-- 실험 2. volatile 기본값 ADD COLUMN.
-- gen_random_uuid()는 행마다 값이 달라야 하므로 카탈로그에 한 벌 저장하는 수법을 쓸 수 없다.
-- 테이블 전체를 다시 쓰는 동안 ACCESS EXCLUSIVE 락을 계속 쥔다.
\timing off
SELECT relfilenode AS "ALTER 전 relfilenode", pg_size_pretty(pg_relation_size(oid)) AS "힙 크기"
  FROM pg_class WHERE relname = 'orders_v1';

\timing on
ALTER TABLE orders_v1 ADD COLUMN trace_id uuid NOT NULL DEFAULT gen_random_uuid();
\timing off

SELECT relfilenode AS "ALTER 후 relfilenode", pg_size_pretty(pg_relation_size(oid)) AS "힙 크기"
  FROM pg_class WHERE relname = 'orders_v1';

SELECT attname       AS "컬럼",
       atthasmissing AS "힙에 없는 값을 카탈로그로 대신하나",
       attmissingval AS "카탈로그에 저장된 기본값"
  FROM pg_attribute
 WHERE attrelid = 'orders_v1'::regclass AND attname = 'trace_id';
