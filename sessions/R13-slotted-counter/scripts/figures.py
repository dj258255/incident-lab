#!/usr/bin/env python3
"""문서에 넣을 증거 이미지를 결과 파일에서 만든다.

손으로 만든 이미지는 다시 만들 수 없고, 다시 만들 수 없는 이미지는 증거가 아니다.
그래서 여기서 만드는 카드는 전부 results/ 아래 실측 파일만 읽는다.
측정 데이터가 바뀌면 이 스크립트를 다시 돌려 이미지도 같이 갱신한다.

  사용법: python3 scripts/figures.py [시나리오]
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from termshot import render  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def k6(scenario, label):
    with open(f"{ROOT}/results/{scenario}/{label}.k6.json") as f:
        return json.load(f)["metrics"]


def verify(scenario, label):
    with open(f"{ROOT}/results/{scenario}/{label}.verify.json") as f:
        return json.load(f)


def pretty(obj, keys):
    """/verify 응답에서 볼 키만 골라 JSON 모양으로 편다."""
    lines = ["{"]
    for i, k in enumerate(keys):
        v = obj[k]
        v = f'"{v}"' if isinstance(v, str) else ("true" if v is True else "false" if v is False else f"{v:,}")
        lines.append(f'  "{k}": {v}' + ("," if i < len(keys) - 1 else ""))
    lines.append("}")
    return "\n".join(lines)


def app_log_errors(scenario, label, pattern):
    """앱 로그에서 예외 줄을 전부 뽑고 몇 번 났는지 센다. 자르는 건 호출자가 정한다."""
    path = f"{ROOT}/results/{scenario}/{label}.app.log"
    if not os.path.exists(path):
        return [], 0
    hits = [l.rstrip() for l in open(path, errors="ignore") if re.search(pattern, l)]
    return hits, len(hits)


def fig_lost(scenario):
    """실패율 0%인데 후원이 사라진 화면. 이 세션에서 가장 중요한 증거다."""
    m, v = k6(scenario, "jpa-naive-r1"), verify(scenario, "jpa-naive-r1")
    body = (
        "$ k6 run scripts/load.js        # jpa-naive, VU 100, 60초\n"
        f"    http_req_failed................: {m['http_req_failed']['value']*100:.2f}%"
        f"  {m['http_req_failed']['passes']:,.0f} out of {m['http_reqs']['count']:,.0f}\n"
        f"    http_reqs......................: {m['http_reqs']['count']:,.0f}"
        f"  {m['http_reqs']['rate']:,.1f}/s\n"
        "\n$ curl -s localhost:8080/verify\n"
        + pretty(v, ["mode", "ledger_count", "counter_count", "lost_count", "lost_amount", "match"])
    )
    out = f"{ROOT}/results/fig-lost.png"
    render(out, "실패율 0%, 그런데 후원은 사라졌다", body,
           ["0.00%", "lost_count", "lost_amount", "false"])
    return out


def fig_retry(scenario):
    """정확하게 고쳤더니 되감기가 폭증한 화면."""
    m, v = k6(scenario, "jpa-optimistic-r1"), verify(scenario, "jpa-optimistic-r1")
    d = m["http_req_duration"]
    body = (
        "$ k6 run scripts/load.js        # jpa-optimistic, VU 100, 60초\n"
        f"    http_req_duration..............: med={d['med']:.0f}ms"
        f"  p(95)={d['p(95)']:.0f}ms  p(99)={d['p(99)']:.0f}ms\n"
        f"    http_req_failed................: {m['http_req_failed']['value']*100:.2f}%\n"
        f"    http_reqs......................: {m['http_reqs']['rate']:,.1f}/s\n"
        "\n$ curl -s localhost:8080/verify\n"
        + pretty(v, ["mode", "lost_count", "match", "optimistic_retries", "optimistic_giveups"])
    )
    out = f"{ROOT}/results/fig-retry.png"
    render(out, "정확해졌지만 되감기가 폭증했다", body,
           ["optimistic_retries", "optimistic_giveups", "true"])
    return out


def fig_slot(scenario):
    """슬롯으로 흩은 뒤 화면. 정확하면서 빠른 상태."""
    m, v = k6(scenario, "slot16-r1"), verify(scenario, "slot16-r1")
    d = m["http_req_duration"]
    body = (
        "$ k6 run scripts/load.js        # slot16, VU 100, 60초\n"
        f"    http_req_duration..............: med={d['med']:.1f}ms"
        f"  p(95)={d['p(95)']:.1f}ms  p(99)={d['p(99)']:.1f}ms\n"
        f"    http_req_failed................: {m['http_req_failed']['value']*100:.2f}%\n"
        f"    http_reqs......................: {m['http_reqs']['count']:,.0f}"
        f"  {m['http_reqs']['rate']:,.1f}/s\n"
        "\n$ curl -s localhost:8080/verify\n"
        + pretty(v, ["mode", "slots", "ledger_count", "counter_count", "lost_count", "match"])
    )
    out = f"{ROOT}/results/fig-slot.png"
    render(out, "슬롯 16개로 흩은 뒤", body, ["true", "0.00%"])
    return out


def fig_nopool(scenario):
    """왕복을 줄이는 최적화가 커넥션 고갈로 끝난 화면."""
    label = "redis-pipe-nopool"
    if not os.path.exists(f"{ROOT}/results/{scenario}/{label}.k6.json"):
        return None
    m = k6(scenario, label)
    hits, n = app_log_errors(scenario, label, r"BindException|Can't assign requested address")
    body = (
        "$ SPRING_DATA_REDIS_LETTUCE_POOL_ENABLED=false ./scripts/run.sh redis-pipe 0 zipf\n"
        # k6의 Rate 지표에서 passes는 "조건이 참인 횟수", 즉 실패한 요청 수다.
        f"    http_req_failed................: {m['http_req_failed']['value']*100:.2f}%"
        f"  {m['http_req_failed']['passes']:,.0f} out of {m['http_reqs']['count']:,.0f}\n"
        f"    http_reqs......................: {m['http_reqs']['rate']:,.1f}/s\n"
    )
    if hits:
        # 앱 로그는 수 MB라 저장소에 넣지 않는다(.gitignore의 *.log).
        # 그러면 증거가 사라지므로 해당 줄만 발췌해 따로 남긴다.
        excerpt = f"{ROOT}/results/{scenario}/{label}.errors.txt"
        with open(excerpt, "w") as f:
            f.write(f"# {label}.app.log 에서 발췌. 전체 {n}건.\n")
            f.writelines(h + "\n" for h in hits[:20])
        body += f"\n$ grep -c BindException results/{scenario}/{label}.app.log\n{n}\n"
        for h in hits[:2]:
            body += h[:110] + "\n"
    out = f"{ROOT}/results/fig-nopool.png"
    render(out, "파이프라인을 켰더니 임시 포트가 말랐다", body,
           ["BindException", "Can't assign requested address"])
    return out


def fig_multi(_scenario=None):
    """같은 코드가 인스턴스 수만 바뀌어 틀리기 시작하는 화면."""
    base = f"{ROOT}/results/multi"
    one, two = f"{base}/jvm-lock-x1.verify.json", f"{base}/jvm-lock-x2.verify.json"
    if not (os.path.exists(one) and os.path.exists(two)):
        return None
    v1, v2 = json.load(open(one)), json.load(open(two))
    keys = ["ledger_count", "counter_count", "lost_count", "lost_amount", "match"]
    body = (
        "$ ./scripts/run-multi.sh jvm-lock 0 1     # 인스턴스 1대\n"
        + pretty(v1, keys)
        + "\n\n$ ./scripts/run-multi.sh jvm-lock 0 2     # 같은 코드, 인스턴스 2대\n"
        + pretty(v2, keys)
    )
    out = f"{ROOT}/results/fig-multi.png"
    render(out, "코드는 그대로, 인스턴스만 2대로 늘렸을 때", body,
           ["true", "false", "lost_count", "lost_amount"])
    return out


def fig_recovery(_scenario=None):
    """Redis가 통째로 날아간 뒤 원장에서 카운터를 다시 만드는 화면."""
    base = f"{ROOT}/results/failure"
    bp, ap = f"{base}/redis-kill.before.json", f"{base}/redis-kill.after.json"
    if not (os.path.exists(bp) and os.path.exists(ap)):
        return None
    before, after = json.load(open(bp)), json.load(open(ap))
    rebuild = {}
    rp = f"{base}/redis-kill.rebuild.json"
    if os.path.exists(rp):
        rebuild = json.load(open(rp))
    keys = ["ledger_count", "counter_count", "lost_count", "lost_amount", "match"]
    body = (
        "$ docker kill r13-redis   # 부하 20초 지점에서 강제 종료\n"
        "$ docker start r13-redis  # 35초 지점에서 재기동, 저장 설정이 없어 데이터는 비어 있다\n\n"
        "$ curl -s localhost:8080/verify        # 복구 전\n"
        + pretty(before, keys)
        + "\n\n$ curl -s -X POST localhost:8080/rebuild   # 원장에서 카운터 재구성\n"
    )
    if rebuild:
        body += pretty(rebuild, [k for k in ("rebuilt_table", "elapsed_ms") if k in rebuild])
    body += "\n\n$ curl -s localhost:8080/verify        # 복구 후\n" + pretty(after, keys)
    out = f"{ROOT}/results/fig-recovery.png"
    render(out, "Redis가 비어 버린 뒤 원장에서 카운터를 다시 만든다", body,
           ["true", "false", "lost_count", "lost_amount", "elapsed_ms"])
    return out


if __name__ == "__main__":
    scenario = sys.argv[1] if len(sys.argv) > 1 else "zipf"
    for fn in (fig_lost, fig_retry, fig_slot, fig_nopool, fig_multi, fig_recovery):
        try:
            path = fn(scenario)
            print(("저장: " + path) if path else f"건너뜀: {fn.__name__} (데이터 없음)")
        except (FileNotFoundError, KeyError) as e:
            print(f"건너뜀: {fn.__name__} ({e})")
