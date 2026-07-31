#!/usr/bin/env bash
# README 의 "못 한 것" 두 개를 잡는다.
#
#   1) 보안 관리자가 설치된 경우를 재지 않았습니다
#      그 경우 DNS 캐시의 기본값이 영구(-1)라 앱을 재시작하기 전에는 복구되지 않는다.
#      이 세션의 49.5초보다 훨씬 나쁜 조건인데 재현하지 못했다.
#
#      보안 관리자 자체는 17에서 폐기되고 24에서 제거됐다. 그러나 이 항목이 말하는 것은
#      보안 관리자가 아니라 **그때 적용되던 캐시 정책**이다. sun.net.inetaddr.ttl=-1 이
#      같은 상태를 만든다. 캐시가 영구면 앱이 죽을 때까지 옛 IP 를 붙잡는다.
#
#   2) 읽기 전용 승격 상태를 구분하지 않았습니다
#      read_only 플래그를 함께 찍긴 했지만 스탠바이가 아직 읽기 전용인 구간을
#      따로 만들지는 않았다. 실제 페일오버는 승격이 끝나기 전에 DNS 가 먼저 바뀔 수 있고,
#      그 사이 앱은 "붙기는 하는데 쓰지는 못하는" 상태가 된다.
#      DNS 만 보는 헬스체크가 통과하는 구간이 여기다.
#
# 두 조건 모두 failover.sh 와 같은 타임라인을 쓴다. 다른 것은 JVM 옵션과
# B 의 read_only 처리뿐이다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
RO_WINDOW=${RO_WINDOW:-25}   # B 를 읽기 전용으로 두는 초

# ── 1) 영구 캐시 ────────────────────────────────────────────────────────
echo "=================================================================="
echo "## 1) DNS 캐시가 영구인 경우 (sun.net.inetaddr.ttl=-1)"
echo "=================================================================="
echo "  기본값(-1 은 아님)과 0 은 이미 쟀습니다. 영구 캐시를 추가로 잽니다."
bash "$ROOT/scripts/failover.sh" ttl-forever -Dsun.net.inetaddr.ttl=-1

# ── 2) 읽기 전용 승격 구간 ─────────────────────────────────────────────
echo
echo "=================================================================="
echo "## 2) 승격이 끝나기 전에 DNS 가 먼저 바뀌는 경우"
echo "=================================================================="
echo "  B 를 read_only=ON 으로 두고 페일오버한 뒤, ${RO_WINDOW}초 뒤에 풉니다."
echo "  그동안 앱은 B 에 붙지만 쓰기는 실패합니다."
echo

# B 가 준비될 때까지 기다린 뒤 읽기 전용을 건다. 컨테이너를 막 띄운 직후에는
# SET GLOBAL 이 안 먹고, 그러면 "읽기 전용 구간"이 읽기 전용이 아닌 채로 돈다.
# 앞선 실행에서 페일오버 5.1초 뒤 쓰기가 성공해 창이 성립하지 않았다.
for _ in $(seq 1 60); do
  docker exec r02-db-b mysqladmin ping -uroot -plab >/dev/null 2>&1 && break
  sleep 2
done
docker exec r02-db-b mysql -uroot -plab -e "SET GLOBAL read_only=ON; SET GLOBAL server_id=2;" 2>/dev/null
RO=$(docker exec r02-db-b mysql -uroot -plab -N -B -e "SELECT @@read_only" 2>/dev/null | tr -d ' ')
[ "$RO" = "1" ] || { echo "중단: B 의 read_only 가 안 켜졌습니다(값 ${RO:-없음})" >&2; exit 3; }
echo "  B 의 read_only 확인 = $RO"
# 창이 지나면 읽기 전용을 푸는 백그라운드 작업. 승격이 끝나는 시점을 흉내 낸다.
#
# 시각의 기준이 중요하다. 처음에는 스크립트 시작에서 세었는데, failover.sh 가 앱을
# 띄우는 데 30초 남짓 쓰고 그 뒤에 페일오버를 일으키므로 창이 페일오버보다 먼저
# 닫혔다. 그래서 "읽기 전용 구간"에 실제로는 읽기 전용이 아니었고, 관측된 쓰기 실패
# 네 건은 A 가 죽어서 난 것이었다. failover.sh 가 남기는 타임스탬프 파일을 기다렸다가
# 그 시점부터 센다.
rm -f "$OUT/readonly-window-failover-ts.txt"
(
  for _ in $(seq 1 300); do
    [ -f "$OUT/readonly-window-failover-ts.txt" ] && break
    sleep 1
  done
  sleep "$RO_WINDOW"
  docker exec r02-db-b mysql -uroot -plab -e "SET GLOBAL read_only=OFF;" 2>/dev/null
  echo "[$(date '+%H:%M:%S')] B 의 read_only 를 해제했습니다(페일오버 +${RO_WINDOW}초)"
) &
RELEASER=$!

