#!/usr/bin/env python3
"""PK 점조회 부하를 걸고 버퍼 풀 지표와 지연을 함께 남긴다.

부하 워커를 스레드가 아니라 프로세스로 띄운다. 스레드로 하면 응답이 도착한 뒤 GIL을 얻을
때까지의 대기가 측정 지연에 섞인다. 버퍼 풀이 커져 조회가 빨라질수록 그 오염이 상대적으로
커지므로, 정작 보고 싶은 구간에서 곡선이 뭉개진다.

히트율은 information_schema의 HIT_RATE로 읽지 않고 누적 카운터의 차이로 계산한다.
INNODB_BUFFER_POOL_STATS.HIT_RATE와 SHOW ENGINE INNODB STATUS의 초당 평균값은 직전 출력
이후 경과 시간을 기준으로 하는 값이라, 조건별로 출력 타이밍이 어긋나면 비교가 왜곡된다.
Innodb_buffer_pool_read_requests와 Innodb_buffer_pool_reads는 기동 이후 단조 증가하는
누적값이므로, 측정 구간의 시작과 끝에서 한 번씩 읽어 그 차이만 쓰면 구간이 정확히 맞는다.

워밍업 구간을 따로 두고 그 뒤부터 잰다. 콜드 상태의 첫 몇 초는 어떤 풀 크기에서도 전부 miss라
그대로 섞으면 큰 풀이 손해를 본다.

  사용법: workload.py --dist uniform --out /results/sweep-uniform-1G.json
"""
import argparse
import json
import multiprocessing as mp
import os
import random
import statistics
import threading
import time

import pymysql

p = argparse.ArgumentParser()
p.add_argument("--dist", choices=["uniform", "hot"], default="uniform")
# 2코어 호스트라 2로 고정한다. scripts/00-calib-*.json이 근거다. 1에서 2로 갈 때만
# 처리량이 늘고(3,530 -> 3,864 q/s) 4, 8로 늘리면 처리량은 오히려 줄면서 p95만 커진다.
# 그 구간에서 재면 버퍼 풀이 아니라 CPU 대기를 재게 된다.
p.add_argument("--procs", type=int, default=2)
p.add_argument("--warmup", type=int, default=30)
p.add_argument("--duration", type=int, default=60)
# 핫셋을 전체의 25%로 잡았다. 데이터가 약 1.4GB이므로 핫 워킹셋은 약 350MB다.
# 스윕 점(128M~2G) 한가운데에 무릎이 오게 하려는 값이다. 10%로 하면 무릎이 첫 구간에
# 붙어 버려서 무릎 앞뒤를 같이 볼 수 없다.
p.add_argument("--hot-frac", type=float, default=0.25)
# 5%는 전체 범위로 흩어 놓는다. 100%를 핫셋에 몰면 워킹셋이 들어간 순간 히트율이 100%로
# 붙어 버려 백분위별 차이가 사라진다. 실제 서비스도 꼬리 트래픽이 있다.
p.add_argument("--hot-prob", type=float, default=0.95)
p.add_argument("--out", required=True)
p.add_argument("--timeline")                            # 1초 버킷 지연 시계열 csv
p.add_argument("--action-at", type=int)                 # 측정 시작 후 N초에 아래 SQL을 실행
p.add_argument("--action-sql")
p.add_argument("--label", default="")
# 콜드에서 출발한다. 아래 COUNT(*)가 임포트 시점에 클러스터드 인덱스를 통째로 훑기 때문에
# 원래는 모든 조건이 풀 스캔 직후 상태에서 워밍업을 시작한다. 큰 풀 조건의 0페이지 miss는
# 그 스캔이 만들어 준 값이다. 이 플래그를 켜면 MIN/MAX 만 읽는다. B-Tree 의 양 끝 리프
# 페이지만 건드리므로 버퍼 풀이 비어 있는 채로 시작한다. 행 수는 통계에서 근사치를 읽는다.
p.add_argument("--cold", action="store_true")
# 읽기 사이에 쓰기를 섞는다. 읽기 전용이면 축소할 때 플러시할 더티 페이지가 없어
# 실험 2의 축소 시간이 하한이 된다. 0이면 안 섞는다.
p.add_argument("--write-ratio", type=float, default=0.0)
args = p.parse_args()

