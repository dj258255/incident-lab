#!/usr/bin/env bash
# A24 공용 헬퍼.
PW='Lab_Passw0rd!'
DB=lostark_log
CT=a24-mssql
SQLCMD=/opt/mssql-tools18/bin/sqlcmd

# 조사 규모. 환경변수로 줄일 수 있게 두되, 줄이면 결과에 그 사실이 남는다.
OPENS=${OPENS:-10000000}      # 상자 개봉 로그 행 수
OTHERS=${OTHERS:-10000000}    # 개봉이 아닌 재화 이동 행 수
ACCOUNTS=${ACCOUNTS:-500000}  # 계정 수
DUPE_OPENS=${DUPE_OPENS:-300} # 이상 지급이 붙은 개봉 수
DUPE_ACCOUNTS=${DUPE_ACCOUNTS:-60}  # 이상 계정 수 (로스트아크 2023 공지의 63계정 규모)
# 정상인데 활동이 많은 계정. 통계적 탐지가 이들을 어뷰저와 가르는지 보려고 둔다.
# 어뷰저는 5회 개봉에 지급 20건(1+3씩), 이들은 20회 개봉에 지급 20건이다.
# 지급 건수와 금액 규모가 겹치므로 합계만 보는 방법으로는 못 가른다.
HEAVY_ACCOUNTS=${HEAVY_ACCOUNTS:-40}
HEAVY_OPENS=${HEAVY_OPENS:-20}

Q(){  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -Q "$1" 2>&1; }
QD(){ docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" -Q "$1" 2>&1; }
# 파일로 심어 실행한다. 긴 SQL 과 SET 옵션이 필요한 질의에 쓴다.
QF(){
  docker exec -i "$CT" sh -c "cat > /tmp/a24q.sql" <<<"$1"
  local n; n=$(docker exec "$CT" sh -c 'wc -l < /tmp/a24q.sql' | tr -d ' \r')
  [ "${n:-0}" -gt 0 ] || { echo "중단: SQL 파일이 비었습니다" >&2; return 2; }
  docker exec "$CT" "$SQLCMD" -S localhost -U sa -P "$PW" -C -h -1 -W -d "$DB" -i /tmp/a24q.sql 2>&1
}

num(){ echo "$1" | head -1 | tr -d ' \r'; }

# 실행하고 오류가 있으면 멈춘다.
# QD "..." >/dev/null 로 던지면 sqlcmd 의 Msg 가 그대로 버려져서, SQL 이 한 줄도
# 안 들어갔는데 스크립트는 다음 단계로 넘어간다. 실제로 그렇게 데이터셋이 조용히
# 비어 있는 채로 끝까지 돌았다. 쓰기 질의는 전부 이 함수로 던진다.
QDX(){
  local out; out=$(QD "$1")
  if echo "$out" | grep -qE '^(Msg|메시지) [0-9]+'; then
    echo "중단: SQL 오류" >&2
    echo "$out" | grep -E '^(Msg|메시지)|^[A-Za-z가-힣].*(수준|Level)' | head -4 >&2
    return 2
  fi
  return 0
}

wait_ready(){
  local i
  for i in $(seq 1 150); do
    [ "$(num "$(Q "SELECT 'RE'+'ADY'")")" = "READY" ] && return 0
    sleep 2
  done
  echo "중단: $CT 가 쿼리를 못 받습니다" >&2; return 2
}

# 논리 읽기를 뽑는다. 시간이 아니라 이 값이 이 세션의 지표다.
# STATISTICS IO 출력은 표가 여럿이면 줄이 여럿이므로 전부 더한다.
logical_reads(){   # $2 에 아무 값이나 주면 SET 옵션 없이 잰다(함정 조건용)
  local sql=$1 raw=${2:-}
  local out setopt
  # 필터드 인덱스는 조회 시점의 SET 옵션이 안 맞으면 조용히 안 쓰인다.
  # 에러가 아니라 그냥 안 쓰이므로 논리 읽기만 보면 인덱스가 없는 것과 구분이 안 된다.
  if [ -n "$raw" ]; then setopt=""; else setopt="SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;"; fi
  out=$(QF "SET NOCOUNT ON;
${setopt}
SET STATISTICS IO ON;
${sql}
SET STATISTICS IO OFF;")
  # "논리적 읽기 수" 는 한글 로케일, 영문은 "logical reads". 둘 다 받는다.
  echo "$out" | grep -oE '(logical reads|논리적 읽기 수) [0-9]+' | grep -oE '[0-9]+' \
    | awk '{s+=$1} END {print s+0}'
}

# 실행 계획에서 특정 문자열이 나오는지 본다(파티션 제거 확인 등).
plan_has(){
  local sql=$1 pat=$2
  QF "SET NOCOUNT ON;
SET SHOWPLAN_XML ON;
GO
${sql}
GO
SET SHOWPLAN_XML OFF;" | grep -qi "$pat" && echo YES || echo NO
}
