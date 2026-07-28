#!/usr/bin/env bash
# 앱을 빌드한다. 측정 중에 다시 빌드하면 변형마다 다른 바이너리를 재게 되므로 하지 않는다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if pgrep -f "sponsor-api.jar" >/dev/null; then
  echo "측정이 도는 중이다. 끝난 뒤에 빌드하라." >&2
  exit 1
fi

GRADLE="${GRADLE:-gradle}"
command -v "$GRADLE" >/dev/null || { echo "gradle이 없다. brew install gradle" >&2; exit 1; }

cd "$ROOT/app"
"$GRADLE" bootJar -q --console=plain
ls -l "$ROOT/app/build/libs/sponsor-api.jar"
