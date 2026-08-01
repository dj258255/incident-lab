# 차트를 다시 그리는 데 쓰는 최소 이미지.
#
# tools/render 는 Pillow 로 콘솔 캡처와 막대그래프를 만든다. 그런데 일부 세션의
# scripts/report.py 는 matplotlib 으로 시계열 곡선을 그린다. 호스트에는 둘 다 없어서
# 그 곡선들이 한동안 옛 데이터인 채로 남아 있었다. 렌더 환경을 컨테이너에 가둔다.
#
#   docker build -t incident-lab-mpl tools/render-mpl
#   docker run --rm -v "$PWD:/work" -w /work/sessions/<세션> incident-lab-mpl \
#     python scripts/report.py
FROM python:3.12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends fonts-nanum \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir matplotlib
WORKDIR /work
