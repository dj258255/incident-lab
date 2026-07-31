#!/usr/bin/env bash
# 남은 실험을 순서대로 돌린다. 중간에 끊겨도 다시 부르면 이어서 간다.
#
# 2026-07-31 에 큐를 /tmp 에 두고 돌리다가 호스트가 재부팅되면서 스크립트와 로그가
# 통째로 사라졌다. 그래서 이 파일은 저장소 안에 두고, 진행 상태도 저장소 안에 남긴다.
#
#   실행:   tools/run-pending.sh            남은 것만 돌린다
#           tools/run-pending.sh --list     무엇이 남았는지만 본다
#           tools/run-pending.sh --redo A19 그 단계를 다시 돌린다
#
# 단계 하나가 끝나면 state 디렉터리에 done 파일을 남긴다. 다음 실행은 그 파일이 있는
# 단계를 건너뛴다. 실패한 단계는 done 을 안 남기므로 다음 실행에서 다시 시도한다.
#
# Docker VM 이 7.7GB 뿐이라 단계마다 앞의 컨테이너를 내리고 시작한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/.run-state"
LOGS="$ROOT/.run-state/logs"
mkdir -p "$STATE" "$LOGS"
VENV="$ROOT/.venv/bin/python"
PY(){ if [ -x "$VENV" ]; then "$VENV" "$@"; else python3 "$@"; fi; }

log(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGS/run.log"; }

# 단계 정의. 이름과 세션 디렉터리와 실행할 명령.
# 이름은 done 파일 이름이 되므로 바꾸지 않는다.
steps=(
  "R02|R02-failover-dns-cache|compose|bash scripts/exp-permanent-and-readonly.sh"
  "B31|B31-threadlocal-classloader-leak|none|bash scripts/exp-tomcat-and-oomkill.sh"
  "R14|R14-charset-timezone|compose|bash scripts/exp-write-and-jdbc.sh"
  "R12|R12-perf-insights-clone|compose|PYRUN scripts/exp-lock-alternatives.py --out results/lock-alternatives.json"
  "B52extra|B52-jpa-list-api|compose|bash scripts/exp-insert-extra.sh"
  "R01|R01-replica-promotion-loss|compose|bash scripts/exp-after-commit-load.sh"
  "R13|R13-slotted-counter|compose-repl|bash scripts/exp-uniform-and-repeat.sh"
  "A23logical|A23-backup-pitr|compose-mysql-restore|bash scripts/exp7-logical-vs-physical.sh"
  "F03|F03-market-open-connection-storm|none|bash scripts/exp-pool-sweep.sh"
  "R03|R03-reader-endpoint-skew|compose|bash scripts/exp-repeat-load.sh"
  "A23oracle|A23-backup-pitr|compose-oracle|bash scripts/exp6-oracle-archivelog.sh"
  "A18|A18-uber-write-amplification|none|bash scripts/exp2-waldump.sh"
  "A22|A22-index-not-used|compose|PYRUN scripts/exp-convert-side.py --out results/convert-side.json"
  "F02|F02-samsung-ghost-shares|compose-db|bash scripts/run-designs.sh"
  "A06|A06-gap-lock-deadlock|compose|PYRUN scripts/exp-extra.py --out results/extra.json"
  "A19|A19-subtransaction-slru|none|bash scripts/exp-version-and-under64.sh"
  "F01|F01-hanmac-divide-by-zero|f01spring|F01SPRING"
  "R16|R16-batch-cache-pollution|compose|R16SEED"
  "A09|A09-planner-stats-flip|compose|bash scripts/exp-probability-autoanalyze.sh"
  "R17mdl|R17-timeseries-partition|compose|bash scripts/exp-mdl-repeat-and-optimize.sh"
  "A17cs|A17-uuid-page-split|compose-mysql|PYRUN scripts/exp-charset-and-secondary.py --out results/charset-and-secondary.json"
  "A01size|A01-int-pk-exhaustion|compose-mysql|bash scripts/exp6-size-bytes.sh"
  "F15slow|F15-websocket-slow-consumer|none|bash scripts/exp-slow-count-sweep.sh"
  "F02conc|F02-samsung-ghost-shares|compose-db|bash scripts/exp-concurrency-sweep.sh"
  "A22or|A22-index-not-used|compose|PYRUN scripts/exp-or-and-index-merge.py --out results/or-and-index-merge.json"
  "R14jdbc|R14-charset-timezone|compose|bash scripts/exp-jdbc-roundtrip.sh"
  "F07cap|F07-nasdaq-ipo-livelock|none|bash scripts/run-cap-sweep.sh"
  "R04phys|R04-replication-slot-wal|compose|bash scripts/exp5-physical-slot.sh"
  "A23rto|A23-backup-pitr|compose-a23|bash scripts/exp8-mysql-repeat.sh"
  "A02ddl|A02-mdl-storm|compose|bash scripts/exp-ddl-kinds.sh"
  "A08extra|A08-buffer-pool-sizing|none|bash scripts/run-extra.sh"
  "A14subtx|A14-xid-wraparound|compose|bash scripts/exp-subtx-burn.sh"
)

if [ "${1:-}" = "--list" ]; then
  printf "%-12s %s\n" "단계" "상태"
  for s in "${steps[@]}"; do
    name="${s%%|*}"
    [ -f "$STATE/$name.done" ] && st="완료" || st="남음"
    printf "%-12s %s\n" "$name" "$st"
  done
  exit 0
fi

if [ "${1:-}" = "--redo" ] && [ -n "${2:-}" ]; then
  rm -f "$STATE/$2.done"
  log "$2 의 완료 표시를 지웠습니다. 다음 실행에서 다시 돕니다."
fi

# 모든 랩 컨테이너를 내린다. 7.7GB 안에서 한 번에 하나만 돌리기 위해서다.
# lakehouse 처럼 이 랩과 무관한 것은 건드리지 않는다.
teardown(){
  docker ps -q --filter "name=^/a[0-9]" --filter "name=^/r[0-9]" --filter "name=^/b[0-9]" \
             --filter "name=^/lab-" --filter "name=^/f0" 2>/dev/null | xargs -r docker rm -f -v >/dev/null 2>&1 || true
  # -v 를 빠뜨리면 익명 볼륨이 남는다. 이 러너는 단계마다 컨테이너를 새로 띄우므로
  # 열아홉 단계를 돌리는 동안 볼륨이 계속 쌓인다. 실제로 258GB 가 쌓여 디스크가 99% 로
  # 차고 git 인덱스 쓰기가 타임아웃됐다. 붙어 있지 않은 볼륨도 함께 정리한다.
  docker volume prune -f >/dev/null 2>&1 || true
}

bring_up(){ # $1=세션경로 $2=방식
  case "$2" in
    compose)                (cd "$1" && docker compose up -d >/dev/null 2>&1) ;;
    compose-db)             (cd "$1" && docker compose up -d db >/dev/null 2>&1) ;;
    compose-mysql)          (cd "$1" && docker compose up -d mysql >/dev/null 2>&1) ;;
    compose-mysql-restore)  (cd "$1" && docker compose up -d mysql restore >/dev/null 2>&1) ;;
    # mysqlbinlog 가 mysql 이미지에 없어 tools 컨테이너가 함께 있어야 한다.
    compose-a23)            (cd "$1" && docker compose up -d mysql restore tools >/dev/null 2>&1) ;;
    compose-oracle)         (cd "$1" && docker compose --profile oracle up -d oracle >/dev/null 2>&1) ;;
    # 복제본이 repl 프로파일 뒤에 있어 기본 up 으로는 안 뜬다. 그러면 복제 대조가
    # 헤더만 찍고 데이터 행이 하나도 없는 표를 남긴다. 실제로 그렇게 났다.
    compose-repl)           (cd "$1" && docker compose --profile repl up -d >/dev/null 2>&1) ;;
    f01spring)              : ;;
    none)                   : ;;
  esac
}

