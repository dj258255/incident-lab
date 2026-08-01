#!/usr/bin/env python3
"""라틴 문자·숫자·코드 스팬 뒤의 조사 앞 공백을 없앤다.

회차를 덧붙이며 쓴 절만 `TTL 을`, `Metaspace 가`처럼 띄어 썼고 나머지 본문은
`TTL을`, `Metaspace가`로 붙였다. 어느 문장이 나중에 붙었는지가 표기만으로 드러난다.
붙이는 쪽으로 통일한다.

건드리면 안 되는 것: 코드 블록, 인라인 코드 **안쪽**, URL, frontmatter.
인라인 코드가 끝난 **뒤**의 조사는 대상이다(`target` 을 → `target`을).

  python3 josa.py --dry <파일...>   # 바뀔 자리만 보여준다
  python3 josa.py <파일...>          # 실제로 고친다
"""
import re, sys, pathlib

# 뒤에 붙일 조사. 짧고 흔한 글자(고, 나 등)는 다른 낱말의 첫 글자일 수 있어 뺀다.
JOSA = ('으로부터', '으로서', '으로써', '이라고', '이라는', '이라도', '이라서', '에서는',
        '에서도', '에게는', '까지도', '부터는', '이라면', '입니다', '이었습니다',
        '으로', '라고', '라는', '라도', '라서', '에서', '에게', '부터', '까지',
        '보다', '처럼', '만큼', '밖에', '조차', '마저', '이나', '이든', '이며',
        '이고', '이다', '이란', '은', '는', '이', '가', '을', '를', '의', '에',
        '와', '과', '도', '만', '로', '뿐', '씩')

# 앞: 라틴 문자·숫자·닫는 백틱/괄호/따옴표. 뒤: 조사 + (공백·구두점·줄끝)
PAT = re.compile(
    r'(?<=[A-Za-z0-9`\)\]%])[ ]('
    + '|'.join(sorted(JOSA, key=len, reverse=True))
    + r')(?=[\s.,;:!?)\]}"\'·…]|$)'
)

def protect(text):
    """코드 블록·인라인 코드 안쪽·URL·frontmatter 를 가려 놓는다."""
    spans = []
    def hide(m):
        spans.append(m.group(0))
        return f'\x00{len(spans)-1}\x00'
    # frontmatter
    text = re.sub(r'\A---\n.*?\n---\n', hide, text, flags=re.S)
    text = re.sub(r'```.*?```', hide, text, flags=re.S)
    text = re.sub(r'`[^`\n]*`', hide, text)          # 인라인 코드 "안쪽"만 가린다
    text = re.sub(r'https?://\S+', hide, text)
    return text, spans

def restore(text, spans):
    return re.sub(r'\x00(\d+)\x00', lambda m: spans[int(m.group(1))], text)

def main():
    dry = '--dry' in sys.argv
    files = [a for a in sys.argv[1:] if not a.startswith('-')]
    total = 0
    for f in files:
        p = pathlib.Path(f)
        raw = p.read_text(encoding='utf-8')
        body, spans = protect(raw)
        hits = list(PAT.finditer(body))
        if not hits:
            continue
        total += len(hits)
        if dry:
            print(f"\n=== {p.name} · {len(hits)}곳 ===")
            for m in hits[:6]:
                a = max(0, m.start() - 26); b = min(len(body), m.end() + 16)
                ctx = restore(body[a:b], spans).replace('\n', ' ')
                print(f"    …{ctx}…")
        else:
            body = PAT.sub(r'\1', body)
            p.write_text(restore(body, spans), encoding='utf-8')
            print(f"  {p.name}: {len(hits)}곳")
    print(f"\n합계 {total}곳")

if __name__ == '__main__':
    main()
