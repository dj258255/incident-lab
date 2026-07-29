-- 라이브 방송과 후원. 목록 API가 방송을 페이지로 가져오면서 각 방송의 후원 정보를 함께 보여준다.
-- 전형적인 1:N이고, N+1이 태어나는 자리다.
CREATE TABLE live (
  id          BIGINT AUTO_INCREMENT PRIMARY KEY,
  title       VARCHAR(200) NOT NULL,
  streamer_id BIGINT       NOT NULL,
  created_at  DATETIME(3)  NOT NULL,
  KEY idx_created (created_at, id)
) ENGINE=InnoDB;

CREATE TABLE sponsor (
  id         BIGINT AUTO_INCREMENT PRIMARY KEY,
  live_id    BIGINT NOT NULL,
  user_id    BIGINT NOT NULL,
  amount     INT    NOT NULL,
  created_at DATETIME(3) NOT NULL,
  KEY idx_live (live_id)
) ENGINE=InnoDB;
