-- 주문 테이블 하나뿐이다. 세컨더리 인덱스를 일부러 만들지 않았다.
-- 인덱스가 붙으면 버퍼 풀에 클러스터드 인덱스와 세컨더리 인덱스가 섞여 들어가서
-- "풀 크기 대 데이터 크기" 비율이 흐려진다. PK 점조회만 남기면 버퍼 풀에 올라오는 것이
-- 클러스터드 인덱스 페이지 하나로 정리돼 크기 관계를 그대로 읽을 수 있다.
CREATE TABLE orders (
  id      BIGINT       NOT NULL AUTO_INCREMENT,
  user_id INT          NOT NULL,
  status  TINYINT      NOT NULL,
  amount  INT          NOT NULL,
  pad     BINARY(160)  NOT NULL,   -- 행을 약 200바이트로 부풀려 페이지당 행 수를 낮춘다
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
