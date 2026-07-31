#!/usr/bin/env bash
# Oracle 아카이브 로그 모드 전환에 드는 정지 시간.
#
# exp5 에 이렇게 적었다.
#   "이 이미지는 ARCHIVELOG 로 출고됩니다. 켜는 과정을 밟지 못했습니다."
#
# 출고 상태가 그렇다는 것이 못 하는 이유는 아니다. 끄고 다시 켜면 된다.
# 이 실험은 그 왕복을 재고, 다른 엔진과 갈리는 자리를 눈으로 본다.
#
#   1) NOARCHIVELOG 로 내린다. 여기가 이미 정지를 요구한다
#   2) 그 상태에서 RMAN 이 시점 복구를 어떻게 거절하는지 본다
#   3) ARCHIVELOG 로 되돌린다. 정지 시간을 잰다
#
# 대조군:
#   MySQL      log-bin      재기동 1회
#   PostgreSQL archive_mode 재기동 1회
#   Oracle     ARCHIVELOG   내리고 → mount 로 올리고 → 바꾸고 → open. 단계가 더 있다
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
SQL(){ docker exec -i a23-oracle bash -lc "sqlplus -S / as sysdba" <<EOF 2>&1
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200 TRIMSPOOL ON
$1
EOF
}
RMAN(){ docker exec -i a23-oracle bash -lc "rman target /" <<EOF 2>&1
$1
EOF
}
mode(){ SQL "SELECT log_mode FROM v\$database;" | tr -d ' \r\n'; }
# 열려 있는지. mount 상태에서는 OPEN 이 아니다.
opened(){ SQL "SELECT open_mode FROM v\$database;" | tr -d ' \r\n'; }

# 준비 확인. 질의문에 없는 문자열이 결과로 나와야 성공으로 본다.
# 원래 SELECT 'PING' 을 던지고 출력에서 PING 을 찾았는데, 실패하면 sqlplus 가
# 질의문을 그대로 echo 하므로 그 안의 PING 이 매칭됐다. 인스턴스가 안 떠 있는데도
# 준비된 것으로 판정해 그대로 진행했고, 실험 전체가 ORA-01034 로 채워졌다.
# 문자열을 이어 붙이면 질의문에는 PING 이 없고 결과에만 나온다.
ready(){ SQL "SELECT 'PI'||'NG' FROM dual;" | grep -q "PING"; }
for _ in $(seq 1 150); do ready && break; sleep 5; done
ready || { echo "중단: a23-oracle 이 쿼리를 받지 못합니다" >&2; exit 2; }

{
echo "# Oracle 아카이브 로그 모드 전환에 드는 정지 시간"
SQL "SELECT banner FROM v\$version WHERE ROWNUM=1;" | tr -s ' ' | sed 's/^/# /'
echo "# 출고 상태 log_mode = $(mode), open_mode = $(opened)"
echo

# ── 1) 끈다 ─────────────────────────────────────────────────────────────
echo "## 1) ARCHIVELOG 를 끈다"
echo "  이것부터가 정지를 요구합니다. 데이터베이스를 내리고 mount 로 올려야 합니다."
T0=$(date +%s)
SQL "SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE NOARCHIVELOG;
ALTER DATABASE OPEN;" | grep -iE "ORA-|altered|Database (closed|dismounted|mounted|opened)" | head -8 | sed 's/^/    /'
T1=$(date +%s)
DOWN_OFF=$((T1 - T0))
SQL "ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;" >/dev/null 2>&1
echo "  전환 후 log_mode = $(mode), open_mode = $(opened)"
echo "  끄는 데 걸린 시간 = ${DOWN_OFF}초 (그동안 데이터베이스가 질의를 받지 않습니다)"
echo

# ── 2) NOARCHIVELOG 에서 시점 복구를 시도한다 ──────────────────────────
echo "## 2) NOARCHIVELOG 상태에서 RMAN 이 무엇을 말하는가"
echo "  이 상태에서는 리두가 덮어써지므로 백업 시점 뒤로는 되돌아갈 재료가 없습니다."
RMAN "RUN { SET UNTIL TIME \"SYSDATE-1/1440\"; RESTORE DATABASE; }" \
  | grep -iE "RMAN-|ORA-" | head -5 | sed 's/^/    /'
echo "  아카이브 로그 자체도 확인합니다:"
SQL "SELECT 'archived_logs=' || COUNT(*) FROM v\$archived_log WHERE first_time > SYSDATE - 1/24;" \
  | tr -d ' \r' | grep -v '^$' | sed 's/^/    /'
echo

# ── 3) 다시 켠다 ────────────────────────────────────────────────────────
echo "## 3) ARCHIVELOG 로 되돌린다"
T2=$(date +%s)
SQL "SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;" | grep -iE "ORA-|altered|Database (closed|dismounted|mounted|opened)" | head -8 | sed 's/^/    /'
T3=$(date +%s)
DOWN_ON=$((T3 - T2))
SQL "ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;" >/dev/null 2>&1
echo "  전환 후 log_mode = $(mode), open_mode = $(opened)"
echo "  켜는 데 걸린 시간 = ${DOWN_ON}초"
echo "  전환 직후 아카이브가 실제로 도는지 확인합니다:"
SQL "ALTER SYSTEM ARCHIVE LOG CURRENT;" >/dev/null 2>&1
SQL "SELECT 'archived_logs=' || COUNT(*) FROM v\$archived_log WHERE first_time > SYSDATE - 1/1440;" \
  | tr -d ' \r' | grep -v '^$' | sed 's/^/    /'
echo

echo "## 정리"
printf "  %-34s %s초\n" "ARCHIVELOG → NOARCHIVELOG" "$DOWN_OFF"
printf "  %-34s %s초\n" "NOARCHIVELOG → ARCHIVELOG" "$DOWN_ON"
echo
echo "  이 랩은 데이터가 1,500행이라 정지 시간이 거의 기동 시간입니다. 운영 규모에서는"
echo "  SHUTDOWN IMMEDIATE 가 열린 트랜잭션의 롤백을 기다리므로 더 길어집니다."
echo "  갈리는 자리는 길이가 아니라 단계입니다. MySQL 의 log-bin 과 PostgreSQL 의"
echo "  archive_mode 는 설정을 바꾸고 재기동 한 번이면 끝나는데, Oracle 은 데이터베이스를"
echo "  mount 상태에 두는 단계가 하나 더 있습니다. 열린 채로는 바꿀 수 없습니다."
echo "  각 방향 1회 실행입니다."
} 2>&1 | tee "$OUT/exp6-oracle-archivelog.txt"
