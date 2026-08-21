#!/usr/bin/env python3
"""문서 안 링크가 실제로 가 닿는지 본다.

'결론부터' 표는 행마다 본문 절을 앵커로 가리킨다. 절 번호를 하나 바꾸면
그 링크가 조용히 죽는다. 에러가 안 나므로 눌러 보기 전에는 모른다.

  python3 tools/check-anchors.py                 # 저장소 전체
  python3 tools/check-anchors.py sessions/A27*/README.md

## 세 가지를 본다

1. **문서 안 앵커**: `](#...)` 가 그 문서의 제목에서 만들어지는 앵커인가.
2. **다른 문서의 앵커**: `](other.md#...)` 가 그 문서에 있는가.
3. **파일 경로**: `](path)` 가 실제로 있는가.

## 앵커 만드는 규칙

GitHub 을 따른다. 소문자로 내리고, 낱말 사이 공백을 `-` 로 바꾸고,
그 밖의 문장부호를 지운다. 코드 펜스 안의 `#` 는 제목이 아니다.
"""
import io, os, re, sys, glob

def anchor_of(title):
    a = title.strip().lower()
    a = re.sub(r'[^\w\s가-힣-]', '', a)
    return a.strip().replace(' ', '-')

def anchors(path, _cache={}):
    if path in _cache:
        return _cache[path]
    out, fence = set(), False
    try:
        for ln in io.open(path, encoding='utf-8'):
            if ln.lstrip().startswith('```'):
                fence = not fence
                continue
            if fence or not ln.startswith('#'):
                continue
            out.add(anchor_of(ln.lstrip('#')))
    except OSError:
        pass
    _cache[path] = out
    return out

def check(path):
    bad = []
    t = io.open(path, encoding='utf-8').read()
    here = anchors(path)
    base = os.path.dirname(path)
    for line_no, line in enumerate(t.split('\n'), 1):
        for target in re.findall(r'\]\(([^)\s]+)\)', line):
            if target.startswith(('http', 'mailto')):
                continue
            file_part, _, frag = target.partition('#')
            if not file_part:                       # 같은 문서 안
                if frag not in here:
                    bad.append((line_no, target, '이 문서에 그 제목이 없다'))
                continue
            p = os.path.normpath(os.path.join(base, file_part))
            if not os.path.exists(p):
                bad.append((line_no, target, '그 경로에 파일이 없다'))
            elif frag and frag not in anchors(p):
                bad.append((line_no, target, '그 문서에 그 제목이 없다'))
    return bad

paths = sys.argv[1:] or (
    sorted(glob.glob('sessions/*/README.md')) +
    ['README.md', 'SQLSERVER.md', 'CONVENTIONS.md', 'CATALOG.md'] +
    sorted(glob.glob('audit/*.md')))

total = 0
for p in paths:
    if not os.path.exists(p):
        continue
    bad = check(p)
    if bad:
        print('=== %s' % p)
        for line_no, target, why in bad:
            print('  %5d  %s\n         %s' % (line_no, target, why))
        total += len(bad)
print('끊어진 링크 %d건' % total)
sys.exit(1 if total else 0)
