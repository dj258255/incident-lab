#!/bin/sh
# B43 expand-contract 시나리오 러너.
# compose가 db 준비를 확인한 뒤 이 스크립트를 실행한다. 순서는
#   시드 -> 상수 기본값(재현 실패) -> volatile 기본값(재작성) -> SELECT 대기
#   -> 락 큐잉 -> 해소 1(lock_timeout) -> 해소 2(3단계 expand-contract) -> 재계측 요약
# 이다. 여러 psql 세션을 sleep 간격으로 띄워 락 대기 사슬을 만든다.
set -eu

PSQL='psql -X -v ON_ERROR_STOP=1'
PSQL_TRY='psql -X'          # 실패 자체가 데모인 구간: 오류를 출력하고 계속 간다
ROWS=${ROWS:-3000000}
CHUNK=${CHUNK:-100000}

hr() {
    echo ''
    echo '=================================================================='
    echo "$1"
    echo '=================================================================='
}

# 파일에 찍힌 psql \timing 출력(ms)을 골라낸다. 요약표는 이 두 함수로만 만든다.
# max_time: 그 파일에서 가장 오래 걸린 문장. nth_time: n번째로 계측된 문장.
max_time() {
    awk '{ for (i = 1; i < NF; i++) if ($i == "Time:") { v = $(i + 1) + 0; if (v > m) m = v } }
         END { printf "%.3f", m }' "$1" 2>/dev/null
}
nth_time() {
    awk -v want="$2" '{ for (i = 1; i < NF; i++) if ($i == "Time:") { c++;
                          if (c == want) { printf "%.3f", $(i + 1) + 0; exit } } }' "$1" 2>/dev/null
}

# SELECT count(*) 한 번을 재고 소요 시간만 남긴다.
probe() {   # $1 = 테이블, $2 = 반복, $3 = 간격(초), $4 = 이름표
    n=1
    while [ "$n" -le "$2" ]; do
        printf '  %s %s회차: ' "$4" "$n"
        PGAPPNAME=probe psql -X -q -t -A -c '\timing on' -c "SELECT count(*) FROM $1;" | tr '\n' ' '
        echo ''
        n=$((n + 1))
        if [ "$n" -le "$2" ]; then sleep "$3"; fi
    done
}

# 락 스냅샷. 원하는 장면이 잡힐 때까지 짧게 폴링한다(대상 문장이 짧아 한 번에 못 잡을 수 있다).
snap_locks() {   # $1 = 테이블, $2 = 이 문자열이 보이면 채택, $3 = 최대 시도, $4 = 간격(초)
    tries=${3:-60}
    gap=${4:-0.2}
    n=1
    while [ "$n" -le "$tries" ]; do
        OUT=$(PGAPPNAME=lockwatch psql -X -v tbl="$1" -f /scripts/locks.sql 2>&1 || true)
        if echo "$OUT" | grep -qF "$2"; then
            echo "$OUT"
            return 0
        fi
        sleep "$gap"
        n=$((n + 1))
    done
    echo "(스냅샷을 잡지 못했습니다: 조건 '$2')"
}

now_ts() { psql -X -t -A -c 'SELECT clock_timestamp();'; }
elapsed_s() { psql -X -t -A -c "SELECT round(extract(epoch FROM (clock_timestamp() - timestamptz '$1'))::numeric, 3);"; }

# ---------------------------------------------------------------- 0
hr '[0] 환경'
$PSQL <<'SQL'
SELECT version();
SHOW lock_timeout;
SHOW deadlock_timeout;
SQL

# ---------------------------------------------------------------- 1
hr "[1] 시드: ${ROWS}행 주문 테이블 두 벌 (orders_v1 = 문제 방식, orders_v2 = 해소 방식)"
$PSQL -v rows="$ROWS" -f /scripts/seed.sql

# ---------------------------------------------------------------- 2
hr '[2] 실험 1: 상수 기본값 ADD COLUMN. 카탈로그대로 걸면 재현에 실패한다'
$PSQL -f /scripts/exp1-const-default.sql > /tmp/e1.txt 2>&1
cat /tmp/e1.txt
echo ''
echo '기본값 없이 NOT NULL만 붙이면 어떻게 되나:'
$PSQL_TRY -f /scripts/exp1b-no-default.sql 2>&1 || true

# ---------------------------------------------------------------- 3
hr '[3] 실험 2·3: volatile 기본값 ADD COLUMN. 재작성이 일어나고 그동안 SELECT가 막힌다'
echo '기준선(락 없음): SELECT count(*) 3회'
probe orders_v1 3 1 '기준선' | tee /tmp/e3-base.txt

