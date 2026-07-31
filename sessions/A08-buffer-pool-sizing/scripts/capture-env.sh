#!/usr/bin/env bash
# 측정 환경을 results/00-env.txt에 남긴다. 수치는 조건과 함께 적어야 의미가 있다.
set -euo pipefail
cd "$(dirname "$0")/.."

{
  # nproc 과 free 는 GNU 명령이라 macOS 에 없다. 그대로 두면 "호스트 CPU:  코어"
  # 같은 줄이 남는데, 실패한 줄이 성공한 줄과 모양이 같아 눈에 안 띈다.
  # 공용 도구로 옮겼다. 컨테이너가 실제로 쓰는 Docker VM 사양도 함께 남는다.
  bash ../../tools/capture-env.sh
  echo
  BP_SIZE=2G docker compose exec -T mysql mysql -uroot -plab lab -N -B -e "
    SELECT CONCAT('MySQL 버전: ', @@version);
    SELECT CONCAT('버퍼 풀 인스턴스: ', @@innodb_buffer_pool_instances);
    SELECT CONCAT('청크 크기: ', @@innodb_buffer_pool_chunk_size/1024/1024, 'M');
    SELECT CONCAT('페이지 크기: ', @@innodb_page_size/1024, 'K');
    SELECT CONCAT('기동 시 풀 로드: ', @@innodb_buffer_pool_load_at_startup);
    SELECT CONCAT('종료 시 풀 덤프: ', @@innodb_buffer_pool_dump_at_shutdown);
    SELECT CONCAT('행 수: ', FORMAT(COUNT(*),0)) FROM orders;
  " 2>/dev/null
  BP_SIZE=2G docker compose exec -T mysql mysql -uroot -plab lab -N -B -e "
    SELECT CONCAT('데이터 크기 ', ROUND(DATA_LENGTH/1024/1024), 'MB')
    FROM information_schema.TABLES WHERE TABLE_SCHEMA='lab' AND TABLE_NAME='orders';
  " 2>/dev/null
} | tee results/00-env.txt
