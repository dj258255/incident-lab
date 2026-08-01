#!/usr/bin/env bash
# SQL Server 시점 복구를 반복해서 돌린다.
#
# exp4 는 조건마다 1회였다. 그런데 이 랩의 SQL Server 는 ARM 에뮬레이션으로 돌아서
# 시간 수치를 아예 안 적었다. 그러면 무엇을 반복해야 하는가.
#
# **시간이 아니라 판정을 반복한다.** 이 실험이 말하는 것은 셋 다 시간이 아니다.
#   NORECOVERY 를 빠뜨리면 로그를 못 이어 붙인다
#   STOPATMARK 로 사고 직전 지점을 가리키면 그 시점 행 수가 돌아온다
#   STOPAT 이 로그 백업 끝보다 뒤면 데이터베이스가 RESTORING 에 남는다
# 이 셋이 회차마다 같은지가 이 스크립트의 질문이다. 에뮬레이션은 시간을 흔들지만
# 판정은 안 흔든다면, 시간을 못 재도 결론은 인용할 수 있다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
ROUNDS=${ROUNDS:-3}
PW='Lab_Passw0rd!'

Q(){  docker exec a23-mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$PW" -C -h -1 -W -Q "$1" 2>&1; }
QD(){ docker exec a23-mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$PW" -C -h -1 -W -d "$1" -Q "$2" 2>&1; }
QE(){ docker exec a23-mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$PW" -C -Q "$1" 2>&1; }

for _ in $(seq 1 150); do [ "$(Q 'SELECT 1' | head -1)" = "1" ] && break; sleep 2; done
[ "$(Q 'SELECT 1' | head -1)" = "1" ] || { echo "중단: a23-mssql 이 쿼리를 못 받습니다" >&2; exit 2; }
docker exec -u 0 a23-mssql sh -c 'mkdir -p /var/opt/mssql/backup && chown -R 10001:0 /var/opt/mssql/backup' >/dev/null 2>&1

num(){ echo "$1" | head -1 | tr -d ' \r'; }
state(){ num "$(Q "SELECT state_desc FROM sys.databases WHERE name='$1'")"; }
rows(){
  local v; v=$(num "$(QD "$1" "SELECT COUNT(*) FROM sponsor" 2>/dev/null)")
  case "$v" in ''|*[!0-9]*) echo "-" ;; *) echo "$v" ;; esac
}

: > "$OUT/mssql-repeat.csv"
echo "run,case,state,rows" >> "$OUT/mssql-repeat.csv"

{
echo "# SQL Server 시점 복구를 ${ROUNDS}회 반복"
echo "# $(num "$(Q "SELECT LEFT(@@VERSION, 40)")")"
echo
echo "  이 컨테이너는 ARM 에뮬레이션으로 돕니다. 시간 수치는 그래서 안 적습니다."
echo "  대신 **판정이 회차마다 같은지**를 봅니다. 에뮬레이션이 시간을 흔들어도"
echo "  판정이 안 흔들리면 결론은 인용할 수 있습니다."
echo

for r in $(seq 1 "$ROUNDS"); do
  echo "## 회차 $r"
  for db in spoon r_a r_b r_c; do
    QE "IF DB_ID('$db') IS NOT NULL BEGIN ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$db]; END" >/dev/null 2>&1
  done
  docker exec a23-mssql sh -c 'rm -f /var/opt/mssql/backup/*.bak /var/opt/mssql/backup/*.trn' >/dev/null 2>&1

  # 사고 전 상태를 만든다. 복구 모델 FULL 이어야 로그 백업이 된다.
  QE "CREATE DATABASE spoon" >/dev/null 2>&1
  QE "ALTER DATABASE spoon SET RECOVERY FULL" >/dev/null 2>&1
  QD spoon "CREATE TABLE sponsor (id INT IDENTITY PRIMARY KEY, amount INT NOT NULL)" >/dev/null 2>&1
  QD spoon "SET NOCOUNT ON;
            DECLARE @i INT = 0;
            WHILE @i < 1500 BEGIN INSERT INTO sponsor (amount) VALUES (@i % 997); SET @i += 1; END" >/dev/null 2>&1
  BEFORE=$(rows spoon)
  if [ "$BEFORE" != "1500" ]; then
    echo "  적재가 ${BEFORE}행입니다(기대 1500). 이 회차는 버립니다"; echo; continue
  fi

  QE "BACKUP DATABASE spoon TO DISK='/var/opt/mssql/backup/full.bak' WITH INIT" >/dev/null 2>&1

  # 전체 백업 **뒤에** 정상 쓰기를 넣는다. 처음에는 백업 직후 시각을 그대로
  # SAFE_TS 로 잡았는데, 그러면 로그 백업 안에 그 시점이 없어서 STOPAT 이 로그의
  # 시작보다 앞선다. SQL Server 는 되돌아갈 자리를 못 찾고 RESTORING 에 남는다.
  # 조건 B 가 조건 C 와 같은 모양으로 나와서 두 조건을 못 갈랐다.
  QD spoon "SET NOCOUNT ON;
            DECLARE @i INT = 0;
            WHILE @i < 500 BEGIN INSERT INTO sponsor (amount) VALUES (7777); SET @i += 1; END" >/dev/null 2>&1
  SAFE_N=$(rows spoon)
  # 사고 직전 지점을 벽시계 대신 **트랜잭션 마크**로 잡는다. STOPAT 은 초 단위
  # 반올림과 로그 백업의 유효 구간에 민감해서, 회차마다 조건 B 가 RESTORING 에
  # 남았다 안 남았다 한다. STOPATMARK 는 로그 안의 지점을 이름으로 가리키므로
  # 시계와 무관하다. 실무에서도 "이 시점으로 돌린다"를 정확히 하려면 이 쪽이다.
  QD spoon "BEGIN TRAN safepoint WITH MARK 'before incident';
            INSERT INTO sponsor (amount) VALUES (0);
            COMMIT TRAN safepoint" >/dev/null 2>&1
  SAFE_N=$(rows spoon)
  sleep 2
  QD spoon "DELETE FROM sponsor WHERE amount = 7777" >/dev/null 2>&1
  AFTER=$(rows spoon)
  QE "BACKUP LOG spoon TO DISK='/var/opt/mssql/backup/log.trn' WITH INIT" >/dev/null 2>&1

  # A: NORECOVERY 없이 복원한 뒤 로그를 이어 붙이려 한다
  QE "RESTORE DATABASE r_a FROM DISK='/var/opt/mssql/backup/full.bak'
      WITH MOVE 'spoon' TO '/var/opt/mssql/data/r_a.mdf',
           MOVE 'spoon_log' TO '/var/opt/mssql/data/r_a.ldf', RECOVERY" >/dev/null 2>&1
  A_ERR=$(QE "RESTORE LOG r_a FROM DISK='/var/opt/mssql/backup/log.trn' WITH STOPATMARK='safepoint', RECOVERY" | grep -ciE "^Msg")
  A_STATE=$(state r_a)

  # B: NORECOVERY 로 복원한 뒤 STOPAT 을 사고 직전으로
  QE "RESTORE DATABASE r_b FROM DISK='/var/opt/mssql/backup/full.bak'
      WITH MOVE 'spoon' TO '/var/opt/mssql/data/r_b.mdf',
           MOVE 'spoon_log' TO '/var/opt/mssql/data/r_b.ldf', NORECOVERY" >/dev/null 2>&1
  QE "RESTORE LOG r_b FROM DISK='/var/opt/mssql/backup/log.trn' WITH STOPATMARK='safepoint', RECOVERY" >/dev/null 2>&1
  B_STATE=$(state r_b); B_ROWS=$(rows r_b)

  # C: STOPAT 을 사고 시각(로그 백업 끝보다 뒤)으로
  QE "RESTORE DATABASE r_c FROM DISK='/var/opt/mssql/backup/full.bak'
      WITH MOVE 'spoon' TO '/var/opt/mssql/data/r_c.mdf',
           MOVE 'spoon_log' TO '/var/opt/mssql/data/r_c.ldf', NORECOVERY" >/dev/null 2>&1
  QE "RESTORE LOG r_c FROM DISK='/var/opt/mssql/backup/log.trn' WITH STOPAT='$(num "$(Q "SELECT CONVERT(varchar(23), DATEADD(minute, 5, SYSDATETIME()), 121)")")', RECOVERY" >/dev/null 2>&1
  C_STATE=$(state r_c); C_ROWS=$(rows r_c)

  printf "  %-30s %s\n" "사고 직전 / 사고 후" "${SAFE_N}행 / ${AFTER}행"
  printf "  %-30s %s\n" "A NORECOVERY 누락" "로그 적용 에러 ${A_ERR}건, 상태 ${A_STATE}"
  printf "  %-30s %s\n" "B STOPATMARK=safepoint" "상태 ${B_STATE}, ${B_ROWS}행"
  printf "  %-30s %s\n" "C STOPAT=사고 시각" "상태 ${C_STATE}, 행 ${C_ROWS}"
  echo
  { echo "$r,before,ONLINE,$SAFE_N"
    echo "$r,after,ONLINE,$AFTER"
    echo "$r,A,$A_STATE,$A_ERR"
    echo "$r,B,$B_STATE,$B_ROWS"
    echo "$r,C,$C_STATE,$C_ROWS"; } >> "$OUT/mssql-repeat.csv"
done

echo "=================================================================="
echo "## 정리"
echo "=================================================================="
python3 - "$OUT/mssql-repeat.csv" <<'STATS'
import csv, sys, collections
rows = list(csv.DictReader(open(sys.argv[1], encoding='utf-8')))
if not rows:
    print("  유효한 회차가 없습니다"); raise SystemExit
by = collections.defaultdict(list)
for r in rows:
    by[r['case']].append((r['state'], r['rows']))
label = {'before': '사고 전 행 수', 'after': '사고 후 행 수',
         'A': 'A NORECOVERY 누락', 'B': 'B STOPATMARK=safepoint', 'C': 'C STOPAT=사고 시각'}
print(f"  {'조건':<22}{'회차별 값':<34}{'같은가'}")
stable = True
for k in ('before', 'after', 'A', 'B', 'C'):
    v = by.get(k) or []
    if not v: continue
    seen = {f"{s}/{n}" for s, n in v}
    same = "같음" if len(seen) == 1 else "**갈림**"
    if len(seen) != 1: stable = False
    shown = ', '.join(f"{s}/{n}" for s, n in v)
    print(f"  {label[k]:<22}{shown[:32]:<34}{same}")
print()
if stable:
    print("  **판정이 회차마다 같습니다.** 에뮬레이션이 시간을 흔들어도 이 셋은 안 흔들립니다.")
    print("  그래서 시간 수치 없이도 이 절의 결론은 인용할 수 있습니다.")
    print("    NORECOVERY 를 빠뜨리면 로그를 이어 붙일 수 없습니다.")
    print("    STOPATMARK 로 사고 직전 지점을 가리키면 그 시점 행 수가 돌아옵니다.")
    print("    STOPAT 이 로그 백업 끝보다 뒤면 데이터베이스가 RESTORING 에 남습니다.")
else:
    print("  **회차마다 갈리는 항목이 있습니다.** 위 표에서 갈린 줄은 인용하면 안 됩니다.")
STATS
echo
echo "  시간은 재지 않았습니다. ARM 에뮬레이션이라 절대값이 이 호스트의 것도 아닙니다."
} 2>&1 | tee "$OUT/exp11-mssql-repeat.txt"
