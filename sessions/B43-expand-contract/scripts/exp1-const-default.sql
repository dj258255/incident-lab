-- 실험 1. 상수 기본값 ADD COLUMN.
-- 카탈로그와 인터넷 조언대로 "300만 행에 NOT NULL 컬럼 추가"를 그냥 걸어 본다.
-- 한 번만 재면 그 순간의 디스크 사정에 휘둘리므로 같은 형태로 세 번 건다.
-- relfilenode가 그대로면 테이블을 다시 쓰지 않았다는 뜻이다.
\timing off
SELECT relfilenode AS "ALTER 전 relfilenode", pg_size_pretty(pg_relation_size(oid)) AS "힙 크기"
  FROM pg_class WHERE relname = 'orders_v1';

\timing on
ALTER TABLE orders_v1 ADD COLUMN status_code  integer NOT NULL DEFAULT 0;
ALTER TABLE orders_v1 ADD COLUMN retry_count  integer NOT NULL DEFAULT 0;
ALTER TABLE orders_v1 ADD COLUMN is_cancelled boolean NOT NULL DEFAULT false;
\timing off

SELECT relfilenode AS "ALTER 후 relfilenode", pg_size_pretty(pg_relation_size(oid)) AS "힙 크기"
  FROM pg_class WHERE relname = 'orders_v1';

-- 300만 행 어디에도 0을 쓰지 않았는데 전부 0으로 읽힌다. 값은 카탈로그에 한 벌만 있다.
SELECT attname       AS "컬럼",
       atthasmissing AS "힙에 없는 값을 카탈로그로 대신하나",
       attmissingval AS "카탈로그에 저장된 기본값"
  FROM pg_attribute
 WHERE attrelid = 'orders_v1'::regclass
   AND attname IN ('status_code', 'retry_count', 'is_cancelled')
 ORDER BY attnum;

\timing on
SELECT count(*) AS "status_code = 0 인 행 수" FROM orders_v1 WHERE status_code = 0;