echo ''
echo 'volatile ALTER를 걸고 1초 뒤 다른 세션에서 SELECT count(*)를 실행한다.'
( PGAPPNAME=ddl psql -X -v ON_ERROR_STOP=1 -f /scripts/exp2-volatile-default.sql ) > /tmp/e3-ddl.txt 2>&1 &
P_DDL=$!
sleep 1
( PGAPPNAME=reader psql -X -c '\timing on' -c 'SELECT count(*) FROM orders_v1;' ) > /tmp/e3-reader.txt 2>&1 &
P_R=$!
sleep 1
snap_locks orders_v1 'AccessExclusiveLock' > /tmp/e3-locks.txt 2>&1
wait "$P_DDL" || true
wait "$P_R" || true

echo ''
echo '--- volatile ALTER 세션 (application_name=ddl) ---'
cat /tmp/e3-ddl.txt
echo '--- ALTER가 도는 동안의 락 상태 ---'
cat /tmp/e3-locks.txt
echo '--- 그동안 대기하던 SELECT 세션 (application_name=reader) ---'
cat /tmp/e3-reader.txt

# ---------------------------------------------------------------- 4
hr '[4] 실험 4: 락 큐잉. 빠른 ALTER가 장기 트랜잭션 뒤에 서면 뒤따르는 SELECT까지 전부 줄을 선다'
echo '재작성 뒤 기준선을 다시 잰다(테이블이 커졌다).'
probe orders_v1 2 1 '기준선' | tee /tmp/e4-base.txt

echo ''
echo '타임라인: 0초 장기 트랜잭션(12초 유지) / 2초 ALTER / 4·5·6초 평범한 SELECT 3건'
( PGAPPNAME=long-txn psql -X -v ON_ERROR_STOP=1 -f /scripts/hold-access-share.sql ) > /tmp/e4-hold.txt 2>&1 &
P_H=$!
sleep 2
( PGAPPNAME=ddl psql -X -v ON_ERROR_STOP=1 -f /scripts/fast-alter.sql ) > /tmp/e4-ddl.txt 2>&1 &
P_D=$!
sleep 2
( PGAPPNAME=reader-1 psql -X -c '\timing on' -c 'SELECT count(*) FROM orders_v1;' ) > /tmp/e4-r1.txt 2>&1 &
P_1=$!
sleep 1
( PGAPPNAME=reader-2 psql -X -c '\timing on' -c 'SELECT count(*) FROM orders_v1;' ) > /tmp/e4-r2.txt 2>&1 &
P_2=$!
sleep 1
( PGAPPNAME=reader-3 psql -X -c '\timing on' -c 'SELECT count(*) FROM orders_v1;' ) > /tmp/e4-r3.txt 2>&1 &
P_3=$!
sleep 1
snap_locks orders_v1 'reader-3' > /tmp/e4-locks.txt 2>&1
wait "$P_H" || true
wait "$P_D" || true
wait "$P_1" || true
wait "$P_2" || true
wait "$P_3" || true

echo ''
echo '--- 대기 사슬 (장기 트랜잭션 시작 7초 시점) ---'
cat /tmp/e4-locks.txt
echo '--- 장기 트랜잭션 세션 ---'
cat /tmp/e4-hold.txt
echo '--- ALTER 세션: 실험 1에서 밀리초에 끝났던 것과 같은 종류의 문장이다 ---'
cat /tmp/e4-ddl.txt
echo '--- 뒤에 줄 선 평범한 SELECT 3건 ---'
cat /tmp/e4-r1.txt
cat /tmp/e4-r2.txt
cat /tmp/e4-r3.txt

# ---------------------------------------------------------------- 5
hr '[5] 해소 1: lock_timeout으로 대기를 끊는다 (기본값 0 = 무제한)'
echo '같은 타임라인에 ALTER 세션만 lock_timeout = 2s 로 바꾼다.'
( PGAPPNAME=long-txn psql -X -v ON_ERROR_STOP=1 -f /scripts/hold-access-share.sql ) > /tmp/e5-hold.txt 2>&1 &
P_H=$!
sleep 2
( PGAPPNAME=ddl psql -X -f /scripts/fast-alter-timeout.sql ) > /tmp/e5-ddl.txt 2>&1 &
P_D=$!
sleep 1
( PGAPPNAME=reader-1 psql -X -c '\timing on' -c 'SELECT count(*) FROM orders_v1;' ) > /tmp/e5-r1.txt 2>&1 &
P_1=$!
sleep 4
( PGAPPNAME=reader-2 psql -X -c '\timing on' -c 'SELECT count(*) FROM orders_v1;' ) > /tmp/e5-r2.txt 2>&1 &
P_2=$!
wait "$P_D" || true
wait "$P_1" || true
wait "$P_2" || true
wait "$P_H" || true

