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

-- ID를 애플리케이션이 정해 넣는 대조군 테이블. AUTO_INCREMENT가 없다.
-- IDENTITY 전략이 배치를 막는지 확인하려고 SponsorAssigned 엔티티가 이 표를 쓴다.
--
-- 측정 당시 이 정의가 schema.sql에 없었습니다. 앱은 ddl-auto: none이라
-- reproduce.md 순서를 그대로 따라가면 saveAllAssigned 조건에서 실패합니다.
-- 발행 전 자기 검증에서 발견해 나중에 채운 것이라, 측정에 쓴 DDL과 글자까지
-- 같다고 보장할 수 없습니다. 아래는 엔티티 매핑에 맞춰 복원한 정의입니다.
CREATE TABLE sponsor_assigned (
  id         BIGINT PRIMARY KEY,
  live_id    BIGINT NOT NULL,
  user_id    BIGINT NOT NULL,
  amount     INT    NOT NULL,
  created_at DATETIME(3) NOT NULL,
  KEY idx_live (live_id)
) ENGINE=InnoDB;

-- Persistable.isNew() 로 merge 의 SELECT 를 없애는 변형용. 스키마는 sponsor_assigned 와 같다.
CREATE TABLE sponsor_persistable (
  id         BIGINT PRIMARY KEY,
  live_id    BIGINT NOT NULL,
  user_id    BIGINT NOT NULL,
  amount     INT    NOT NULL,
  created_at DATETIME(3) NOT NULL,
  KEY idx_live (live_id)
) ENGINE=InnoDB;
