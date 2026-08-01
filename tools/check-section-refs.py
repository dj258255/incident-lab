#!/usr/bin/env python3
"""'N절이 ...라고 적었습니다' 식 참조가 실제로 그 절을 가리키는지 본다.

글이 회차를 거듭하며 절이 늘고 번호가 밀렸는데 본문의 참조는 안 따라간 자리가 많다.
참조 문장에서 따옴표로 인용한 구절을 뽑아, 그 구절이 실제로 몇 절에 있는지 찾아
번호가 어긋나면 보고한다.

  python3 checkref.py <파일...>
"""
import re, sys, pathlib

HEAD = re.compile(r'^##\s+(?:(\d+)\.\s*)?(.+)$')
# "3절이", "3절은", "3절에", "위 3절 표" 등 + 같은 문장 안의 「」 또는 " " 인용
REF = re.compile(r'(\d+)\s*절')

def sections(text):
    """[(번호 or None, 제목, 시작줄, 끝줄)]"""
    lines = text.splitlines()
    marks = []
    for i, ln in enumerate(lines):
        m = HEAD.match(ln)
        if m:
            marks.append((i, m.group(1), m.group(2).strip()))
    out = []
    for j, (i, num, title) in enumerate(marks):
        end = marks[j + 1][0] if j + 1 < len(marks) else len(lines)
        out.append((num, title, i, end, '\n'.join(lines[i:end])))
    return out

def main():
    for path in sys.argv[1:]:
        p = pathlib.Path(path)
        text = p.read_text(encoding='utf-8')
        secs = sections(text)
        bynum = {s[0]: s for s in secs if s[0]}
        lines = text.splitlines()
        print(f"\n=== {p.name} ===")
        def owner(idx):
            """그 줄이 속한 절 번호. 참조 문장 자신이 든 절은 후보에서 뺀다."""
            cur = None
            for num, title, st, en, body in secs:
                if st <= idx < en:
                    cur = num
            return cur

        for lineno, ln in enumerate(lines, 1):
            if ln.startswith('## '):
                continue
            own = owner(lineno - 1)
            for m in REF.finditer(ln):
                num = m.group(1)
                if num not in bynum:
                    print(f"  {lineno:>5}  {num}절 → 그런 절이 없음   {ln.strip()[:80]}")
                    continue
                # 인용구가 있으면 그 문구가 그 절에 있는지 본다
                quotes = re.findall(r'[\"“”「]([^\"“”「」]{8,60})[\"“”」]', ln)
                for q in quotes:
                    body = bynum[num][4]
                    key = re.sub(r'\s+', '', q)
                    if re.sub(r'\s+', '', body).find(key) < 0:
                        # 다른 절에 있는지 찾는다
                        found = [s[0] for s in secs
                                 if s[0] and s[0] != own
                                 and re.sub(r'\s+','',s[4]).find(key) >= 0]
                        if not found:
                            continue   # 자기 절에만 있으면 참조가 아니라 인용이다
                        tag = f"실제로는 {'/'.join(found)}절" if found else "어느 절에도 없음"
                        print(f"  {lineno:>5}  {num}절 인용 불일치 → {tag}")
                        print(f"         인용: {q[:60]}")

if __name__ == '__main__':
    main()
