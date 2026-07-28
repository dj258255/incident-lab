-- 후원 원장. 카운터만 두면 "얼마 들어왔는지"는 알아도 "누가 언제 얼마"를 못 답한다.
-- 세 변형 모두 이 INSERT를 공통으로 수행하므로, 변형 간 차이는 카운터 갱신 방식에서만 생긴다.
CREATE TABLE sponsor_log (
  id          BIGINT AUTO_INCREMENT PRIMARY KEY,
  live_id     BIGINT   NOT NULL,
  user_id     BIGINT   NOT NULL,
  amount      INT      NOT NULL,
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  KEY idx_live_created (live_id, created_at)
) ENGINE=InnoDB;

-- 변형 1: 방송당 한 행. 후원이 몰리면 이 한 행에 X락이 직렬로 걸린다.
CREATE TABLE live_counter (
  live_id       BIGINT PRIMARY KEY,
  total_amount  BIGINT NOT NULL DEFAULT 0,
  sponsor_count INT    NOT NULL DEFAULT 0
) ENGINE=InnoDB;

-- 변형 2: 방송당 N행으로 쪼갠다. 쓰기는 슬롯에 분산되고 읽기는 SUM으로 합친다.
CREATE TABLE live_counter_slot (
  live_id       BIGINT   NOT NULL,
  slot          SMALLINT NOT NULL,
  total_amount  BIGINT   NOT NULL DEFAULT 0,
  sponsor_count INT      NOT NULL DEFAULT 0,
  PRIMARY KEY (live_id, slot)
) ENGINE=InnoDB;

-- 낙관적 락 변형용. @Version 컬럼이 필요해 별도 테이블로 둔다.
CREATE TABLE live_counter_v (
  live_id       BIGINT PRIMARY KEY,
  total_amount  BIGINT NOT NULL DEFAULT 0,
  sponsor_count INT    NOT NULL DEFAULT 0,
  version       BIGINT NOT NULL DEFAULT 0
) ENGINE=InnoDB;
