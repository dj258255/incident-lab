#!/usr/bin/env python3
"""incident-lab 시각 증거 생성기.

캡처한 콘솔 출력을 '터미널 스크린샷' PNG로, 측정 수치를 막대그래프 PNG로 만든다.
입력은 세션의 results/render.json 하나다. 한글은 NanumGothicCoding(없으면 NanumGothic)으로 렌더한다.

사용:
    python render.py <세션 results 경로>
    # 예: python render.py sessions/F01-hanmac-divide-by-zero/results

render.json 스키마:
    {
      "images": [
        {"type": "term", "out": "01.png", "title": "...", "font": 28, "lines": [ <라인>, ... ]},
        {"type": "bar",  "out": "02.png", "title": "...", "note": "...",
         "bars": [{"label": "...", "value": 10, "color": "red"}, ...]}
      ]
    }

라인은 문자열이거나 [ [조각, 색], [조각, 색], ... ] 형태다. 색 이름은 fg/green/red/dim/yellow.
문자열이 "$"로 시작하면 프롬프트로 보고 초록으로 칠한다.
"""
import glob
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

BG = (24, 26, 33)
TITLEBAR = (58, 62, 74)
FG = (222, 224, 230)
GREEN = (122, 214, 150)
RED = (224, 108, 108)
YELLOW = (226, 192, 104)
DIM = (150, 154, 165)
GRID = (60, 64, 76)

COLORS = {"fg": FG, "green": GREEN, "red": RED, "dim": DIM, "yellow": YELLOW}


def resolve_font():
    p = os.environ.get("FONT_PATH")
    if p and os.path.exists(p):
        return p
    patterns = [
        "/usr/share/fonts/truetype/nanum/NanumGothicCoding*.ttf",
        "/usr/share/fonts/truetype/nanum/NanumGothic*.ttf",
        "/usr/share/fonts/**/*Nanum*.ttf",
        "/usr/share/fonts/**/*CJK*.ttf",
    ]
    for pat in patterns:
        hits = sorted(glob.glob(pat, recursive=True))
        if hits:
            return hits[0]
    raise SystemExit("한글 폰트를 찾지 못했습니다. FONT_PATH를 지정하거나 fonts-nanum을 설치하세요.")


FONT_PATH = resolve_font()
_FONT_CACHE = {}


def font(size):
    if size not in _FONT_CACHE:
        _FONT_CACHE[size] = ImageFont.truetype(FONT_PATH, size)
    return _FONT_CACHE[size]


def norm_line(ln):
    """라인을 [(문자열, 색), ...] 조각 리스트로 정규화한다."""
    if isinstance(ln, list):
        return [(seg[0], COLORS.get(seg[1], FG)) for seg in ln]
    if isinstance(ln, str) and ln.startswith("$"):
        return [(ln, GREEN)]
    return [(ln, FG)]


def line_width(draw, segments, fnt):
    return sum(draw.textlength(seg, font=fnt) for seg, _ in segments) or 1


def render_term(spec, out_path):
    size = spec.get("font", 28)
    fnt = font(size)
    title = spec.get("title", "")
    title_fnt = font(int(size * 0.7))
    pad, titlebar, gap = 30, 58, 12

    probe = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    ascent, descent = fnt.getmetrics()
    line_h = ascent + descent + gap
    lines = [norm_line(ln) for ln in spec["lines"]]

    text_w = max(line_width(probe, segs, fnt) for segs in lines)
    title_w = probe.textlength(title, font=title_fnt)
    W = int(max(text_w, title_w) + pad * 2)
    H = int(titlebar + pad + line_h * len(lines) + pad)

    img = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(img)
    draw.rectangle([0, 0, W, titlebar], fill=TITLEBAR)
    for i, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        cx = pad + i * 26
        draw.ellipse([cx - 8, titlebar // 2 - 8, cx + 8, titlebar // 2 + 8], fill=c)
    if title:
        draw.text(((W - title_w) / 2, (titlebar - int(size * 0.7)) / 2 - 2),
                  title, font=title_fnt, fill=DIM)

    y = titlebar + pad
    for segs in lines:
        x = pad
        for seg, color in segs:
            draw.text((x, y), seg, font=fnt, fill=color)
            x += draw.textlength(seg, font=fnt)
        y += line_h

    img.save(out_path)
    return img.size


def render_bar(spec, out_path):
    W, H = spec.get("w", 940), spec.get("h", 560)
    img = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(img)
    draw.text((44, 30), spec["title"], font=font(30), fill=FG)

    bars = spec["bars"]
    maxv = max([b["value"] for b in bars] + [1])
    top, bottom, left, right = 110, H - 130, 70, W - 44
    plot_h = bottom - top
    slot = (right - left) / len(bars)
    bw = min(180, slot * 0.5)

    # 눈금선
    for k in range(0, 5):
        gy = bottom - plot_h * k / 4
        draw.line([left, gy, right, gy], fill=GRID, width=1)
        draw.text((left - 44, gy - 14), str(round(maxv * k / 4)), font=font(20), fill=DIM)
    draw.line([left, bottom, right, bottom], fill=DIM, width=2)

    val_fnt, lab_fnt = font(38), font(24)
    for i, b in enumerate(bars):
        cx = left + slot * (i + 0.5)
        v = b["value"]
        h = int(plot_h * (v / maxv)) if maxv else 0
        color = COLORS.get(b.get("color", "dim"), DIM)
        x0, x1 = cx - bw / 2, cx + bw / 2
        y0 = bottom - h
        if h > 0:
            draw.rectangle([x0, y0, x1, bottom], fill=color)
        else:
            draw.rectangle([x0, bottom - 4, x1, bottom], fill=color)
            y0 = bottom
        vs = str(v)
        vw = draw.textlength(vs, font=val_fnt)
        draw.text((cx - vw / 2, y0 - 50), vs, font=val_fnt, fill=FG)
        lw = draw.textlength(b["label"], font=lab_fnt)
        draw.text((cx - lw / 2, bottom + 18), b["label"], font=lab_fnt, fill=DIM)

    if spec.get("note"):
        draw.text((44, H - 44), spec["note"], font=font(20), fill=DIM)

    img.save(out_path)
    return img.size


def main():
    if len(sys.argv) < 2:
        raise SystemExit("사용법: python render.py <세션 results 경로>")
    results_dir = sys.argv[1]
    with open(os.path.join(results_dir, "render.json"), encoding="utf-8") as f:
        spec = json.load(f)
    for job in spec["images"]:
        out = os.path.join(results_dir, job["out"])
        if job["type"] == "term":
            size = render_term(job, out)
        elif job["type"] == "bar":
            size = render_bar(job, out)
        else:
            print("알 수 없는 type:", job["type"])
            continue
        print(f"생성: {out}  {size[0]}x{size[1]}")


if __name__ == "__main__":
    main()
