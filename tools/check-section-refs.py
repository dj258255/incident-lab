#!/usr/bin/env python3
"""'N절이 ...라고 적었습니다' 식 참조가 실제로 그 절을 가리키는지 본다.

글이 회차를 거듭하며 절이 늘고 번호가 밀렸는데 본문의 참조는 안 따라간 자리가 많다.
참조 문장에서 따옴표로 인용한 구절을 뽑아, 그 구절이 실제로 몇 절에 있는지 찾아
번호가 어긋나면 보고한다.

  python3 checkref.py <파일...>

## 두 가지를 본다

1. **절 번호 어긋남**: "N절이 ...라고 적었다"의 인용문이 실제로는 다른 절에 있는 경우.
2. **본문에 없는 인용**: 인용문이 글 전체에서 그 참조 문장에만 있는 경우. 옛 판의
   문장을 인용한 채 그 판을 고치면 이렇게 된다. 독자가 따라가면 없는 문장을 찾는다.

## 2번의 오탐

이 저장소는 앞 절의 주장을 **원문 그대로가 아니라 요약해서** 따옴표에 넣는 일이 잦다.
그러면 취지는 그 절에 있는데 글자는 없어서 후보로 올라온다. 그것은 정당한 문체다.
실제로 21건 중 셋만 진짜였고(인용한 내용 자체가 어디에도 없었다) 나머지는 요약 인용이었다.

그래서 2번은 **후보 목록으로만 쓰고, 인용한 취지가 그 절에 있는지를 사람이 봐야 한다.**
자기귀속 동사("~라고 적었습니다")가 없는 줄은 남의 주장을 반박하거나 가정한 것이라
아예 세지 않는다. 그 조건을 안 걸었을 때는 오탐이 47건이었다.
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
                            # 인용문이 그 참조 문장이 든 절에만 있으면 두 경우다.
                            #   (a) 자기 절 안의 문장을 다시 인용한 것       → 문제 아님
                            #   (b) 옛 판의 문장을 인용한 채 그 판을 고친 것 → 결함
                            # 글 전체에서 그 문구가 한 번뿐이면 (b) 다. 인용한 원문이
                            # 사라졌다는 뜻이라 독자가 따라가면 없는 문장을 찾는다.
                            # 처음에는 이 자리를 통째로 건너뛰어 세 편의 끊긴 인용을
                            # 놓쳤다.
                            # 자기귀속 동사가 있을 때만 본다. 없으면 남의 주장을
                            # 인용해 반박하거나("~는 말은 틀립니다") 가정한 것이라
                            # 앞 절을 가리키는 참조가 아니다. 처음에는 이 조건 없이
                            # 세어 오탐이 47건 나왔다.
                            ATTR = ('적었습니다', '적어 두었습니다', '적어 뒀습니다',
                                    '적은', '적어 둔', '썼습니다', '말했습니다')
                            if not any(a in ln for a in ATTR):
                                continue
                            whole = re.sub(r'\s+', '', text)
                            if whole.count(key) <= 1:
                                print(f"  {lineno:>5}  {num}절 인용이 본문에 없음 "
                                      f"(옛 판의 문장을 인용한 채 고친 자리)")
                                print(f"         인용: {q[:60]}")
                            continue
                        tag = f"실제로는 {'/'.join(found)}절" if found else "어느 절에도 없음"
                        print(f"  {lineno:>5}  {num}절 인용 불일치 → {tag}")
                        print(f"         인용: {q[:60]}")

if __name__ == '__main__':
    main()
