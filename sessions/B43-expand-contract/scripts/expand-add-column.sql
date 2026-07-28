-- 해소 2, 1단계(expand). nullable 컬럼을 기본값 없이 추가한다.
-- 기본값이 없으면 카탈로그에 저장할 값조차 없으므로 힙은 한 바이트도 건드리지 않는다.
\timing off
SELECT relfilenode AS "1단계 전 relfilenode", pg_size_pretty(pg_relation_size(oid)) AS "힙 크기"
  FROM pg_class WHERE relname = 'orders_v2';

\timing on
ALTER TABLE orders_v2 ADD COLUMN trace_id uuid;
\timing off

SELECT relfilenode AS "1단계 후 relfilenode", pg_size_pretty(pg_relation_size(oid)) AS "힙 크기"
  FROM pg_class WHERE relname = 'orders_v2';
