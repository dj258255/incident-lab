#!/usr/bin/env bash
# 파티션 수가 단건 조회에 주는 비용이 table_open_cache 에 좌우되는가.
# 본문의 11.2배는 조건마다 1회씩이고, table_open_cache 와 innodb_open_files 조합은
# 재지 않았다고 적었다. 파티션마다 테이블스페이스 파일이 하나씩 붙으니 이 두 설정이
# 배수를 정할 수 있다.
# 캐싱: 조건마다 새 컨테이너. 같은 방식으로 데운 뒤 잰다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/results"; mkdir -p "$OUT"
C=r17-pc; ROWS=${ROWS:-400000}; REPS=${REPS:-3}; PROBE=${PROBE:-2000}

echo "partitions,table_open_cache,rep,ms" > "$OUT/partition-cache.csv"
{
echo "# 파티션 수와 table_open_cache 가 단건 조회에 주는 영향"
echo "# 각 조건 $ROWS 행 · 단건 조회 $PROBE 회 · ${REPS}회 반복 · 조건마다 새 컨테이너"
echo
printf "  %10s %18s %12s %s\n" "파티션" "table_open_cache" "중앙(ms)" "회차"
for PARTS in 1 32 256; do
  for TOC in 400 4000; do
    MS=()
    for rep in $(seq 1 "$REPS"); do
      docker rm -f "$C" >/dev/null 2>&1
      docker run -d --name "$C" -e MYSQL_ROOT_PASSWORD=lab -e MYSQL_DATABASE=lab mysql:8.4.3 \
        --table-open-cache=$TOC --innodb-open-files=$TOC --open-files-limit=20000 >/dev/null
      M(){ docker exec -i "$C" mysql -uroot -plab -N -B lab -e "$1" 2>/dev/null; }
      for _ in $(seq 1 90); do [ "$(M 'SELECT 1')" = "1" ] && break; sleep 2; done
      if [ "$PARTS" = 1 ]; then
        M "CREATE TABLE wl(id BIGINT NOT NULL AUTO_INCREMENT, d INT NOT NULL, v INT, PRIMARY KEY(id,d)) ENGINE=InnoDB;" >/dev/null
      else
        PD=""; for p in $(seq 1 $PARTS); do PD="$PD PARTITION p$p VALUES LESS THAN ($p),"; done
        M "CREATE TABLE wl(id BIGINT NOT NULL AUTO_INCREMENT, d INT NOT NULL, v INT, PRIMARY KEY(id,d)) ENGINE=InnoDB
           PARTITION BY RANGE(d) (${PD%,});" >/dev/null
      fi
      M "SET SESSION cte_max_recursion_depth=$((ROWS+10));
         INSERT INTO wl(d,v) SELECT n % $PARTS, n FROM (
           WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<$ROWS) SELECT n FROM s) q;" >/dev/null
      G=$(M "SELECT COUNT(*) FROM wl")
      [ "${G:-0}" -ne "$ROWS" ] && { echo "  적재 ${G:-0}행(기대 $ROWS), 이 회차 버림"; docker rm -f "$C" >/dev/null; continue; }
      M "ANALYZE TABLE wl; SELECT COUNT(*) FROM wl;" >/dev/null   # 같은 웜업
      # 단건 조회를 한 문장으로 PROBE 회. 파티션 프루닝이 걸리는 형태다.
      t0=$(date +%s%N)
      M "SELECT COUNT(*) FROM (SELECT 1 FROM wl WHERE d = FLOOR(RAND()*$PARTS) AND id > 0 LIMIT $PROBE) x;" >/dev/null
      t1=$(date +%s%N); ms=$(( (t1-t0)/1000000 ))
      MS+=("$ms"); echo "$PARTS,$TOC,$rep,$ms" >> "$OUT/partition-cache.csv"
      docker rm -f "$C" >/dev/null 2>&1
    done
    MED=$(printf '%s\n' "${MS[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
    printf "  %10s %18s %12s %s\n" "$PARTS" "$TOC" "${MED:-?}" "$(IFS=,; echo "${MS[*]}")"
  done
done
echo
echo "  같은 파티션 수에서 table_open_cache 가 배수를 바꾸면 그 설정이 원인의 일부입니다."
} 2>&1 | tee "$OUT/exp4-partition-cache.txt"
