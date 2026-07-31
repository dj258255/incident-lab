#!/usr/bin/env bash
# 측정 환경을 남긴다. 수치는 조건과 함께 적어야 의미가 있다.
#
#   사용법: tools/capture-env.sh [출력파일]
#           기본값은 표준출력이다.
#
# 일곱 편에 "호스트 사양을 기록하지 않았습니다"가 남아 있어 만들었다.
# 그동안 각 세션이 제각기 nproc 과 free 를 쓰고 있었는데 둘 다 GNU coreutils·procps
# 명령이라 macOS 에는 없다. 없는 명령은 빈 문자열을 내고, 그러면 "호스트 CPU:  코어"
# 같은 줄이 남는다. 실패한 줄이 성공한 줄과 같은 모양이라 눈에 안 띈다.
# 여기서는 양쪽을 다 시도하고, 못 얻으면 못 얻었다고 적는다.
#
# 컨테이너로 재는 랩이라 호스트만으로는 부족하다. Docker Desktop 은 리눅스 VM 을 두고
# 그 안에서 컨테이너가 돌기 때문에, 컨테이너가 실제로 쓸 수 있는 CPU 와 메모리는
# 호스트가 아니라 그 VM 이 정한다. 둘 다 남긴다.
set -uo pipefail
OUT="${1:-/dev/stdout}"

n(){ printf '%s' "${1:-확인 못 함}"; }

host_cpu(){
  if command -v nproc >/dev/null 2>&1; then nproc
  elif command -v sysctl >/dev/null 2>&1; then sysctl -n hw.ncpu 2>/dev/null
  fi
}
host_mem_gb(){
  if command -v free >/dev/null 2>&1; then free -g | awk '/^Mem:/{print $2}'
  elif command -v sysctl >/dev/null 2>&1; then
    python3 -c "print(round($(sysctl -n hw.memsize 2>/dev/null || echo 0)/1073741824))"
  fi
}
host_model(){
  if command -v sysctl >/dev/null 2>&1; then sysctl -n machdep.cpu.brand_string 2>/dev/null
  elif [ -r /proc/cpuinfo ]; then awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo
  fi
}
disk_kind(){
  # 저장 장치 종류. macOS 는 diskutil, 리눅스는 rotational 플래그로 본다.
  if command -v diskutil >/dev/null 2>&1; then
    diskutil info / 2>/dev/null \
      | awk -F': *' '/Solid State|Protocol/{gsub(/^ +/,"",$1); printf "%s %s  ", $1, $2}'
  elif [ -r /sys/block/sda/queue/rotational ]; then
    [ "$(cat /sys/block/sda/queue/rotational)" = "0" ] && echo "회전 없음(SSD/NVMe)" || echo "회전(HDD)"
  fi
}

{
  echo "## 측정 환경"
  echo
  echo "### 호스트"
  echo "  OS          $(uname -sr) $(uname -m)"
  [ "$(uname -s)" = "Darwin" ] && echo "  macOS       $(sw_vers -productVersion 2>/dev/null)"
  echo "  CPU         $(n "$(host_model)")"
  echo "  코어        $(n "$(host_cpu)")"
  echo "  메모리      $(n "$(host_mem_gb)")GB"
  echo "  저장 장치   $(n "$(disk_kind)")"
  echo
  echo "### 컨테이너 런타임"
  echo "  $(docker --version 2>/dev/null || echo 'docker 없음')"
  echo "  $(docker compose version 2>/dev/null | head -1)"
  # 컨테이너가 실제로 쓸 수 있는 자원은 호스트가 아니라 이 VM 이 정한다.
  # 랩 수치를 다른 장비와 견줄 때 봐야 하는 값은 이쪽이다.
  VM_CPU=$(docker info --format '{{.NCPU}}' 2>/dev/null)
  VM_MEM=$(docker info --format '{{.MemTotal}}' 2>/dev/null)
  echo "  런타임 VM   $(n "$VM_CPU")코어, $(python3 -c "print(f'{${VM_MEM:-0}/1073741824:.1f}')" 2>/dev/null)GB"
  echo "  스토리지    $(docker info --format '{{.Driver}}' 2>/dev/null)"
  echo
  echo "### 이 시점에 떠 있던 다른 컨테이너"
  # 같은 VM 에서 다른 것이 돌고 있으면 지연 수치가 그만큼 흔들린다.
  # 없으면 없다고 적어 두는 편이 나중에 값을 읽을 때 도움이 된다.
  OTHERS=$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null)
  if [ -n "$OTHERS" ]; then echo "$OTHERS" | sed 's/^/  /'; else echo "  없음"; fi
  echo
  echo "### 기록 시각"
  echo "  $(date '+%Y-%m-%d %H:%M:%S %Z')"
} > "$OUT"
[ "$OUT" != "/dev/stdout" ] && cat "$OUT"
exit 0
