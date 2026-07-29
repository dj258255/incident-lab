-- 라이브 커머스 주문을 가정한 테이블. 인덱스는 전부 "제대로" 걸려 있다.
-- 이 세션의 주제는 인덱스 부재가 아니라, 있는 인덱스를 쿼리가 못 쓰게 만드는 조건이다.

CREATE TABLE orders (
  id           BIGINT AUTO_INCREMENT PRIMARY KEY,
  -- 주문번호를 문자열로 둔다. 레거시에서 흔한 선택이고, 형변환 함정의 무대가 된다.
  order_no     VARCHAR(32)  NOT NULL,
  user_id      BIGINT       NOT NULL,
  -- 상태 플래그를 비트로 묶은 컬럼. LINE 사례와 같은 구조다.
  status_flag  INT          NOT NULL,
  amount       INT          NOT NULL,
  buyer_name   VARCHAR(64)  NOT NULL,
  created_at   DATETIME(3)  NOT NULL,
  KEY idx_order_no (order_no),
  KEY idx_user_created (user_id, created_at),
  KEY idx_buyer (buyer_name),
  KEY idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 조인 상대. 문자셋을 일부러 다르게 둔다(레거시 테이블을 물려받은 상황).
-- MySQL 문서가 "utf8mb4 컬럼과 latin1 컬럼 비교는 인덱스 사용을 배제한다"고 적은 그 조건이다.
CREATE TABLE order_legacy (
  order_no     VARCHAR(32)  NOT NULL PRIMARY KEY,
  memo         VARCHAR(200) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- 같은 데이터를 문자셋만 맞춰 만든 대조군. 해소 후 비교에 쓴다.
CREATE TABLE order_legacy_fixed (
  order_no     VARCHAR(32)  NOT NULL PRIMARY KEY,
  memo         VARCHAR(200) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
