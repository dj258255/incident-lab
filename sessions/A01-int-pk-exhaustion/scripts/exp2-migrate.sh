#!/usr/bin/env bash
# 실험 2. 쓰기가 계속 들어오는 중에 INT PK를 BIGINT로 바꾼다.
#
# 두 방법을 같은 크기의 테이블에서 비교한다.
#   A. 한 방 ALTER (MODIFY id BIGINT)   : 간단하다. 그동안 쓰기가 어떻게 되는가
#   B. expand-contract 3단계            : 신규 컬럼 추가 → 백필 → 교체
#
# 측정을 설계할 때 잡은 판단 기준은 "그동안 들어온 쓰기가 몇 건 실패했는가"였다.
# 재 보니 양쪽 다 0건이라 이 기준으로는 두 방법이 갈리지 않았다. 갈린 것은 통과 건수와
# 지연이다. 그래서 이 스크립트는 실패 건수만 세지 않고 건별 응답 시간을 CSV로 남기고,
# scripts/report.py가 창 안 초당 통과량과 전환 직전 기준선을 함께 낸다.
# 아래 마지막 say 줄은 측정 전에 세운 이 가설을 그대로 두었다. results/exp2.txt를
# 다시 돌려도 같은 파일이 나오게 하려는 것이고, 왜 틀렸는지는 README 4절에 적었다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/../../.venv/bin/python"
OUT="$ROOT/results"
mkdir -p "$OUT"
M()  { docker exec a01-mysql mysql -uroot -plab spoon "$@" 2>&1 | grep -v "Warning.*password"; }
MQ() { docker exec a01-mysql mysql -uroot -plab spoon -N -B -e "$1" 2>/dev/null; }
say() { echo "$*" | tee -a "$OUT/exp2.txt"; }
: > "$OUT/exp2.txt"

ROWS="${ROWS:-3000000}"

# MySQL 이 쿼리를 받을 때까지 기다린다. 없으면 컨테이너가 뜨자마자 시작한 회차에서
# CREATE TABLE 이 실패하고, 그 뒤 ALTER 가 "Table doesn't exist"로 0.16초에 끝난다.
# 반복 측정 run1 이 실제로 그렇게 나왔다. 실패한 회차가 "아주 빠른 회차"로 보이는 쪽이라
# 표에 그대로 들어가면 결론을 뒤집는다.
wait_ready() {
  for _ in $(seq 1 90); do
    [ "$(MQ 'SELECT 1')" = "1" ] && return 0
    sleep 2
  done
  echo "중단: MySQL 이 쿼리를 받지 못합니다" >&2
  exit 2
}

