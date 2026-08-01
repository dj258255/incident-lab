#!/usr/bin/env python3
"""발행된 표의 숫자가 results/ 에 실제로 있는지 확인한다.

이 랩이 반복해서 낸 결함이 하나 있다. **실험을 다시 돌려 results/ 를 덮어쓰고 글의 표는
안 고치는 것이다.** 결정적인 열(WAL 바이트, 히트율, 페이지 수)은 회차가 바뀌어도 같아서
표 전체가 멀쩡해 보이고, 지연이나 처리량처럼 흔들리는 열만 조용히 낡는다. 리뷰어가
저장소를 열면 글을 반박하는 파일을 만난다.

그래서 발행 전에 기계로 막는다. 표 안의 숫자를 뽑아 그 세션의 results/ 에서 찾고,
한 건도 안 나오면 후보로 올린다.

  python3 tools/check-published-numbers.py                 # 전 세션
  python3 tools/check-published-numbers.py R04 A18         # 일부만
  python3 tools/check-published-numbers.py --blog <경로>   # 블로그 글도 함께
  python3 tools/check-published-numbers.py --prose         # 표 밖 산문까지

## 표만 보면 놓치는 자리

처음에는 표 행만 봤다. 그런데 "못 한 것" 절이 표의 값을 다시 인용하는 자리가 있고,
표를 고치면서 그쪽을 안 고치면 한 글 안에 두 값이 남는다. 실제로 R13 에서 6절 표를
0.07초로 고쳤는데 "못 한 것"이 0.53초를 그대로 인용하고 있었고, 표만 보는 검사는
그것을 못 잡았다. --prose 를 붙이면 표 밖 문장도 본다(후보가 크게 늘어난다).

## 무엇을 못 잡는가

파생값은 results/ 에 없는 것이 정상이다. 배수(3.1배), 백분율, 합계, 반올림한 값이
그렇다. 그래서 이 검사는 **판정이 아니라 후보 목록**이다. 사람이 한 줄씩 봐야 한다.
대신 잡아야 할 것은 확실히 잡는다. 측정값은 results/ 어딘가에 반드시 있다.

낮은 자릿수는 우연히 맞을 확률이 높아 노이즈가 된다. 유효숫자 3자리 이상이거나
천 단위 구분자가 있는 것만 본다.
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SESSIONS = ROOT / "sessions"

# 표 행에서 숫자를 뽑는다. 1,234 / 12.34 / 1234 형태.
NUM = re.compile(r'(?<![\w.])(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+\.\d+|\d{3,})(?![\w])')

def significant(tok: str) -> bool:
    """후보로 올릴 만한 숫자인가."""
    if ',' in tok:
        return True                      # 천 단위 구분자가 있으면 거의 측정값이다
    digits = tok.replace('.', '').lstrip('0')
    if len(digits) < 3:
        return False                     # 두 자리 이하는 우연 일치가 많다
    # 연도, 흔한 설정값은 뺀다
    if tok in {'2011','2012','2013','2014','2015','2016','2017','2018','2019',
               '2020','2021','2022','2023','2024','2025','2026','2038',
               '100','1000','1024','2048','4096','8192','767','3072','200','300',
               '400','500','600','120','180','365','512','256','128','064'}:
        return False
    return True

def variants(tok: str):
    """results/ 에 어떤 표기로 있을지 모른다. 몇 가지로 찾아본다."""
    out = {tok}
    bare = tok.replace(',', '')
    out.add(bare)
    if '.' in bare:
        out.add(bare.rstrip('0').rstrip('.'))    # 4.60 → 4.6
        head, _, tail = bare.partition('.')
        out.add(head)                            # 4.60 → 4  (반올림 대조용)
    else:
        out.add(bare + '.0')
    return {v for v in out if v}

def scan(doc: pathlib.Path, results: pathlib.Path, prose: bool = False):
    if not doc.exists():
        return None
    haystack = []
    if results.is_dir():
        for f in results.rglob('*'):
            if f.is_file() and f.suffix.lower() not in {'.png','.jpg','.jpeg','.gif','.pdf'}:
                try:
                    haystack.append(f.read_text(encoding='utf-8', errors='replace'))
                except Exception:
                    pass
    blob = '\n'.join(haystack)
    missing = []
    for lineno, line in enumerate(doc.read_text(encoding='utf-8').splitlines(), 1):
        is_table = line.lstrip().startswith('|')
        if not is_table and not prose:
            continue                     # 기본은 표 행만 본다
        if is_table and set(line.strip()) <= set('|-: '):
            continue                     # 구분선
        if not is_table and (line.lstrip().startswith(('#', '>', '```')) or '`' in line):
            continue                     # 헤딩·인용·코드가 섞인 줄은 건너뛴다
        for tok in NUM.findall(line):
            if not significant(tok):
                continue
            if not any(v in blob for v in variants(tok)):
                missing.append((lineno, tok, line.strip()[:95]))
    return missing

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    prose = '--prose' in sys.argv
    blog_dir = None
    if '--blog' in sys.argv:
        blog_dir = pathlib.Path(sys.argv[sys.argv.index('--blog') + 1])
        args = [a for a in args if a != str(blog_dir)]

    names = sorted(p.name for p in SESSIONS.iterdir() if p.is_dir())
    if args:
        names = [n for n in names if any(n.startswith(a) for a in args)]

    total = 0
    for name in names:
        s = SESSIONS / name
        docs = [s / "README.md"]
        if blog_dir:
            slug = re.sub(r'^[A-Z]\d+-', '', name)
            cand = blog_dir / f"{slug}.md"
            if cand.exists():
                docs.append(cand)
        for doc in docs:
            miss = scan(doc, s / "results", prose=prose)
            if miss:
                total += len(miss)
                print(f"\n=== {name} · {doc.name} · 후보 {len(miss)}건 ===")
                for lineno, tok, ctx in miss:
                    print(f"  {lineno:>5}  {tok:<14} {ctx}")
    print(f"\n합계 후보 {total}건. 파생값(배수·백분율·합계)은 정상이므로 한 줄씩 확인해야 합니다.")
    return 0

if __name__ == '__main__':
    sys.exit(main())