# failover.sh 는 /probe 만 찍는다. 쓰기 가능 여부를 같이 봐야 하므로
# 여기서는 /probe 와 /write 를 번갈아 찍는 폴러를 따로 돌린다.
# failover.sh 를 그대로 쓰고, 그 옆에서 /write 를 찍는다.
: > "$OUT/readonly-write.jsonl"
(
  for _ in $(seq 1 120); do
    echo "$(date +%s.%N) $(curl -s --max-time 4 http://127.0.0.1:18080/write 2>/dev/null)" \
      >> "$OUT/readonly-write.jsonl"
    sleep 0.5
  done
) &
WPOLL=$!

bash "$ROOT/scripts/failover.sh" readonly-window -Dsun.net.inetaddr.ttl=0
kill $WPOLL 2>/dev/null || true
wait $RELEASER 2>/dev/null || true
docker exec r02-db-b mysql -uroot -plab -e "SET GLOBAL read_only=OFF;" 2>/dev/null

# ── 정리 ────────────────────────────────────────────────────────────────
{
echo
echo "=================================================================="
echo "## 정리"
echo "=================================================================="
python3 - "$OUT" <<'PY'
import json, os, sys, glob

out = sys.argv[1]

def load(path):
    rows = []
    if not os.path.exists(path):
        return rows
    for line in open(path, encoding='utf-8'):
        parts = line.split(' ', 1)
        if len(parts) < 2:
            continue
        try:
            rows.append((float(parts[0]), json.loads(parts[1])))
        except Exception:
            rows.append((float(parts[0]), None))
    return rows

def fo_ts(label):
    p = os.path.join(out, f"{label}-failover-ts.txt")
    return float(open(p).read().strip()) if os.path.exists(p) else None

for label in ("default", "ttl0", "ttl-forever", "readonly-window"):
    rows = load(os.path.join(out, f"{label}.jsonl"))
    t0 = fo_ts(label)
    if not rows or not t0:
        continue
    switch = None
    for ts, d in rows:
        if ts < t0 or not d:
            continue
        if str(d.get("server_id")) == "2":
            switch = ts - t0
            break
    print(f"  {label:<18} B 로 넘어가기까지 "
          + (f"{switch:6.1f}초" if switch is not None else "관측 창 안에 못 넘어감"))

# 읽기 전용 구간
w = load(os.path.join(out, "readonly-write.jsonl"))
t0 = fo_ts("readonly-window")
if w and t0:
    ok = [ts - t0 for ts, d in w if ts >= t0 and d and d.get("write") == "OK"]
    err = [ts - t0 for ts, d in w if ts >= t0 and d and str(d.get("write", "")).startswith("ERR")]
    print()
    print(f"  읽기 전용 구간: 쓰기 실패 {len(err)}회, 성공 {len(ok)}회")
    if err:
        print(f"    첫 실패 +{min(err):.1f}초, 마지막 실패 +{max(err):.1f}초")
    if ok:
        print(f"    첫 성공  +{min(ok):.1f}초")
    print()
    print("  DNS 가 B 를 가리키고 앱이 B 에 붙은 뒤에도 쓰기는 한동안 실패합니다.")
    print("  DNS 해석이나 커넥션 성립만 보는 헬스체크는 이 구간을 통과시킵니다.")
    print("  쓰기 가능 여부(@@read_only)까지 봐야 실제 복구 시점이 나옵니다.")
PY
echo
echo "  각 조건 1회 실행입니다."
} 2>&1 | tee "$OUT/exp-permanent-and-readonly.txt"