seed() {
  M -e "DROP TABLE IF EXISTS $1;
        CREATE TABLE $1 (
          id INT AUTO_INCREMENT PRIMARY KEY,
          user_id BIGINT NOT NULL,
          amount INT NOT NULL,
          created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
          KEY idx_user (user_id)
        ) ENGINE=InnoDB;"
  "$PY" - "$1" "$ROWS" <<'PYEOF'
import sys, random, pymysql
tbl, rows = sys.argv[1], int(sys.argv[2])
c = pymysql.connect(host="127.0.0.1", port=13318, user="root", password="lab",
                    database="spoon", autocommit=False)
cur = c.cursor()
B = 5000
for i in range(0, rows, B):
    cur.executemany(f"INSERT INTO {tbl} (user_id, amount) VALUES (%s,%s)",
                    [(random.randint(1, 500000), 1000) for _ in range(min(B, rows - i))])
    if (i // B) % 40 == 0:
        c.commit()
c.commit()
c.close()
PYEOF
}

# PID를 파일로 넘긴다. $(...)로 받으면 그 서브셸의 자식이라 나중에 kill이 닿지 않는다.
writer_start() {
  rm -f "$2"
  "$PY" - "$1" "$2" <<'PYEOF' &
import sys, time, csv, random, signal, pymysql
tbl, out = sys.argv[1], sys.argv[2]
rows = []
stop = {"v": False}
signal.signal(signal.SIGINT, lambda *_: stop.__setitem__("v", True))
c = pymysql.connect(host="127.0.0.1", port=13318, user="root", password="lab",
                    database="spoon", autocommit=True)
cur = c.cursor()
end = time.time() + 400
# 한 줄씩 바로 기록한다. 종료 시점에만 쓰면 프로세스가 강제 종료될 때 전부 잃는다.
f = open(out, "w", newline="", buffering=1)
w = csv.writer(f)
w.writerow(["ts", "ms", "status"])
while not stop["v"] and time.time() < end:
    t0 = time.perf_counter()
    try:
        cur.execute(f"INSERT INTO {tbl} (user_id, amount) VALUES (%s,%s)",
                    (random.randint(1, 500000), 1000))
        w.writerow((f"{time.time():.3f}", f"{(time.perf_counter()-t0)*1000:.2f}", "ok"))
    except pymysql.Error as e:
        w.writerow((f"{time.time():.3f}", f"{(time.perf_counter()-t0)*1000:.2f}", f"err:{e.args[0]}"))
        try:
            c.ping(reconnect=True); cur = c.cursor()
        except Exception:
            time.sleep(0.2)
    f.flush()
    time.sleep(0.01)
f.close()
PYEOF
  echo $! > "$OUT/writer.pid"
}

summarize() {
  "$PY" - "$1" "$2" "$3" <<'PYEOF' | tee -a "$OUT/exp2.txt"
import sys, csv, statistics as st
path, s, e = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
rows = list(csv.DictReader(open(path)))
during = [r for r in rows if s <= float(r["ts"]) <= e]
ok = [float(r["ms"]) for r in during if r["status"] == "ok"]
err = [r for r in during if r["status"] != "ok"]
codes = {}
for r in err:
    codes[r["status"]] = codes.get(r["status"], 0) + 1
p95 = st.quantiles(ok, n=20)[18] if len(ok) >= 20 else (max(ok) if ok else 0)
print(f"  전환 중 쓰기 {len(during):,}건 · 성공 {len(ok):,} · 실패 {len(err):,}")
print(f"  성공한 쓰기의 p95 {p95:.1f}ms · 최대 {max(ok) if ok else 0:.0f}ms")
if codes:
    print(f"  실패 내역 {codes}")
PYEOF
}

say "=============================================================="
say "실험 2. 쓰기가 들어오는 중에 INT를 BIGINT로 바꾼다 (${ROWS}행)"
say "=============================================================="

say ""
say "방법 A. ALTER TABLE ... MODIFY id BIGINT (한 방)"
wait_ready
seed sponsor_a
SEEDED=$(MQ "SELECT COUNT(*) FROM sponsor_a")
[ "${SEEDED:-0}" -ge "$ROWS" ] || { echo "중단: sponsor_a 적재가 ${SEEDED:-0}행에서 멈췄습니다(기대 ${ROWS})" >&2; exit 3; }
say "  적재 $(MQ "SELECT COUNT(*) FROM sponsor_a")행, $(MQ "SELECT ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024) FROM information_schema.TABLES WHERE TABLE_SCHEMA='spoon' AND TABLE_NAME='sponsor_a'")MB"
writer_start sponsor_a "$OUT/writer-a.csv"; WPID=$(cat "$OUT/writer.pid")
sleep 5
S=$(date +%s.%N)
say "  먼저 온라인으로 시도한다"
M -e "ALTER TABLE sponsor_a MODIFY id BIGINT AUTO_INCREMENT, ALGORITHM=INPLACE, LOCK=NONE;" | sed 's/^/    /' | tee -a "$OUT/exp2.txt"
say "  엔진이 거부한다. 타입 변경은 테이블을 다시 만들어야 하므로 COPY만 가능하다."
say "  COPY로 실행한다"
M -e "ALTER TABLE sponsor_a MODIFY id BIGINT AUTO_INCREMENT, ALGORITHM=COPY;" | sed 's/^/    /' | tee -a "$OUT/exp2.txt"
E=$(date +%s.%N)
say "  소요 $(echo "$E - $S" | bc)초"
sleep 3
kill -INT "$WPID" 2>/dev/null || true; sleep 2
summarize "$OUT/writer-a.csv" "$S" "$E"

say ""
say "방법 B. expand-contract 3단계"
seed sponsor_b
say "  적재 $(MQ "SELECT COUNT(*) FROM sponsor_b")행"
writer_start sponsor_b "$OUT/writer-b.csv"; WPID=$(cat "$OUT/writer.pid")
sleep 5
S=$(date +%s.%N)

say ""
say "  1단계 expand: BIGINT 신규 컬럼 추가"
S1=$(date +%s.%N)
M -e "ALTER TABLE sponsor_b ADD COLUMN id_new BIGINT NULL, ALGORITHM=INPLACE, LOCK=NONE;" | sed 's/^/    /' | tee -a "$OUT/exp2.txt"
E1=$(date +%s.%N)
say "    소요 $(echo "$E1 - $S1" | bc)초"

say "  2단계 backfill: 기존 행을 청크로 채운다"
S3=$(date +%s.%N)
CHUNKS=0
while :; do
  N=$(MQ "UPDATE sponsor_b SET id_new = id WHERE id_new IS NULL LIMIT 20000; SELECT ROW_COUNT();" | tail -1)
  CHUNKS=$((CHUNKS+1))
  [ "${N:-0}" -lt 20000 ] && break
done
E3=$(date +%s.%N)
say "    청크 ${CHUNKS}회, 소요 $(echo "$E3 - $S3" | bc)초"
say "    남은 NULL $(MQ "SELECT COUNT(*) FROM sponsor_b WHERE id_new IS NULL")건 (백필 중 들어온 새 행)"

say "  3단계 잔여 백필: 백필 중에 들어온 새 행을 마저 채운다"
S4=$(date +%s.%N)
M -e "UPDATE sponsor_b SET id_new = id WHERE id_new IS NULL;" | sed 's/^/    /' | tee -a "$OUT/exp2.txt"
E4=$(date +%s.%N)
say "    소요 $(echo "$E4 - $S4" | bc)초"
say "    (실제 전환은 여기서 애플리케이션이 두 컬럼을 함께 쓰도록 배포한 뒤"
say "     컬럼명을 교체한다. 이 실험은 DB 쪽 작업만 잰다)"
E=$(date +%s.%N)
say "  전체 소요 $(echo "$E - $S" | bc)초"
sleep 3
kill -INT "$WPID" 2>/dev/null || true; sleep 2
summarize "$OUT/writer-b.csv" "$S" "$E"

say ""
say "판단 기준은 소요 시간이 아니라 전환 중 쓰기 실패 건수다."
