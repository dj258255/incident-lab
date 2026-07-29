#!/usr/bin/env python3
"""results/run-1.txt(1회차 원문 출력)에서 results/render.json을 만든다.

그림 안의 수치를 손으로 옮기면 본문을 고칠 때 그림만 옛 값으로 남는다. F13 초판이 그랬다.
그래서 콘솔 카드의 글자와 막대그래프의 값을 전부 실행 원문에서 읽어 쓴다.

사용: python3 scripts/make-render.py   (세션 디렉토리에서 실행)
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SESSION = os.path.dirname(HERE)
RUN = os.path.join(SESSION, "results", "run-1.txt")
OUT = os.path.join(SESSION, "results", "render.json")
PREFIX = "lab-f13-matching  | "


def load_lines():
    if not os.path.exists(RUN):
        sys.exit(f"원문 출력이 없습니다: {RUN}")
    with open(RUN, encoding="utf-8") as f:
        raw = f.read().splitlines()
    return [ln[len(PREFIX):] if ln.startswith(PREFIX) else ln for ln in raw]


def block(lines, header):
    """헤더 줄부터 빈 줄 직전까지를 원문 그대로 잘라 온다."""
    for i, ln in enumerate(lines):
        if ln.startswith(header):
            out = [ln]
            for nxt in lines[i + 1:]:
                if not nxt.strip():
                    break
                out.append(nxt)
            return out
    sys.exit(f"블록을 찾지 못했습니다: {header}")


def split_tag(line):
    """'  C1 기준       84,956건 ...' 를 (조건 태그, 나머지)로 가른다."""
    m = re.match(r"^(  (?:C\d|P\d) \S+\s+)(.*)$", line)
    return (m.group(1), m.group(2)) if m else (None, None)


def main():
    lines = load_lines()
    header = next(ln for ln in lines if ln.startswith("JDK "))
    viol = block(lines, "시간우선 위반 요약")
    thr = block(lines, "처리량 요약")
    share = block(lines, "변수별 몫")

    # 콘솔 카드 1: 시간우선 위반 요약. 위반이 남은 조건은 빨강, 0건인 조건은 초록.
    viol_lines = [viol[0], [[viol[1], "dim"]]]
    rates, elapsed = [], []
    for ln in viol[2:]:
        tag, rest = split_tag(ln)
        if tag is None:
            viol_lines.append(ln)
            continue
        clean = rest.startswith("0건")
        viol_lines.append([[tag, "fg"], [rest, "green" if clean else "red"]])
        rate = float(re.search(r"(\d\.\d{3}) \(", rest).group(1))
        rates.append((tag.strip(), rate, "green" if clean else "red"))

    # 콘솔 카드 2: 처리량 요약과 변수별 몫. 느려진 쪽 배수는 빨강, 빨라진 쪽은 초록.
    thr_lines = [thr[0], [[thr[1], "dim"]]]
    for ln in thr[2:]:
        tag, rest = split_tag(ln)
        if tag is None:
            thr_lines.append(ln)
            continue
        ms = float(rest.split()[0])
        elapsed.append((tag.strip(), ms))
        thr_lines.append(ln)
    thr_lines.append("")
    thr_lines.append(share[0])
    for ln in share[1:]:
        m = re.search(r"(\d+\.\d{2})배$", ln)
        if not m:
            thr_lines.append(ln)
            continue
        cut = ln.rindex(m.group(0))
        thr_lines.append([[ln[:cut], "fg"],
                          [m.group(0), "red" if float(m.group(1)) > 1 else "green"]])

    # 막대그래프의 색은 위반 요약에서 읽은 조건별 판정을 그대로 쓴다.
    verdict = {tag: color for tag, _, color in rates}
    note = ("초록은 시간우선 위반 0건 조건, 빨강은 위반이 남은 조건. "
            "접수 4 + 매칭 1(P1은 3+2, P2는 4+2). "
            f"{header}. 2 vCPU aarch64 Rocky Linux 9.6, 2026-07-29")

    spec = {"images": [
        {"type": "term", "out": "01-buggy-run.png", "font": 22,
         "title": "docker compose up  ·  F13 시간우선 위반 요약 (조건 8개 × 51회, 1회차)",
         "lines": ["$ docker compose up", "", header, ""] + viol_lines},
        {"type": "term", "out": "02-fixed-run.png", "font": 22,
         "title": "docker compose up  ·  F13 처리량과 변수별 몫 (조건 8개 × 51회, 1회차)",
         "lines": ["$ docker compose up", ""] + thr_lines},
        {"type": "bar", "out": "03-violations.png", "w": 1800,
         "title": "체결 1건당 시간우선 위반 중앙값 (같은 가격 매수 20만 건, 51회)",
         "bars": [{"label": t, "value": v, "color": c} for t, v, c in rates],
         "note": note},
        {"type": "bar", "out": "04-elapsed.png", "w": 1800,
         "title": "20만 건 처리 소요 시간 중앙값 (ms, 낮을수록 빠름, 51회)",
         "bars": [{"label": t, "value": v, "color": verdict[t]} for t, v in elapsed],
         "note": note},
    ]}

    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(spec, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"생성: {OUT}  (콘솔 카드 2장, 막대그래프 2장)")
    for t, v, c in rates:
        print(f"  {t}: 체결당 위반 {v} ({c})")


if __name__ == "__main__":
    main()