for s in "${steps[@]}"; do
  IFS='|' read -r name dir mode cmd <<< "$s"
  [ -f "$STATE/$name.done" ] && continue
  sess="$ROOT/sessions/$dir"
  [ -d "$sess" ] || { log "$name 건너뜀(세션 없음: $dir)"; continue; }

  log "$name 시작"
  teardown
  bring_up "$sess" "$mode"

  rc=0
  case "$cmd" in
    F01SPRING)
      ( cd "$sess/spring" && mkdir -p ../results \
        && docker compose up --build --abort-on-container-exit ) > "$LOGS/$name.log" 2>&1 || rc=$?
      sed 's/^lab-f01-hanmac-spring  | //' "$LOGS/$name.log" \
        | grep -A400 "== \[Spring\]" > "$sess/results/spring-killswitch.txt" 2>/dev/null || true
      ( cd "$sess/spring" && docker compose down >/dev/null 2>&1 ) || true
      ;;
    R16SEED)
      ( cd "$sess" \
        && for _ in $(seq 1 90); do docker exec r16-mysql mysqladmin ping -h 127.0.0.1 -plab >/dev/null 2>&1 && break; sleep 2; done \
        && PY scripts/seed.py \
        && bash scripts/exp-sustained.sh ) > "$LOGS/$name.log" 2>&1 || rc=$?
      ;;
    PYRUN*)
      ( cd "$sess" && sleep 20 && PY ${cmd#PYRUN } ) > "$LOGS/$name.log" 2>&1 || rc=$?
      ;;
    *)
      ( cd "$sess" && eval "$cmd" ) > "$LOGS/$name.log" 2>&1 || rc=$?
      ;;
  esac

  if [ "$rc" -eq 0 ]; then
    date '+%Y-%m-%d %H:%M:%S' > "$STATE/$name.done"
    log "$name 완료"
  else
    log "$name 실패(종료 코드 $rc). 로그: .run-state/logs/$name.log"
    tail -5 "$LOGS/$name.log" | sed 's/^/    /' | tee -a "$LOGS/run.log"
  fi
done

teardown
log "남은 실험 전부 처리했습니다"