HOST = os.environ.get("MYSQL_HOST", "127.0.0.1")
PORT = int(os.environ.get("MYSQL_PORT", 3306))


def connect():
    return pymysql.connect(host=HOST, port=PORT, user="root", password="lab",
                           database="lab", autocommit=True)


# 조회 대상 id 범위는 테이블에서 직접 읽는다. 벌크 적재가 AUTO_INCREMENT를 블록 단위로
# 잡아 쓰기 때문에 id에 구멍이 생긴다(700만 행에 최대 id는 741만). 구멍에 걸린 조회는 행을
# 못 찾고 돌아오지만 B-Tree를 타고 리프 페이지를 읽는 것은 같으므로 버퍼 풀 관점에서는
# 차이가 없다. 범위를 700만으로 잘라 쓰면 뒤쪽 40만 행이 영영 조회되지 않아 워킹셋 계산이 틀어진다.
_c = connect()
_cur = _c.cursor()
if args.cold:
    # MIN/MAX 는 PK 의 첫 리프와 끝 리프만 읽는다. 행 수는 통계의 근사치를 쓴다.
    # 정확한 행 수가 필요한 자리가 아니고, 정확히 세려면 전체를 훑어야 하므로
    # 콜드라는 조건 자체가 깨진다.
    _cur.execute("SELECT MIN(id), MAX(id) FROM orders")
    ID_MIN, ID_MAX = _cur.fetchone()
    _cur.execute("SELECT TABLE_ROWS FROM information_schema.TABLES "
                 "WHERE TABLE_SCHEMA='lab' AND TABLE_NAME='orders'")
    ROW_COUNT = _cur.fetchone()[0]
else:
    _cur.execute("SELECT MIN(id), MAX(id), COUNT(*) FROM orders")
    ID_MIN, ID_MAX, ROW_COUNT = _cur.fetchone()
_c.close()
HOT_MAX = ID_MIN + max(1, int((ID_MAX - ID_MIN) * args.hot_frac))


def worker(seed, t_measure_start, t_end, q):
    """측정 창 안의 (경과초, 지연ms)만 모아 부모에게 넘긴다."""
    rnd = random.Random(seed)
    conn = connect()
    cur = conn.cursor()
    local = []
    while True:
        now = time.time()
        if now >= t_end:
            break
        if args.dist == "hot" and rnd.random() < args.hot_prob:
            pk = rnd.randint(ID_MIN, HOT_MAX)
        else:
            pk = rnd.randint(ID_MIN, ID_MAX)
        t0 = time.perf_counter()
        if args.write_ratio > 0 and rnd.random() < args.write_ratio:
            # 같은 행을 갱신한다. 페이지를 더티로 만드는 것이 목적이라 값은 중요하지 않다.
            cur.execute("UPDATE orders SET amount = amount + 1 WHERE id = %s", (pk,))
        else:
            cur.execute("SELECT id, user_id, status, amount FROM orders WHERE id = %s", (pk,))
            cur.fetchall()
        el = (time.perf_counter() - t0) * 1000
        if now >= t_measure_start:
            local.append((round(now - t_measure_start, 3), round(el, 4)))
    conn.close()
    q.put(local)


def counters(cur):
    # read_ahead 두 개를 같이 읽는다. O_DIRECT 조건에서 블록 I/O 가 InnoDB 가 센 읽기의
    # 2.0배로 나온 것을 리드어헤드로 의심했는데, 의심만 적고 확인하지 않았다.
    # 리드어헤드가 원인이면 Innodb_buffer_pool_read_ahead 가 0 이 아니어야 한다.
    cur.execute("""SHOW GLOBAL STATUS WHERE Variable_name IN
                   ('Innodb_buffer_pool_read_requests','Innodb_buffer_pool_reads',
                    'Innodb_data_read','Innodb_buffer_pool_pages_data',
                    'Innodb_buffer_pool_pages_total','Innodb_buffer_pool_wait_free',
                    'Innodb_buffer_pool_read_ahead','Innodb_buffer_pool_read_ahead_evicted',
                    'Innodb_pages_read','Innodb_buffer_pool_pages_dirty')""")
    return {k: int(v) for k, v in cur.fetchall()}


