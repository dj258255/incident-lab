#!/usr/bin/env bash
# 같은 50만 행을 갱신하되 그것을 몇 개의 서브트랜잭션으로 나눌지만 바꾼다.
#   사용법: ./p-long-tx.sh <서브트랜잭션수> <버틸초> [갱신행수]
set -uo pipefail
NSUB="$1"; HOLD="$2"; ROWS="${3:-500000}"
if [ "$NSUB" = "0" ]; then
  BODY="UPDATE sponsor SET amount = amount + 1 WHERE id <= $ROWS;"
else
  BODY="DO \$\$
DECLARE per int := GREATEST(1, $ROWS / $NSUB);
BEGIN
  FOR s IN 0..$((NSUB - 1)) LOOP
    BEGIN
      UPDATE sponsor SET amount = amount + 1
       WHERE id > s * per AND id <= LEAST((s + 1) * per, $ROWS);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
END \$\$;"
fi
docker exec -i a19-primary psql -U postgres -d spoon -v ON_ERROR_STOP=1 <<EOF
BEGIN;
UPDATE sponsor SET amount = amount + 1 WHERE id = 1;
$BODY
SELECT pg_sleep($HOLD);
ROLLBACK;
EOF
