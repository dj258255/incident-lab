-- 라이브 방송의 일별 정산 테이블.
-- (live_id, settle_date)에 유니크 제약이 있어 "없으면 넣고 있으면 더한다"를 하게 되는데,
-- 그 패턴이 갭 락 데드락의 표준 무대다.
CREATE TABLE settlement (
  id          BIGINT AUTO_INCREMENT PRIMARY KEY,
  live_id     BIGINT NOT NULL,
  settle_date DATE   NOT NULL,
  amount      BIGINT NOT NULL DEFAULT 0,
  UNIQUE KEY uk_live_date (live_id, settle_date)
) ENGINE=InnoDB;

-- 시나리오 2용. 인덱스가 없는 컬럼으로 UPDATE하면 락 범위가 통째로 넓어진다.
CREATE TABLE payout (
  id       BIGINT AUTO_INCREMENT PRIMARY KEY,
  live_id  BIGINT NOT NULL,
  status   VARCHAR(20) NOT NULL,
  amount   BIGINT NOT NULL,
  KEY idx_live (live_id)
) ENGINE=InnoDB;
