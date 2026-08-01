#!/usr/bin/env bash
# results/raw/ 의 회차별 원문에서 한 줄 요약을 뽑아 results/summary.csv 로 모은다.
# 서버 CSV(초 단위 계측)와 클라이언트 txt의 SUMMARY 줄을 합친다.
set -euo pipefail
cd "$(dirname "$0")/.."

out=results/summary.csv
{
  echo "mode,run,seconds,published,publish_per_s,heap_peak_mb,heap_end_mb,slow_queue_peak_mb,gc_ms,broadcast_blocked_ms,closed_sessions,oom,recv_total,lat_p50_ms,lat_p95_ms,lat_p99_ms,lat_max_ms,worst_client_p95_ms,last_seq_min,slow_closed_at_s"
  for f in results/raw/server-*.csv; do
    base="$(basename "$f" .csv)"
    label="${base#server-}"
    mode="${label%-r*}"
    run="${label##*-r}"
    client="results/raw/client-${label}.txt"
    [ -f "$client" ] || continue

    read -r secs published pps heappeak heapend slowpeak gcms blocked closed oom <<EOF
$(awk -F, '
  /^#/ || /^t_s/ {next}
  {
    secs=$1; published=$4;
    if ($2+0 > heappeak) heappeak=$2+0;
    heapend=$2+0;
    if ($8+0 > slowpeak) slowpeak=$8+0;
    gcms=$14; blocked=$15; closed=$12; oom=$16;
  }
  END {
    pps = (secs>0) ? published/secs : 0;
    printf "%d %d %.0f %.1f %.1f %.2f %d %d %d %d\n", secs, published, pps, heappeak, heapend, slowpeak, gcms, blocked, closed, oom;
  }' "$f")
EOF

    # 클라이언트 SUMMARY 줄에서 key=value 를 뽑는다.
    val() { grep -o "$1=[^ ]*" "$client" | tail -1 | cut -d= -f2; }
    echo "$mode,$run,$secs,$published,$pps,$heappeak,$heapend,$slowpeak,$gcms,$blocked,$closed,$oom,$(val recv_total),$(val lat_p50_ms),$(val lat_p95_ms),$(val lat_p99_ms),$(val lat_max_ms),$(val worst_client_p95_ms),$(val last_seq_min),$(val slow_closed_at_s)"
  done
} > "$out"

column -s, -t "$out"
echo
echo "저장: $out"
