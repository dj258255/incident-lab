-- 대조군. 바로 앞 단계의 SET NOT NULL이 빨랐던 이유가 "검증된 CHECK 제약이 있어서"인지 확인한다.
-- 같은 테이블, 같은 컬럼, 같은 데이터에서 제약만 떼고 다시 건다.
-- NOT NULL 해제와 제약 삭제는 카탈로그만 건드리므로 데이터 상태는 그대로다.
\timing off
ALTER TABLE orders_v2 ALTER COLUMN trace_id DROP NOT NULL;
ALTER TABLE orders_v2 DROP CONSTRAINT orders_v2_trace_id_not_null;

SELECT count(*) FILTER (WHERE trace_id IS NULL) AS "NULL인 행(그대로 0이어야 한다)" FROM orders_v2;
SELECT count(*) AS "orders_v2에 남은 CHECK 제약 수"
  FROM pg_constraint WHERE conrelid = 'orders_v2'::regclass AND contype = 'c';

\timing on
ALTER TABLE orders_v2 ALTER COLUMN trace_id SET NOT NULL;
\timing off
