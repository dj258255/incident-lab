#!/bin/sh
# F02 시나리오 러너. compose가 db 준비를 확인한 뒤 이 스크립트를 실행한다.
# 버그 -> CHECK의 한계 -> 트리거 해소 -> 동시성 실험 3라운드 -> SERIALIZABLE 대안 -> maker-checker 순서.
set -eu

PSQL="psql -X -v ON_ERROR_STOP=1"
PSQL_TRY="psql -X"   # 실패 자체가 데모인 구간: 오류를 출력하고 계속 간다

hr() {
    echo ''
    echo '=================================================================='
    echo "$1"
    echo '=================================================================='
}

# 동시 입고 2세션. 첫 스크립트를 먼저 띄우고 1초 뒤 둘째를 띄운다.
# 각 세션은 UPDATE(트리거 검증) 후 3초를 기다렸다 커밋하므로 검증 구간이 겹친다.
run_race() {
    psql -X -v ON_ERROR_STOP=1 -f "$1" > /tmp/race-a.txt 2>&1 &
    PID_A=$!
    sleep 1
    psql -X -v ON_ERROR_STOP=1 -f "$2" > /tmp/race-b.txt 2>&1 &
    PID_B=$!
    wait "$PID_A" || true
    wait "$PID_B" || true
    cat /tmp/race-a.txt
    echo '------------------------------------------------------------------'
    cat /tmp/race-b.txt
}

hr '[1] 초기 원장: 발행총수 1,000,000주, 계좌 1,000개, 교차행 불변식 없음'
$PSQL -f /sql/01-schema.sql 2>&1

hr '[2] 버그 재현: 배당 배치의 원/주 단위 착오가 그대로 커밋된다'
$PSQL -f /sql/02-bug-dividend.sql 2>&1

hr '[3] CHECK 제약은 왜 못 막나: 교차행 불변식 표현 시도'
$PSQL_TRY -f /sql/03-check-limitation.sql 2>&1

hr '[4] 해소 1: 총량 검증 트리거, 같은 착오 배치가 롤백된다'
$PSQL_TRY -f /sql/04-fix-trigger.sql 2>&1

hr '[5] 동시 입고 경쟁 (다른 계좌 2건, 잠금 없는 트리거)'
$PSQL -f /sql/05-race-reset-plain.sql 2>&1
echo '서로 다른 계좌로 20,000주 대체입고 2건이 동시에 들어온다.'
echo '각각은 한도 안이고(970,000+20,000=990,000), 둘 다 커밋되면 10,000주 초과다.'
run_race /sql/race-session-a.sql /sql/race-session-b.sql
$PSQL -f /sql/race-report.sql 2>&1

hr '[6] 같은 경쟁을 같은 계좌로 (잠금 없는 트리거)'
$PSQL -f /sql/05-race-reset-plain.sql 2>&1
echo '이번에는 두 세션이 같은 계좌 101에 20,000주씩 입고한다.'
run_race /sql/race-session-a.sql /sql/race-same-b.sql
$PSQL -f /sql/race-report.sql 2>&1
psql -X -c "SELECT account_id AS \"계좌\", shares AS \"잔고(주)\" FROM holdings WHERE account_id = 101;"

hr '[7] 해소 1 보강: advisory lock으로 총량 검증 직렬화 (다른 계좌 2건)'
$PSQL -f /sql/06-race-reset-lock.sql 2>&1
run_race /sql/race-session-a.sql /sql/race-session-b.sql
$PSQL -f /sql/race-report.sql 2>&1

hr '[8] 대안: 잠금 없는 트리거 + SERIALIZABLE 격리 (다른 계좌 2건)'
$PSQL -f /sql/05-race-reset-plain.sql 2>&1
run_race /sql/race-ser-a.sql /sql/race-ser-b.sql
$PSQL -f /sql/race-report.sql 2>&1

hr '[9] 해소 2: maker-checker, 발행총수 1% 초과 입고는 승인 대기'
$PSQL_TRY -f /sql/07-maker-checker.sql 2>&1

hr '끝. 본문 수치는 전부 위 출력에서 가져간다.'