def pct(xs, q):
    if not xs:
        return None
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * q))]


def main():
    admin = connect()
    acur = admin.cursor()
    acur.execute("SELECT @@innodb_buffer_pool_size, @@innodb_buffer_pool_chunk_size, "
                 "@@innodb_buffer_pool_instances, @@innodb_flush_method, @@version")
    bp_size, chunk, instances, flush_method, version = acur.fetchone()
    print(f"[{args.label or args.dist}] 버퍼 풀 {bp_size/1024/1024:.0f}MB "
          f"(chunk {chunk/1024/1024:.0f}M x instances {instances}), flush {flush_method}, "
          f"MySQL {version}", flush=True)
    print(f"  조회 범위 id {ID_MIN:,}~{ID_MAX:,} ({ROW_COUNT:,}행)"
          + (f", 핫셋 id {ID_MIN:,}~{HOT_MAX:,} 확률 {args.hot_prob}" if args.dist == "hot" else ""),
          flush=True)

    t_measure_start = time.time() + args.warmup
    t_end = t_measure_start + args.duration
    q = mp.Queue()
    procs = [mp.Process(target=worker, args=(1000 + i, t_measure_start, t_end, q))
             for i in range(args.procs)]
    for pr in procs:
        pr.start()

    print(f"  워밍업 {args.warmup}초", flush=True)
    time.sleep(max(0, t_measure_start - time.time()))
    before = counters(acur)

    action = None
    if args.action_at is not None and args.action_sql:
        action = {"sql": args.action_sql}

        def fire():
            time.sleep(max(0, t_measure_start + args.action_at - time.time()))
            c = connect()
            cc = c.cursor()
            s = time.perf_counter()
            stmt_start_s = time.time() - t_measure_start   # 측정 시작 기준 경과초
            print(f"  실행: {args.action_sql}", flush=True)
            try:
                cc.execute(args.action_sql)
            except Exception as ex:
                # 실패를 스레드 안에서 삼키면 리사이즈 없이 잰 값이 리사이즈 결과로 저장된다.
                # 실제로 numfmt 가 없는 호스트에서 SQL 이 빈 값으로 나가 에러 1064 가 났고,
                # 그대로 진행돼 결과 파일만 정상으로 보였다. 결과에 남겨 fail-closed 로 만든다.
                action.update({"error": f"{type(ex).__name__}: {ex}"})
                print(f"  실행 실패: {ex}", flush=True)
                c.close()
                return
            e = time.perf_counter()
            # SET GLOBAL은 즉시 돌아오고 리사이즈는 백그라운드로 진행된다. 진행 상황은
            # Innodb_buffer_pool_resize_status에 문자열로 실린다.
            #
            # 이 값은 리사이즈를 한 번도 안 했으면 빈 문자열이다. 그래서 "비었으면 끝"으로
            # 판정하면 아직 시작도 안 한 시점에 완료로 오인한다. 한 번이라도 진행 문자열을
            # 본 뒤에야 완료 판정을 하고, 끝까지 아무 문자열도 안 뜨면 GRACE초 기다렸다 접는다.
            GRACE = 5.0
            seen_activity = False
            status, trail = "", []
            while time.perf_counter() - s < 180:
                cc.execute("SHOW STATUS LIKE 'Innodb_buffer_pool_resize_status'")
                r = cc.fetchone()
                status = r[1] if r else ""
                if status and (not trail or trail[-1][1] != status):
                    trail.append((round(time.perf_counter() - s, 2), status))
                if status:
                    seen_activity = True
                    if "completed" in status.lower():
                        break
                elif not seen_activity and time.perf_counter() - s > GRACE:
                    break
                time.sleep(0.1)
            done = time.perf_counter()
            cc.execute("SELECT @@innodb_buffer_pool_size")
            final_size = cc.fetchone()[0]
            c.close()
            action.update({"stmt_start_s": round(stmt_start_s, 2),
                           "stmt_ms": round((e - s) * 1000, 1),
                           "settle_s": round(done - s, 2), "final_status": status,
                           "status_trail": trail,
                           "final_pool_mb": final_size // 1024 // 1024,
                           "saw_status": seen_activity})
            print(f"  문장 반환 {(e-s)*1000:.0f}ms, 상태 안정까지 {done-s:.1f}초, "
                  f"최종 풀 {final_size//1024//1024}MB", flush=True)
            for t, st in trail:
                print(f"    +{t:.2f}초  {st}", flush=True)
        threading.Thread(target=fire, daemon=True).start()

    time.sleep(max(0, t_end - time.time()))
    after = counters(acur)

    samples = []
    for _ in procs:
        samples.extend(q.get())
    for pr in procs:
        pr.join(timeout=15)

    lat = [ms for _, ms in samples]
    req = after["Innodb_buffer_pool_read_requests"] - before["Innodb_buffer_pool_read_requests"]
    rd = after["Innodb_buffer_pool_reads"] - before["Innodb_buffer_pool_reads"]
    bytes_read = after["Innodb_data_read"] - before["Innodb_data_read"]

    out = {
        "label": args.label or f"{args.dist}-{bp_size//1024//1024}M",
        "dist": args.dist,
        "buffer_pool_mb": bp_size // 1024 // 1024,
        "chunk_mb": chunk // 1024 // 1024,
        "instances": instances,
        "flush_method": flush_method,
        "mysql_version": version,
        "procs": args.procs,
        "hot_frac": args.hot_frac,
        "hot_prob": args.hot_prob,
        "id_min": ID_MIN,
        "id_max": ID_MAX,
        "row_count": ROW_COUNT,
        "hot_max_id": HOT_MAX,
        "warmup_s": args.warmup,
        "duration_s": args.duration,
        "queries": len(lat),
        "qps": round(len(lat) / args.duration, 1),
        "p50_ms": round(pct(lat, 0.50), 3) if lat else None,
        "p95_ms": round(pct(lat, 0.95), 3) if lat else None,
        "p99_ms": round(pct(lat, 0.99), 3) if lat else None,
        "max_ms": round(max(lat), 3) if lat else None,
        "mean_ms": round(statistics.fmean(lat), 3) if lat else None,
        "read_requests": req,
        "disk_reads": rd,
        "hit_rate_pct": round((1 - rd / req) * 100, 4) if req else None,
        "data_read_mb": round(bytes_read / 1024 / 1024, 1),
        "pages_data": after["Innodb_buffer_pool_pages_data"],
        "pages_total": after["Innodb_buffer_pool_pages_total"],
        "pages_dirty": after["Innodb_buffer_pool_pages_dirty"],
        # 리드어헤드가 실제로 돌았는지. O_DIRECT 조건의 블록 I/O 격차를 이것으로 가른다.
        "read_ahead": after["Innodb_buffer_pool_read_ahead"] - before["Innodb_buffer_pool_read_ahead"],
        "read_ahead_evicted": (after["Innodb_buffer_pool_read_ahead_evicted"]
                               - before["Innodb_buffer_pool_read_ahead_evicted"]),
        # InnoDB 가 센 페이지 읽기 총량. disk_reads 와 갈리면 리드어헤드 몫이다.
        "pages_read": after["Innodb_pages_read"] - before["Innodb_pages_read"],
        "cold_start": bool(args.cold),
        "write_ratio": args.write_ratio,
    }
    if action:
        action["at_s"] = args.action_at
        out["action"] = action

    with open(args.out, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)

    if args.timeline:
        buckets = {}
        for sec, ms in samples:
            buckets.setdefault(int(sec), []).append(ms)
        with open(args.timeline, "w") as f:
            f.write("sec,count,p50_ms,p95_ms,p99_ms,max_ms\n")
            for sec in sorted(buckets):
                v = buckets[sec]
                f.write(f"{sec},{len(v)},{pct(v,0.5):.3f},{pct(v,0.95):.3f},"
                        f"{pct(v,0.99):.3f},{max(v):.3f}\n")

    print(f"  {out['qps']:,} q/s  p50 {out['p50_ms']}ms  p95 {out['p95_ms']}ms  "
          f"p99 {out['p99_ms']}ms  히트율 {out['hit_rate_pct']}%  "
          f"디스크 읽기 {out['disk_reads']:,}페이지 / {out['data_read_mb']}MB", flush=True)
    admin.close()


if __name__ == "__main__":
    main()
