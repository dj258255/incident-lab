#!/usr/bin/env bash
# 스위트를 돌리고 요약까지 다시 만든다.
# run-suite.sh 만 반복하면 raw/ 만 갱신되고 summary.csv 와 medians.json 은 그대로다.
# 그러면 반복 비교가 "회차마다 내용이 같은 파일"로 요약을 걸러 버려 아무것도 못 본다.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
bash "$D/run-suite.sh" "$@" || exit $?
[ -x "$D/summarize.sh" ] || chmod +x "$D/summarize.sh" 2>/dev/null
bash "$D/summarize.sh" "$@"
