#!/usr/bin/env python3
"""de-ai 프롬프트 1절의 금지 패턴을 글에서 찾는다.

기호로 잡히는 것(대시·이모지)만 세고 끝내면 정작 잡아야 할 대비 프레임을 놓친다.
그래서 "A가 아니라 B" 계열을 글자가 아니라 구조로 찾고, 변형까지 후보로 올린다.
코드 블록·인라인 코드·URL·표는 건드리면 안 되므로 제외한다.
"""
import re, sys, pathlib

def strip_protected(text):
    """코드 블록과 인라인 코드, URL 을 공백으로 지운다(줄 수는 보존)."""
    def blank(m):
        return re.sub(r'[^\n]', ' ', m.group(0))
    text = re.sub(r'```.*?```', blank, text, flags=re.S)
    text = re.sub(r'`[^`\n]*`', blank, text)
    text = re.sub(r'https?://\S+', blank, text)
    return text

# 대비 프레임. "아니라/아닌" 형과 무자(無字) 변형 둘 다.
CONTRAST = [
    (re.compile(r'[^\s.。!?]{2,20}\s*(?:이|가|은|는|을|를)?\s*아니라\s'), '대비 프레임(아니라)'),
    (re.compile(r'[^\s.。!?]{2,20}\s*아닌\s'), '대비 프레임(아닌)'),
    (re.compile(r'\S+\s*대신에?\s+\S+'), '대비 프레임 후보(대신)'),
    (re.compile(r'\S+보다\s+\S+(?:입니다|합니다|이다)'), '대비 프레임 후보(보다)'),
]
BANNED = [
    (re.compile(r'(?<![0-9A-Za-z])—(?![0-9])'), '문중 대시'),
    (re.compile(r'그치지\s*않(?:고|습니다|았)'), '"그치지 않고"'),
    (re.compile(r'[\U0001F300-\U0001FAFF☀-➿️]'), '이모지'),
    (re.compile(r'되어지|지어졌|에\s*있어서'), '번역투'),
    (re.compile(r'완벽|최고의|혁신적'), '과장 어휘'),
    (re.compile(r'막연한|감으로\s'), '떠 있는 추상'),
    (re.compile(r'해요\.|해요\s|예요\.|이에요'), '해요체'),
]

def main():
    tally = {}
    for path in sys.argv[1:]:
        p = pathlib.Path(path)
        raw = p.read_text(encoding='utf-8')
        text = strip_protected(raw)
        hits = []
        for lineno, ln in enumerate(text.splitlines(), 1):
            s = ln.strip()
            if not s or s.startswith('|') or s.startswith('>'):
                continue          # 표와 인용 블록은 별도 판단
            for rx, name in BANNED + CONTRAST:
                for m in rx.finditer(ln):
                    a = max(0, m.start() - 28); b = min(len(ln), m.end() + 28)
                    hits.append((lineno, name, ln[a:b].strip()))
        if hits:
            print(f"\n=== {p.name} · {len(hits)}건 ===")
            for lineno, name, ctx in hits:
                print(f"  {lineno:>5}  {name:<20} …{ctx}…")
        for _, name, _ in hits:
            tally[name] = tally.get(name, 0) + 1
    print("\n--- 유형별 합계 ---")
    for k, v in sorted(tally.items(), key=lambda x: -x[1]):
        print(f"  {k:<24} {v}")

if __name__ == '__main__':
    main()
