#!/usr/bin/env bash
# 실험 2. 페일오버 — 승격하면 무엇을 잃는가.
#
# 3장(A23)의 MySQL 반동기는 강등된 채 승격해 커밋 334건을 잃었다. 같은 질문을
# SQL Server 로그 전달에 묻는다. 답은 꼬리 로그다. 주가 아직 살아 있으면
# 백업 안 된 마지막 로그(꼬리)를 WITH NORECOVERY 로 뜨고 — 이 순간 주는 쓰기를
# 내려놓는다 — 보조가 그것까지 복원하고 열면 유실 0 이다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
OUT="$ROOT/results"; mkdir -p "$OUT"
exec > >(tee "$OUT/exp2-failover.txt") 2>&1

echo "# 실험 2. 페일오버 — 꼬리 로그가 유실 0 을 정한다"
echo
wait_both || exit 2
PFIN=$(cat "$OUT/primary-final.txt")
echo "전제: 주 ${PFIN}행, 보조는 그보다 뒤처져 있다 (실험 1)"
echo

echo "## 2-1. 꼬리 로그를 WITH NORECOVERY 로 — 주가 역할을 내려놓는다"
QP "BACKUP LOG [$DB] TO DISK='/var/opt/mssql/backup/a29_tail.trn' WITH INIT, NORECOVERY" | grep -E 'processed|BACKUP' | head -2
STATE_P=$(num "$(QP "SET NOCOUNT ON; SELECT state_desc FROM sys.databases WHERE name='$DB'")")
echo "  주의 상태: ${STATE_P}"
W=$(QPD "INSERT INTO ledger (account_id, amount) VALUES (1,1)" | head -1)
echo "  주에 쓰기 시도 → $(echo "$W" | cut -c1-60)..."
echo

echo "## 2-2. 보조: 꼬리까지 복원하고 연다"
ship a29_tail.trn
QS "RESTORE LOG [$DB] FROM DISK='/var/opt/mssql/backup/a29_tail.trn' WITH RECOVERY" | grep -E 'RESTORE|processed' | head -2
STATE_S=$(num "$(QS "SET NOCOUNT ON; SELECT state_desc FROM sys.databases WHERE name='$DB'")")
echo "  보조의 상태: ${STATE_S} — 이제 이쪽이 주다"
echo

echo "## 2-3. 검산 — 유실 0 인가"
SN=$(num "$(QSD "SET NOCOUNT ON; SELECT COUNT(*) FROM ledger")")
LATE=$(num "$(QSD "SET NOCOUNT ON; SELECT COUNT(*) FROM ledger WHERE account_id = 888000")")
echo "  승격된 보조: ${SN}행 (장애 직전 주: ${PFIN}행)"
echo "  백업 안 됐던 마지막 3행: ${LATE} / 3  ← 꼬리 로그가 나른 몫"
W2=$(QSD "SET NOCOUNT ON; INSERT INTO ledger (account_id, amount) VALUES (999000, 1); SELECT COUNT(*) FROM ledger" | head -1)
echo "  승격된 쪽에 쓰기: 성공 ($(num "$W2")행)"
echo
echo "결론: MySQL 반동기는 강등을 모른 채 승격해 334건을 잃었지만(A23·3장),"
echo "로그 전달은 주가 살아 있는 한 꼬리 로그가 유실 0 을 만든다. 꼬리를 못 뜨는"
echo "상황 — 주 디스크가 통째로 죽은 때 — 의 유실 폭이 곧 로그 백업 주기다."
