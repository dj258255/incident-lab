-- 조회 부하를 받을 테이블 하나. DDL 대상도 이 테이블이다.
CREATE TABLE orders (
  id      BIGINT       NOT NULL AUTO_INCREMENT,
  user_id INT          NOT NULL,
  status  TINYINT      NOT NULL,
  amount  INT          NOT NULL,
  pad     BINARY(100)  NOT NULL,
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
