#!/usr/bin/env bash
# README 의 "못 한 것" 세 항목을 한 번에 잡는다.
#
#   1) 조건마다 한 번씩만 돌렸습니다
#      → 같은 조건을 3회 돌려 세대 간 편차를 본다. 이 세션은 표본이 원래 얇다.
#        3초 간격 40회는 maxLifetime 30초 기준으로 풀 세대 다섯 개일 뿐이라,
#        조건당 관측이 사실상 다섯 개다. 회차를 늘리면 열다섯 개가 된다.
#
#   2) 쿼리 수를 인스턴스별로 세지도 않았습니다
#      → 커넥션이 쏠렸을 때 그 인스턴스가 실제로 더 많은 쿼리를 받는지 확인한다.
#        앱을 고치지 않고 리플리카 쪽 Com_select 증분으로 센다.
#        커넥션 분포와 쿼리 분포가 같은 값으로 나와야 "커넥션 단위 분산"이라는
#        이 세션의 주장이 쿼리 축에서도 성립한다.
#
#   3) maxLifetime 흔들림을 분리 측정하지 않았습니다
#      → DNS 캐시를 끈 상태(sun.net.inetaddr.ttl=0)에서 maxLifetime 만 바꾼다.
#        캐시가 켜져 있으면 재생성 시각이 흩어져도 같은 IP 로 가므로 두 원인이 섞인다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
RUNS=${RUNS:-3}
SAMPLES=${SAMPLES:-40}

for c in r03-db-1 r03-db-2 r03-db-3; do
  for _ in $(seq 1 60); do
    docker exec "$c" mysqladmin ping -h 127.0.0.1 -plab >/dev/null 2>&1 && break
    sleep 2
  done
done
docker exec r03-db-1 mysqladmin ping -h 127.0.0.1 -plab >/dev/null 2>&1 \
  || { echo "중단: r03 리플리카가 뜨지 않았습니다" >&2; exit 2; }

# Com_select 는 세션이 아니라 서버 누적값이다. 증분으로 봐야 한다.
com_select(){ docker exec "$1" mysql -uroot -plab -N -e \
  "SHOW GLOBAL STATUS LIKE 'Com_select'" 2>/dev/null | awk '{print $2}'; }

start_app(){ # $@ = 환경변수
  docker rm -f r03-app >/dev/null 2>&1 || true
  local envs=(); for a in "$@"; do envs+=(-e "$a"); done
  docker run -d --name r03-app --network r03-lab --dns 172.32.0.53 \
    -p 18081:8080 -v "$ROOT/app/build/libs:/app:ro" \
    ${envs[@]+"${envs[@]}"} \
    eclipse-temurin:21-jre java -jar /app/skew.jar >/dev/null
  for _ in $(seq 1 60); do
    curl -sf http://127.0.0.1:18081/one >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "  앱이 뜨지 않았습니다"; docker logs r03-app 2>&1 | tail -8 | sed 's/^/    /'
  return 1
}

# 분포 표본에서 최다 인스턴스 비중만 뽑는다.
share(){ python3 - "$1" <<'PY'
import json, sys, statistics
vals=[]
for line in open(sys.argv[1]):
    parts=line.split(' ',1)
    if len(parts)<2: continue
    try: d=json.loads(parts[1])
    except Exception: continue
    if 'max_share_pct' in d: vals.append(d['max_share_pct'])
if not vals: print("표본없음"); raise SystemExit
vals.sort()
print(f"n={len(vals)} 중앙 {statistics.median(vals):.1f}% 최소 {vals[0]:.1f}% 최대 {vals[-1]:.1f}%")
PY
}

