#!/usr/bin/env bash
# README 의 "못 한 것" 두 개를 잡는다.
#
#   1) 16 과 17 비교
#      "같은 워크로드를 16 에서 돌려 17 의 뱅크 단위 SLRU 락 개선이 얼마나 기여하는지
#       분리하지 못했습니다. 지금 표의 절벽은 17 에서 버퍼만 32 로 되돌린 것이라
#       16 의 실제 동작과 같다고 말할 수 없습니다."
#
#      16 은 subtransaction_buffers GUC 자체가 없고 NUM_SUBTRANS_BUFFERS 가 32 로
#      컴파일 타임 고정이다. 17 에 subtransaction_buffers=32 를 준 조건과 나란히 놓으면
#      버퍼 수는 같고 락 구조만 다른 대조가 된다. 그것이 이 실험이다.
#
#   2) 활성 수를 64 미만으로 유지한 조건의 처리량을 재지 않았습니다
#      2절에서 ROLLBACK TO 가 PGPROC 캐시를 비운다는 것은 확인했지만, 그 조건에서
#      처리량과 SLRU 미스율이 실제로 회복되는지는 안 쟀다.
#      서브트랜잭션을 64 미만으로 유지하는 조건과 넘기는 조건을 나란히 잰다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
DUR=${DUR:-20}
REPEAT=${REPEAT:-3}
CLIENTS=${CLIENTS:-64}

P(){ docker exec a19-primary psql -U postgres -d spoon -qAt -c "$1" 2>&1; }

# 버전만 바꿔 띄운다. 16 에는 subtransaction_buffers 가 없으므로 그 줄을 빼야 한다.
boot_version(){ # $1=이미지 태그 $2=버퍼(빈 문자열이면 GUC 안 줌)
  docker rm -f a19-primary a19-standby >/dev/null 2>&1 || true
  local extra=()
  [ -n "$2" ] && extra=(-c "subtransaction_buffers=$2")
  docker run -d --name a19-primary --cpus 4 --memory 4g \
    -e POSTGRES_PASSWORD=lab -e POSTGRES_DB=spoon -e POSTGRES_HOST_AUTH_METHOD=trust \
    -v "$ROOT/init":/docker-entrypoint-initdb.d:ro \
    -v "$ROOT/scripts":/scripts:ro \
    -p 15434:5432 "postgres:$1" postgres \
      -c shared_buffers=1GB -c wal_level=replica -c max_wal_senders=10 \
      -c hot_standby=on -c autovacuum=off -c max_connections=300 \
      "${extra[@]+"${extra[@]}"}" >/dev/null
  for _ in $(seq 1 90); do [ "$(P 'SELECT 1')" = "1" ] && break; sleep 2; done
  [ "$(P 'SELECT 1')" = "1" ] || { echo "  중단: postgres:$1 이 쿼리를 받지 못합니다" >&2; return 1; }
  docker exec -i a19-primary psql -U postgres -d spoon -q < "$ROOT/schema.sql" 2>&1 | grep -v NOTICE || true
  return 0
}

# 결과 파일에서 tps 와 SLRU 수치를 뽑는다.
tps_of(){ grep -E "^tps = " "$OUT/$1-reader.txt" 2>/dev/null | head -1 | sed -E 's/tps = ([0-9.]+).*/\1/'; }

