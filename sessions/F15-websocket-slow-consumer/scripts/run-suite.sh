#!/usr/bin/env bash
# F15 측정 묶음. 모드 하나를 RUNS회 반복하며 회차마다 앱을 새로 띄운다(힙 초기화).
#
#   scripts/run-suite.sh                       # 전체 모드 3회씩
#   MODES="unbounded" RUNS=1 scripts/run-suite.sh
#
# 산출물
#   results/raw/server-<mode>-r<run>.csv   초 단위 서버 계측(힙·발행률·큐 깊이)
#   results/raw/client-<mode>-r<run>.txt   정상/느린 구독자 측정
#   results/raw/serverlog-<mode>-r<run>.txt 앱 로그 원문
set -euo pipefail
cd "$(dirname "$0")/.."

MODES=${MODES:-"baseline direct direct-stalled unbounded bounded conflate terminate terminate-tight combo combo-stalled decorator"}
RUNS=${RUNS:-3}
NORMAL=${NORMAL:-5}
TICK_RATE=${TICK_RATE:-3000}
HEAP=${HEAP:-128}
SLOW_BPS=${SLOW_BPS:-32768}

export HOST_UID="$(id -u)"
export HOST_GID="$(id -g)"
export HEAP
export STREAM_TICK_RATE="$TICK_RATE"

mkdir -p results/raw

seconds_for() {
  case "$1" in
    unbounded)              echo "${OOM_SECONDS:-110}" ;;
    direct|direct-stalled)  echo "${BUGGY_SECONDS:-45}" ;;
    *)                      echo "${FIX_SECONDS:-45}" ;;
  esac
}

for mode in $MODES; do
  slow=1
  bps="$SLOW_BPS"
  export STREAM_BLOCKING_SEND_TIMEOUT_MS=0
  export STREAM_BUFFER_LIMIT_BYTES=1048576
  export STREAM_OVER_LIMIT_SECONDS=3
  case "$mode" in
    baseline)
      # 대조군: 같은 direct 코드에 느린 구독자만 없다.
      export STREAM_MODE=direct
      slow=0
      ;;
    direct-stalled)
      # 완전 정지 클라이언트. 한 바이트도 읽지 않는다.
      export STREAM_MODE=direct
      bps=0
      ;;
    terminate-tight)
      # 순간값 한 번으로 끊는 설정. 정상 사용자를 끊는 위험을 재기 위한 것이다.
      export STREAM_MODE=terminate
      export STREAM_BUFFER_LIMIT_BYTES=524288
      export STREAM_OVER_LIMIT_SECONDS=1
      ;;
    combo-stalled)
      # conflation + 절단을 완전 정지 클라이언트에 건다.
      export STREAM_MODE=combo
      bps=0
      ;;
    decorator|decorator-single)
      # Spring 데코레이터에 넘길 한도. 직접 구현과 같은 512KB로 둔다.
      export STREAM_MODE="$mode"
      export STREAM_BUFFER_LIMIT_BYTES=524288
      ;;
    *)
      export STREAM_MODE="$mode"
      ;;
  esac
  export STREAM_EXPECT_CLIENTS=$((NORMAL + slow))
  secs="$(seconds_for "$mode")"

  for run in $(seq 1 "$RUNS"); do
    label="${mode}-r${run}"
    echo "=== ${label} (${secs}s, 정상 ${NORMAL} + 느린 1, ${TICK_RATE} ticks/s, -Xmx${HEAP}m) ==="
    export SAMPLE_NAME="server-${label}"
    export STREAM_LABEL="$label"

    docker compose up -d --force-recreate app >/dev/null
    for _ in $(seq 1 60); do
      if docker compose logs app 2>/dev/null | grep -q "Started StreamApp"; then break; fi
      sleep 1
    done

    docker run --rm --network f15_default \
      -u "$(id -u):$(id -g)" \
      -v "$PWD/scripts/client":/client:ro \
      -v "$PWD/results/raw":/results \
      -w /tmp \
      eclipse-temurin:21-jdk-alpine \
      java -Xmx640m \
        -Durl=ws://app:8080/stream \
        -Dnormal="$NORMAL" -Dslow="$slow" -Dseconds="$secs" -DslowBytesPerSec="$bps" \
        -Dmode="$mode" -Drun="$run" \
        -Dout="/results/client-${label}.txt" \
        /client/Client.java 2>&1 | tail -n 40

    docker compose logs --no-log-prefix app > "results/raw/serverlog-${label}.txt" 2>&1 || true
    docker compose down >/dev/null 2>&1 || true
    sleep 2
  done
done

echo "=== 정리 ==="
docker compose down --remove-orphans >/dev/null 2>&1 || true
docker ps --filter "name=lab-f15" --format '{{.Names}}'
echo "완료. results/raw/ 를 보라."
