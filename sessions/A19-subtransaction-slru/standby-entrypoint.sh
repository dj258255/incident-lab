#!/bin/bash
# 프라이머리에서 베이스백업을 떠 스탠바이로 뜬다.
set -e
until pg_isready -h a19-primary -U postgres -q; do sleep 1; done
if [ ! -f "$PGDATA/standby.signal" ]; then
  rm -rf "${PGDATA:?}"/*
  pg_basebackup -h a19-primary -U postgres -D "$PGDATA" -Fp -Xs -R -w
  chmod 700 "$PGDATA"
fi
exec postgres "$@"