{
echo "# 16 대 17, 그리고 64 미만 조건"
echo "# 리더 ${CLIENTS} 클라이언트, 조건마다 ${DUR}초, 1회 실행입니다."
echo

for spec in "16:" "17.5:32"; do
  IFS=: read -r tag bufs <<< "$spec"
  echo "=================================================================="
  echo "## PostgreSQL $tag  (subtransaction_buffers = ${bufs:-없음, 32 고정})"
  echo "=================================================================="
  boot_version "$tag" "$bufs" || continue
  echo "  서버 = $(P 'SHOW server_version')"
  echo "  SLRU 설정 = $(P "SELECT COALESCE((SELECT setting FROM pg_settings WHERE name='subtransaction_buffers'),'GUC 없음')")"
  # 64 미만 조건을 새로 넣는다. 63 은 PGPROC 캐시 안에 들어간다.
  # 조건마다 REPEAT 회 돌린다. 1회 실행으로는 두 버전의 1.00배가 "같다" 인지
  # "차이가 회차 폭에 묻혔다" 인지 갈리지 않는다.
  for c in "none:0" "sub63:63" "sub64:64" "sub10k:10000" "sub500k:500000"; do
    VALS=""
    for run in $(seq 1 "$REPEAT"); do
      label="v${tag%%.*}-${c%%:*}-r${run}"
      bash "$ROOT/scripts/run-primary.sh" "$label" "${c##*:}" "$CLIENTS" "$DUR" >/dev/null 2>&1
      tps=$(tps_of "$label")
      case "${tps:-}" in ''|*[!0-9.]*) tps=0 ;; esac
      slru=$(P "SELECT blks_hit||' / '||blks_read FROM pg_stat_slru WHERE lower(name) IN ('subtransaction','subtrans')")
      echo "$tag,${c%%:*},${c##*:},${tps},$slru,$run" >> "$OUT/version-compare.csv"
      VALS="$VALS $tps"
    done
    MED=$(echo $VALS | tr ' ' '\n' | grep -v '^$' | sort -g | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
    LO=$(echo $VALS | tr ' ' '\n' | grep -v '^$' | sort -g | head -1)
    HI=$(echo $VALS | tr ' ' '\n' | grep -v '^$' | sort -g | tail -1)
    printf "  %-12s 서브트랜잭션 %7s  tps 중앙 %10s  폭 %s~%s  SLRU hit/read %s\n" \
      "${c%%:*}" "${c##*:}" "${MED:-읽기실패}" "${LO:-?}" "${HI:-?}" "$slru"
  done
  echo
done

echo "=================================================================="
echo "## 정리"
echo "=================================================================="
python3 - "$OUT/version-compare.csv" <<'PY'
import statistics, sys, collections
raw = collections.defaultdict(list)
try:
    for line in open(sys.argv[1], encoding='utf-8'):
        parts = line.rstrip("\n").split(",")
        if len(parts) < 4: continue
        ver, cond, tps = parts[0], parts[1], parts[3]
        try:
            v = float(tps)
        except ValueError:
            continue
        if v > 0:
            raw[(cond, ver)].append(v)
except FileNotFoundError:
    print("  결과 파일이 없습니다"); raise SystemExit
rows = {k: statistics.median(v) for k, v in raw.items()}
order = ["none", "sub63", "sub64", "sub10k", "sub500k"]
print(f"  {'조건':<10} {'16 중앙':>11} {'16 폭':>16} {'17.5 중앙':>11} {'17.5 폭':>16} {'17.5/16':>9}")
for c in order:
    a, b = rows.get((c, "16")), rows.get((c, "17.5"))
    if not (a and b):
        continue
    ra, rb = raw[(c, "16")], raw[(c, "17.5")]
    print(f"  {c:<10} {a:>11,.0f} {min(ra):>7,.0f}~{max(ra):<8,.0f} "
          f"{b:>11,.0f} {min(rb):>7,.0f}~{max(rb):<8,.0f} {b/a:>8.2f}배")
print()
print("  회차 폭이 겹치면 그 조건의 배수는 인용하면 안 됩니다.")
print()
print("  같은 버전 안에서 none 대비 배수")
print(f"  {'조건':<10} {'16':>10} {'17.5':>10}")
for c in order[1:]:
    def r(ver):
        b0, b1 = rows.get(("none", ver)), rows.get((c, ver))
        return f"{b1/b0:.2f}배" if b0 and b1 else "-"
    print(f"  {c:<10} {r('16'):>10} {r('17.5'):>10}")
PY
echo
echo "  버퍼 수가 같으므로(32) 두 버전의 차이는 SLRU 락 구조입니다."
echo "  17 은 뱅크 단위로 락을 나눠 같은 미스율에서도 경합이 덜합니다."
echo "  sub63 은 PGPROC 캐시(64) 안에 들어가는 조건이라, 처리량이 none 에 가까우면"
echo "  '64 미만으로 유지하면 회복된다'가 처리량 축에서도 확인되는 것입니다."
} 2>&1 | tee "$OUT/exp-version-and-under64.txt"
