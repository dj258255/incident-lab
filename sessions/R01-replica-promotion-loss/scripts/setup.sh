#!/usr/bin/env bash
# 복제를 구성한다. 소스에 스키마를 만들고 레플리카를 GTID 자동 위치로 붙인다.
set -euo pipefail

S() { docker exec r01-source  mysql -uroot -plab -e "$1" 2>/dev/null; }
R() { docker exec r01-replica mysql -uroot -plab -e "$1" 2>/dev/null; }

S "CREATE TABLE IF NOT EXISTS spoon.sponsor (
     id BIGINT AUTO_INCREMENT PRIMARY KEY,
     seq BIGINT NOT NULL,
     user_id BIGINT NOT NULL,
     amount INT NOT NULL,
     created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3)
   );"

R "STOP REPLICA; RESET REPLICA ALL;" 2>/dev/null || true
R "CHANGE REPLICATION SOURCE TO
     SOURCE_HOST='source', SOURCE_USER='root', SOURCE_PASSWORD='lab',
     SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1;
   START REPLICA;"
sleep 3
R "SHOW REPLICA STATUS\G" 2>/dev/null | grep -E "Replica_IO_Running|Replica_SQL_Running|Seconds_Behind"
