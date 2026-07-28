#!/usr/bin/env python3
"""실제 실행 출력을 터미널 모양 PNG로 렌더한다.

수치를 표로만 옮겨 적으면 독자는 그 표가 실행 결과인지 손으로 쓴 것인지 알 수 없다.
그래서 원문 출력을 그대로 이미지로 남기고, 문서에는 코드 블록과 함께 싣는다.
이미지는 보기용이고 검증용 원문은 results/ 아래 텍스트 파일이다.

  사용법: termshot.py <출력파일.png> <제목> <입력파일> [강조어1 강조어2 ...]
"""
import html
import os
import re
import subprocess
import sys
import tempfile

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


def render(png_path, title, body, highlights):
    esc = html.escape(body)
    for h in highlights:
        esc = re.sub(f"({re.escape(html.escape(h))})", r'<b class="hl">\1</b>', esc)

    cols = max((len(l) for l in body.splitlines()), default=80)
    width = min(max(cols * 8.1 + 64, 720), 1500)
    doc = f"""<!doctype html><meta charset="utf-8">
<style>
  * {{ margin:0; padding:0; box-sizing:border-box; }}
  body {{ background:#0d1117; padding:22px; }}
  .win {{ width:{width:.0f}px; background:#161b22; border:1px solid #30363d;
          border-radius:10px; overflow:hidden; box-shadow:0 8px 28px rgba(0,0,0,.5); }}
  .bar {{ display:flex; align-items:center; gap:8px; padding:10px 14px;
          background:#21262d; border-bottom:1px solid #30363d; }}
  .dot {{ width:11px; height:11px; border-radius:50%; }}
  .t {{ margin-left:10px; color:#8b949e; font:600 12px/1 ui-sans-serif,-apple-system,sans-serif; }}
  pre {{ padding:16px 18px; color:#c9d1d9; white-space:pre;
         font:13px/1.55 "SF Mono",Menlo,Consolas,monospace; }}
  .hl {{ color:#ffa657; }}
</style>
<div class="win">
  <div class="bar">
    <span class="dot" style="background:#ff5f57"></span>
    <span class="dot" style="background:#febc2e"></span>
    <span class="dot" style="background:#28c840"></span>
    <span class="t">{html.escape(title)}</span>
  </div>
  <pre>{esc}</pre>
</div>"""

    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
        f.write(doc)
        tmp = f.name

    lines = len(body.splitlines()) + 1
    height = int(lines * 20.2 + 100)
    subprocess.run([
        CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
        f"--window-size={int(width) + 44},{height}",
        f"--screenshot={png_path}", f"file://{tmp}",
    ], capture_output=True, check=False)
    os.unlink(tmp)
    return os.path.exists(png_path)


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    out, title, src = sys.argv[1], sys.argv[2], sys.argv[3]
    text = open(src).read().rstrip() if os.path.exists(src) else src
    ok = render(out, title, text, sys.argv[4:])
    print(("저장: " if ok else "실패: ") + out)
