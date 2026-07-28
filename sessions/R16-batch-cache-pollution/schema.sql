-- 핫 테이블: 실시간 조회가 도는 주문 테이블. 버퍼 풀(1GB)에 다 들어가는 크기(약 300MB)로 만든다.
-- pad 컬럼은 행 크기를 실제 주문 행과 비슷하게 맞추는 역할이다.
CREATE TABLE orders_hot (
  id        BIGINT AUTO_INCREMENT PRIMARY KEY,
  user_id   BIGINT      NOT NULL,
  status    TINYINT     NOT NULL,
  amount    INT         NOT NULL,
  pad       VARBINARY(128) NOT NULL,
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  KEY idx_user (user_id)
) ENGINE=InnoDB;

-- 콜드 테이블: 정산 배치가 풀 스캔하는 이력 테이블. 버퍼 풀보다 크게(약 2GB) 만든다.
CREATE TABLE settlement_history (
  id        BIGINT AUTO_INCREMENT PRIMARY KEY,
  order_id  BIGINT      NOT NULL,
  amount    INT         NOT NULL,
  fee       INT         NOT NULL,
  pad       VARBINARY(200) NOT NULL,
  created_at DATETIME(3) NOT NULL
) ENGINE=InnoDB;