echo ''
echo '--- ALTER 세션 (lock_timeout = 2s) ---'
cat /tmp/e5-ddl.txt
echo '--- ALTER 뒤에 줄 섰던 SELECT (3초 시점 시작) ---'
cat /tmp/e5-r1.txt
echo '--- ALTER가 물러난 뒤 들어온 SELECT (7초 시점 시작) ---'
cat /tmp/e5-r2.txt
echo '--- 장기 트랜잭션이 끝난 뒤 같은 ALTER를 다시 건다 ---'
$PSQL_TRY -f /scripts/fast-alter-retry.sql > /tmp/e5-retry.txt 2>&1 || true
cat /tmp/e5-retry.txt

# ---------------------------------------------------------------- 6
hr "[6] 해소 2: 3단계 expand-contract (orders_v2, 손대지 않은 ${ROWS}행)"
echo '목표는 실험 2와 같다. 모든 행에 uuid 값이 든 NOT NULL 컬럼을 만든다.'
echo ''
echo '기준선(락 없음): SELECT count(*) 2회'
probe orders_v2 2 1 '기준선' | tee /tmp/e6-base.txt

echo ''
echo '--- 1단계(expand): nullable 컬럼 추가 ---'
$PSQL -f /scripts/expand-add-column.sql > /tmp/e6-s1.txt 2>&1
cat /tmp/e6-s1.txt

echo ''
echo "--- 2단계(backfill): ${CHUNK}행씩 나눠 UPDATE. 청크마다 커밋한다 ---"
( probe orders_v2 8 5 '  백필 중 SELECT' ) > /tmp/e6-s2probe.txt 2>&1 &
P_P=$!
BF_START=$(now_ts)
i=0
while [ "$i" -lt "$ROWS" ]; do
    psql -X -q -c "UPDATE orders_v2 SET trace_id = gen_random_uuid() WHERE id > $i AND id <= $((i + CHUNK)) AND trace_id IS NULL;" > /dev/null
    i=$((i + CHUNK))
done
BF_SEC=$(elapsed_s "$BF_START")
wait "$P_P" || true
echo "  백필 전체 소요 = ${BF_SEC} 초 (${CHUNK}행 x $((ROWS / CHUNK))청크)"
cat /tmp/e6-s2probe.txt
psql -X -c "SELECT count(*) AS \"trace_id 채워진 행\", count(*) FILTER (WHERE trace_id IS NULL) AS \"아직 NULL\" FROM orders_v2;"
psql -X -c "SELECT pg_size_pretty(pg_relation_size('orders_v2')) AS \"백필 후 힙 크기\", n_live_tup AS \"산 튜플\", n_dead_tup AS \"죽은 튜플\", coalesce(last_autovacuum::text, '아직 없음') AS \"마지막 autovacuum\" FROM pg_stat_user_tables WHERE relname = 'orders_v2';"

echo ''
echo '--- 3단계(contract) 앞: CHECK ... NOT VALID ---'
$PSQL -f /scripts/contract-constraint.sql > /tmp/e6-s3.txt 2>&1
cat /tmp/e6-s3.txt

echo ''
echo '--- 3단계(contract) 뒤: VALIDATE CONSTRAINT. 락을 쥔 채로 SELECT를 같이 돌린다 ---'
( PGAPPNAME=ddl psql -X -v ON_ERROR_STOP=1 -f /scripts/contract-validate.sql ) > /tmp/e6-s4.txt 2>&1 &
P_V=$!
sleep 1
( PGAPPNAME=reader psql -X -f /scripts/read-v2-thrice.sql ) > /tmp/e6-s4reader.txt 2>&1 &
P_VR=$!
( snap_locks orders_v2 'SELECT count(*) FROM orders_v2;' 40 0.1 ) > /tmp/e6-s4locks.txt 2>&1 &
P_W=$!
wait "$P_V" || true
wait "$P_VR" || true
wait "$P_W" || true
echo '--- VALIDATE 세션이 락을 쥐고 있는 동안의 락 상태 ---'
cat /tmp/e6-s4locks.txt
echo '--- VALIDATE 세션 ---'
cat /tmp/e6-s4.txt
echo '--- 같은 시각에 돌린 SELECT ---'
cat /tmp/e6-s4reader.txt

echo ''
echo '--- 마지막: 검증된 CHECK가 있는 상태에서 SET NOT NULL ---'
$PSQL -f /scripts/contract-set-not-null.sql > /tmp/e6-s5.txt 2>&1
cat /tmp/e6-s5.txt