run_case(){ # $1=라벨 $2...=환경변수
  local label="$1"; shift
  echo
  echo "### $label"
  for run in $(seq 1 "$RUNS"); do
    start_app "$@" || return 1
    local f="$OUT/${label}-run${run}.jsonl"
    : > "$f"
    # 쿼리 축을 같이 잰다. 관측 창 시작과 끝의 Com_select 차이.
    local s1 s2 s3 e1 e2 e3
    s1=$(com_select r03-db-1); s2=$(com_select r03-db-2); s3=$(com_select r03-db-3)
    for _ in $(seq 1 "$SAMPLES"); do
      echo "$(date +%s.%N) $(curl -s --max-time 5 http://127.0.0.1:18081/distribution)" >> "$f"
      sleep 3
    done
    e1=$(com_select r03-db-1); e2=$(com_select r03-db-2); e3=$(com_select r03-db-3)
    local d1=$((e1-s1)) d2=$((e2-s2)) d3=$((e3-s3))
    local tot=$((d1+d2+d3)); [ "$tot" -gt 0 ] || tot=1
    printf "  run%d 커넥션 %s\n" "$run" "$(share "$f")"
    printf "       쿼리   db-1 %d(%d%%) db-2 %d(%d%%) db-3 %d(%d%%)\n" \
      "$d1" $((d1*100/tot)) "$d2" $((d2*100/tot)) "$d3" $((d3*100/tot))
    echo "$label,$run,$d1,$d2,$d3" >> "$OUT/query-share.csv"
    docker rm -f r03-app >/dev/null 2>&1 || true
  done
}

{
echo "# 반복 측정, 인스턴스별 쿼리 수, maxLifetime 분리"
echo "# MySQL $(docker exec r03-db-1 mysql -uroot -plab -N -e 'SELECT VERSION()' 2>/dev/null)"
echo "# 조건마다 ${RUNS}회, 회차마다 3초 간격 ${SAMPLES}표본"
: > "$OUT/query-share.csv"
echo "label,run,db1_select,db2_select,db3_select" >> "$OUT/query-share.csv"

# 원래 두 조건을 회차만 늘려 다시 잰다.
run_case short MAXLIFE=30000
run_case long  MAXLIFE=600000

# DNS 캐시를 끄고 maxLifetime 만 바꾼다. 이러면 재생성될 때마다 DNS 를 새로 묻는다.
# 캐시가 켜져 있으면 재생성 시각이 흩어져도 같은 IP 로 가므로 두 원인이 섞인다.
#
# 옵션 이름 주의. networkaddress.cache.ttl 은 java.security 파일이 읽는 **보안 속성**이라
# -D 로 넘기면 안 먹는다. 시스템 속성으로 같은 일을 하는 것은 sun.net.inetaddr.ttl 이다.
# 처음에 앞의 것을 넘겨 돌렸더니 캐시가 그대로 켜진 채로 "캐시 끔" 조건이 됐고,
# 세 회차가 전부 중앙 100% 로 나와 캐시 조건과 구별되지 않았다.
# **에러가 안 나고 조용히 무시되는 쪽이라 결과만 보면 알 수 없다.**
run_case short-nocache MAXLIFE=30000  JAVA_TOOL_OPTIONS=-Dsun.net.inetaddr.ttl=0
run_case long-nocache  MAXLIFE=600000 JAVA_TOOL_OPTIONS=-Dsun.net.inetaddr.ttl=0

# maxLifetime 을 두 값으로만 봤다는 것이 README 에 남아 있었다. 30초와 600초 사이가
# 계단인지 완만한 곡선인지 갈리지 않는다. 캐시를 끈 상태에서 다섯 점을 더 찍는다.
# 캐시가 켜져 있으면 재생성 시각이 흩어져도 같은 IP 로 가므로 이 축이 안 보인다.
for ml in 5000 10000 60000 120000 300000; do
  run_case "ml${ml}" MAXLIFE=$ml JAVA_TOOL_OPTIONS=-Dsun.net.inetaddr.ttl=0
done

echo
echo "## 정리"
column -s, -t "$OUT/query-share.csv" 2>/dev/null || cat "$OUT/query-share.csv"
} 2>&1 | tee "$OUT/exp-repeat-load.txt"
