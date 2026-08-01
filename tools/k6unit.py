"""k6 요약의 시간 값을 단위까지 읽어 밀리초로 돌려준다.

k6 는 값의 크기에 따라 단위를 바꿔 찍는다. 같은 출력 안에 µs, ms, s 가 섞인다.
숫자만 뽑는 정규식은 210.43µs 를 210.43 으로 만들고, 그것을 ms 로 적으면 1000배가
틀린다. 실제로 두 세션이 이 버그를 냈다.
  F03  p(95)=13.99s   -> 13.99 를 "ms" 로 발행. 같은 글 3절과 1000배 어긋남
  F01  p(95)=210.43µs -> 210.43 을 "ms" 로 발행. 동시성이 오르는데 p95 가 떨어지는 곡선
"""
import re

_MULT = {'ns': 1e-6, 'µs': 1e-3, 'us': 1e-3, 'ms': 1.0, 's': 1000.0,
         'm': 60000.0, 'h': 3600000.0}


def ms(text, metric, stat='p(95)', default=None):
    """metric 줄에서 stat 값을 찾아 밀리초로 돌려준다. 못 찾으면 default."""
    m = re.search(re.escape(metric) + r'[^\n]*?' + re.escape(stat) +
                  r'=([\d.]+)(ns|µs|us|ms|s|m|h)\b', text)
    if not m:
        return default
    return float(m.group(1)) * _MULT[m.group(2)]
