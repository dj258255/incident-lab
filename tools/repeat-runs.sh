#!/usr/bin/env bash
# 세션 하나를 여러 번 돌려 회차 간 편차를 본다. 세션 공용 래퍼다.
#
# 왜 필요한가.
# 2026-07-30에 완료 세션의 "못 한 것"을 전수 분류하면서, 조건마다 한 번씩만 재고
# 결론을 낸 세션이 열 곳이라는 것이 드러났다. 같은 저장소의 F13은 조건마다 한 번씩
# 잰 값으로 "단일 시퀀서가 1.8~3.8배 느리다"고 적었는데, 51회씩 세 번 다시 재니
# 오히려 빨랐다. F01도 "킬스위치가 막았다"가 "가드 단독으로 0건"으로 뒤집혔다.
# 한 번 재고 낸 결론은 방향까지 틀릴 수 있다.
#
# 왜 가드가 필요한가.
# 처음 만든 세션별 래퍼는 컨테이너 기동 실패를 그냥 지나쳤다. R04를 3회 돌렸더니
# 세 번 다 "완료"로 찍혔는데, 실제로는 compose가 `range of CPUs is from 0.01 to 2.00`
# 으로 거부해 컨테이너가 없었고 모든 docker exec가 실패해 0만 기록됐다.
# 조용히 실패하는 도구가 조용히 틀린 데이터를 만든다. 그래서 기동을 확인하고
# 안 되면 그 자리에서 멈춘다.
#
# 사용법:
#   tools/repeat-runs.sh <세션디렉토리> <컨테이너이름> <회차수> <스크립트...>
# 예:
#   tools/repeat-runs.sh sessions/A02-mdl-storm a02-mysql 3 scripts/mdl.py
set -uo pipefail

SESSION="${1:?세션 디렉토리}"; CONTAINER="${2:?컨테이너 이름}"; N="${3:?회차수}"; shift 3
SCRIPTS=("$@")
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/$SESSION" || exit 1
OUT="results"; mkdir -p "$OUT"

# 이 호스트가 감당할 수 있는 cpus인지 먼저 본다. 넘으면 compose가 컨테이너 생성을
# 거부하는데, 그 실패가 스크립트 안에서는 빈 문자열로만 보여 0이 기록된다.
# nproc은 macOS에 없다. 이 저장소는 12코어 맥과 2코어 리눅스 양쪽에서 쓰이므로
# 둘 다 되게 한다. 값을 못 구하면 가드를 건너뛰지 말고 그 자리에서 멈춘다.
HOST_CPUS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "")
if [ -z "$HOST_CPUS" ]; then
  echo "중단: 호스트 코어 수를 구하지 못했습니다(nproc·sysctl 둘 다 실패)." >&2
  exit 2
fi
NEED=$(grep -hoE "cpus: *[0-9.]+" compose.yml 2>/dev/null | grep -oE "[0-9.]+" | sort -rn | head -1)
if [ -n "${NEED:-}" ] && awk -v a="$NEED" -v b="$HOST_CPUS" 'BEGIN{exit !(a+0>b+0)}'; then
  echo "중단: compose가 cpus=$NEED 를 요구하는데 이 호스트는 ${HOST_CPUS}코어입니다." >&2
  echo "      도커가 컨테이너 생성을 거부하므로 측정이 조용히 0으로 채워집니다." >&2
  echo "      원래 측정은 더 큰 장비에서 나온 값입니다. cpus를 낮춰 돌리면" >&2
  echo "      원 측정과 조건이 달라져 회차 비교가 성립하지 않습니다." >&2
  exit 2
fi

for i in $(seq 1 "$N"); do
  echo "=================== 회차 $i / $N ==================="
  docker compose down -v >/dev/null 2>&1 || true
  # 출력은 파일로만 남기고 판정은 아래 기동 확인으로 한다.
  # 처음에는 `| tee file | grep -q ...` 로 썼는데, grep -q 가 첫 매칭에서 바로
  # 끝나면서 파이프를 닫고 그 SIGPIPE가 compose까지 끊었다. 컨테이너가 안 뜬 것이
  # 아니라 뜨는 중에 죽은 것이라, 원인을 엉뚱한 데서 찾게 만들었다.
  docker compose up -d > "$OUT/run$i-compose.txt" 2>&1 || true

  # 기동 확인. 여기서 못 뜨면 그 자리에서 멈춘다.
  UP=0
  for _ in $(seq 1 60); do
    if docker ps --filter "name=^${CONTAINER}$" --filter status=running -q | grep -q .; then UP=1; break; fi
    sleep 1
  done
  if [ "$UP" -ne 1 ]; then
    echo "중단: 회차 $i 에서 컨테이너 '$CONTAINER' 가 뜨지 않았습니다." >&2
    echo "      results/run$i-compose.txt 를 보세요." >&2
    exit 3
  fi

  # 측정 직전 호스트 상태. 부하가 결과를 흔들 수 있으므로 기록으로 남긴다.
  # F13에서 문서에 적힌 load average 값이 저장소 어디에도 근거가 없던 일이 있었다.
  { echo "[회차 $i 측정 직전]"; uptime
    echo "코어: $HOST_CPUS"; } | tee "$OUT/host-run$i.txt"

  for s in "${SCRIPTS[@]}"; do
    base=$(basename "$s")
    echo "  실행: $s"
    if [[ "$s" == *.py ]]; then
      "$ROOT/../../.venv/bin/python" "$s" > "$OUT/run$i-${base%.py}-stdout.txt" 2>&1 || \
        echo "  경고: $s 가 0이 아닌 코드로 끝났습니다 (run$i-${base%.py}-stdout.txt 확인)"
    else
      bash "$s" > "$OUT/run$i-${base%.sh}-stdout.txt" 2>&1 || \
        echo "  경고: $s 가 0이 아닌 코드로 끝났습니다 (run$i-${base%.sh}-stdout.txt 확인)"
    fi
  done

  # 이 회차 산출물을 회차 라벨로 보관한다. 원본 경로는 다음 회차에 덮인다.
  for f in "$OUT"/*.csv "$OUT"/*.json "$OUT"/*.txt; do
    b=$(basename "$f")
    case "$b" in run*|host-run*) continue;; esac
    [ -f "$f" ] && cp "$f" "$OUT/run$i-$b"
  done
  echo "회차 $i 완료"
done

docker compose down -v >/dev/null 2>&1 || true
echo "전체 완료. 회차별 산출물은 $SESSION/results/run{1..$N}-*"
