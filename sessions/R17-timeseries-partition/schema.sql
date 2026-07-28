-- 시청 로그 두 판. 같은 데이터를 넣고 "오래된 날짜를 지우는" 두 방법을 비교한다.
--
-- 파티션 키 규칙 (MySQL 공식 제약):
--   파티션 식에 쓰인 컬럼은 테이블의 모든 UNIQUE 키(PK 포함)에 들어가야 한다.
--   그래서 watch_log_part의 PK는 (id, created_at)이다. id 하나만 두면 ERROR 1491이 난다.
--   그 에러는 재현 기록에 원문으로 남긴다.

-- 1) 파티션 없는 판. 삭제는 DELETE로만 가능하다.
CREATE TABLE watch_log_plain (
  id         BIGINT AUTO_INCREMENT PRIMARY KEY,
  live_id    BIGINT      NOT NULL,
  user_id    BIGINT      NOT NULL,
  event_type TINYINT     NOT NULL,          -- 0 입장, 1 퇴장, 2 채팅, 3 선물
  created_at DATETIME(3) NOT NULL,
  KEY idx_live_created (live_id, created_at)
) ENGINE=InnoDB;

-- 2) 일 단위 RANGE 파티션 판. 오래된 날짜는 DROP PARTITION으로 지운다.
--    TO_DAYS()는 파티션 프루닝이 동작하는 소수의 함수 중 하나다.
CREATE TABLE watch_log_part (
  id         BIGINT AUTO_INCREMENT,
  live_id    BIGINT      NOT NULL,
  user_id    BIGINT      NOT NULL,
  event_type TINYINT     NOT NULL,
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (id, created_at),
  KEY idx_live_created (live_id, created_at)
) ENGINE=InnoDB
PARTITION BY RANGE (TO_DAYS(created_at)) (
  PARTITION p20260714 VALUES LESS THAN (TO_DAYS('2026-07-15')),
  PARTITION p20260715 VALUES LESS THAN (TO_DAYS('2026-07-16')),
  PARTITION p20260716 VALUES LESS THAN (TO_DAYS('2026-07-17')),
  PARTITION p20260717 VALUES LESS THAN (TO_DAYS('2026-07-18')),
  PARTITION p20260718 VALUES LESS THAN (TO_DAYS('2026-07-19')),
  PARTITION p20260719 VALUES LESS THAN (TO_DAYS('2026-07-20')),
  PARTITION p20260720 VALUES LESS THAN (TO_DAYS('2026-07-21')),
  PARTITION p20260721 VALUES LESS THAN (TO_DAYS('2026-07-22')),
  PARTITION p20260722 VALUES LESS THAN (TO_DAYS('2026-07-23')),
  PARTITION p20260723 VALUES LESS THAN (TO_DAYS('2026-07-24')),
  PARTITION p20260724 VALUES LESS THAN (TO_DAYS('2026-07-25')),
  PARTITION p20260725 VALUES LESS THAN (TO_DAYS('2026-07-26')),
  PARTITION p20260726 VALUES LESS THAN (TO_DAYS('2026-07-27')),
  PARTITION p20260727 VALUES LESS THAN (TO_DAYS('2026-07-28')),
  PARTITION pmax      VALUES LESS THAN MAXVALUE
);
