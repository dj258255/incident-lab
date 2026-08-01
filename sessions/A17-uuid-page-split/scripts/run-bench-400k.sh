#!/usr/bin/env bash
# run-bench.sh 는 행 수를 위치 인자로 받는다. 반복 러너는 환경변수만 넘기므로
# 본문 8절과 같은 40만 행으로 고정해 감싼다.
exec bash "$(dirname "$0")/run-bench.sh" 400000 "$@"
