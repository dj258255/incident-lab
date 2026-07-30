-- XID 카운터를 앞으로 민다. 이게 있어야 리더 스냅샷의 xmax가 서브트랜잭션 XID
-- 범위를 넘어서고, 그제서야 가시성 판단이 pg_subtrans로 내려간다.
SELECT txid_current();
