-- 후원 처리에서 원장과 통계를 서로 다른 데이터소스로 다루는 상황을 만든다.
-- 실무에서는 마스터·슬레이브 분리, 샤드 분리, 레거시 DB 병행 같은 이유로 흔하다.
CREATE TABLE sponsor (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  live_id BIGINT NOT NULL,
  amount INT NOT NULL,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
) ENGINE=InnoDB;

CREATE TABLE live_stat (
  live_id BIGINT PRIMARY KEY,
  total BIGINT NOT NULL DEFAULT 0
) ENGINE=InnoDB;

INSERT INTO live_stat (live_id, total) SELECT n, 0 FROM
  (SELECT 1 n UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5) t;
