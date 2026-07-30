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

-- JPA 조건(@GeneratedValue(AUTO))이 쓰는 테이블. ddl-auto: none이므로 여기서 만든다.
-- 세션을 만들 때는 손으로 만들고 스키마에 넣지 않아서, 문서대로 따라가면
-- "테이블 없음"으로 실패했다. CONVENTIONS 11절의 "적은 대로 재현되는가"에 걸린 자리다.
CREATE TABLE sponsor_jpa (
  id BIGINT PRIMARY KEY,
  live_id BIGINT NOT NULL,
  amount INT NOT NULL
) ENGINE=InnoDB;

-- Hibernate 6은 엔티티별 시퀀스 테이블을 쓴다. 행이 없으면 채번이 조용히 실패하므로
-- 시드 행을 함께 넣는다. next_val을 지우면 이후 INSERT가 에러 없이 아무 일도 안 한다.
CREATE TABLE sponsor_jpa_seq (
  next_val BIGINT
) ENGINE=InnoDB;
INSERT INTO sponsor_jpa_seq (next_val) VALUES (1);
