#!/bin/bash
# 스탠바이가 붙을 수 있게 복제 접속을 연다. 랩 전용 설정이다.
set -e
echo "host replication all all trust" >> "$PGDATA/pg_hba.conf"
echo "host all all all trust"         >> "$PGDATA/pg_hba.conf"
