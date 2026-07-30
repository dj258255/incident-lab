-- XID를 하나 소비한다. 실제 사고에서는 정상 쓰기 트래픽이 이 역할을 한다.
SELECT txid_current();
