-- 실험 1-보조. 기본값 없이 NOT NULL 컬럼을 붙이면 어떻게 되나.
-- 조사 단계에서 공식 문서 원문을 확보하지 못한 동작이라 직접 실행해 로그를 남긴다.
\timing on
ALTER TABLE orders_v1 ADD COLUMN must_fail integer NOT NULL;
