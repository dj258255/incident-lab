# 시각 증거 렌더러

세션의 측정 수치에 신뢰를 붙이기 위한 도구다. 재현에서 캡처한 콘솔 출력을 터미널 스타일 PNG로,
전후 수치를 막대그래프 PNG로 만든다. 이미지는 손으로 그리지 않는다. 각 세션 `results/render.json`에
적힌 실제 출력과 측정값에서 스크립트가 생성하므로, 리뷰어가 다시 돌려 같은 그림을 얻을 수 있다.

## 왜 컨테이너인가

호스트에 한글 폰트도 이미지 라이브러리도 없다. 호스트를 건드리지 않으려고 렌더 환경을 컨테이너에
가뒀다. 나눔 폰트(고정폭 우선)와 Pillow만 담은 최소 이미지다.

## 준비 (한 번)

```
docker build -t incident-lab-render tools/render
```

## 세션 이미지 생성

저장소 루트에서, 대상 세션의 results 경로를 넘긴다.

```
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/work incident-lab-render \
  sessions/F01-hanmac-divide-by-zero/results
```

`-u`로 호스트 사용자 권한을 넘겨 생성된 PNG가 root 소유로 남지 않게 한다.
스펙은 각 세션 `results/render.json`에 있고, 스키마는 `render.py` 상단 주석에 적어 두었다.

## 스펙 요약

```json
{
  "images": [
    {"type": "term", "out": "01.png", "title": "docker compose up", "lines": [
      "$ docker compose up",
      [["  접수: 정상 100건, 비정상 ", "fg"], ["10건", "red"]]
    ]},
    {"type": "bar", "out": "02.png", "title": "비정상 접수 건수",
     "bars": [{"label": "버그", "value": 10, "color": "red"},
              {"label": "해소", "value": 0, "color": "green"}],
     "note": "측정 환경 ..."}
  ]
}
```

라인은 문자열이거나 `[[조각, 색], ...]` 조각 리스트다. 색은 fg/green/red/dim/yellow.
문자열이 `$`로 시작하면 프롬프트로 보고 초록으로 칠한다.