echo ''
echo '--- 대조군: 검증된 CHECK를 떼고 같은 SET NOT NULL을 다시 건다 ---'
$PSQL -f /scripts/control-set-not-null.sql > /tmp/e6-ctl.txt 2>&1
cat /tmp/e6-ctl.txt

echo ''
echo '--- 두 방식이 남긴 테이블 크기 ---'
psql -X -c "SELECT relname AS \"테이블\", pg_size_pretty(pg_relation_size(oid)) AS \"힙 크기\", pg_size_pretty(pg_total_relation_size(oid)) AS \"인덱스 포함\" FROM pg_class WHERE relname IN ('orders_v1','orders_v2') ORDER BY relname;"

# ---------------------------------------------------------------- 7
hr '[7] 재계측 요약'
PG_VER=$(psql -X -t -A -c "SHOW server_version;")
EC_TOTAL=$(awk -v a="$(max_time /tmp/e6-s1.txt)" -v b="$BF_SEC" \
               -v c="$(max_time /tmp/e6-s3.txt)" -v d="$(max_time /tmp/e6-s4.txt)" \
               -v e="$(max_time /tmp/e6-s5.txt)" \
               'BEGIN { printf "%.1f", (a + c + d + e) / 1000 + b }')
cat <<SUMMARY
조건: PostgreSQL ${PG_VER}, ${ROWS}행, 같은 시드로 만든 두 테이블. 시간 단위는 ms.
문장 하나가 자기 트랜잭션에서 실행되므로 문장 소요 시간이 곧 락 보유 시간의 상한이다.

[문제 A] volatile 기본값 한 방 ALTER (orders_v1)
  ALTER 소요 = ACCESS EXCLUSIVE 보유 : $(max_time /tmp/e3-ddl.txt) ms
  그동안 다른 세션 SELECT count(*)   : $(max_time /tmp/e3-reader.txt) ms
  락 없을 때 같은 SELECT (기준선)    : $(max_time /tmp/e3-base.txt) ms

[문제 B] 장기 트랜잭션 뒤에 선 빠른 ALTER (락 큐잉)
  상수 기본값 ALTER 단독 실행 3회    : $(nth_time /tmp/e1.txt 1) / $(nth_time /tmp/e1.txt 2) / $(nth_time /tmp/e1.txt 3) ms
  같은 ALTER가 대기 뒤에 섰을 때     : $(max_time /tmp/e4-ddl.txt) ms
  그 뒤에 줄 선 평범한 SELECT 3건    : $(max_time /tmp/e4-r1.txt) / $(max_time /tmp/e4-r2.txt) / $(max_time /tmp/e4-r3.txt) ms
  락 없을 때 같은 SELECT (기준선)    : $(max_time /tmp/e4-base.txt) ms

[해소 1] lock_timeout = 2s
  ALTER                              : $(grep -c 'lock timeout' /tmp/e5-ddl.txt || true) 건 취소, 대기 $(max_time /tmp/e5-ddl.txt) ms 만에 포기
  그 뒤에 줄 섰던 SELECT             : $(max_time /tmp/e5-r1.txt) ms
  ALTER가 물러난 뒤 들어온 SELECT    : $(max_time /tmp/e5-r2.txt) ms
  장기 트랜잭션 종료 후 재시도       : $(max_time /tmp/e5-retry.txt) ms

[해소 2] 3단계 expand-contract (orders_v2)
  1단계 ADD COLUMN (nullable)        : $(max_time /tmp/e6-s1.txt) ms   <- ACCESS EXCLUSIVE 최대 보유
  2단계 백필 ${CHUNK}행 x $((ROWS / CHUNK))청크 전체    : ${BF_SEC} 초 (SELECT는 아래 표에)
  3단계 CHECK ... NOT VALID          : $(max_time /tmp/e6-s3.txt) ms
  4단계 VALIDATE CONSTRAINT          : $(max_time /tmp/e6-s4.txt) ms (SHARE UPDATE EXCLUSIVE)
  4단계와 동시에 돌린 SELECT         : $(max_time /tmp/e6-s4reader.txt) ms
  5단계 SET NOT NULL                 : $(max_time /tmp/e6-s5.txt) ms
  (대조군) CHECK 없이 SET NOT NULL   : $(max_time /tmp/e6-ctl.txt) ms
  락 없을 때 같은 SELECT (기준선)    : $(max_time /tmp/e6-base.txt) ms
  1~5단계 전체 소요                  : ${EC_TOTAL} 초 (한 방 ALTER보다 길다. 이게 정직한 결과다)
SUMMARY

echo ''
echo '백필이 도는 동안 잰 SELECT count(*):'
cat /tmp/e6-s2probe.txt

hr '끝. 본문 수치는 전부 위 출력에서 가져간다.'
