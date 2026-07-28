# incident-lab 시각 증거 렌더러.
# 캡처한 콘솔 출력과 측정 수치를 PNG로 만드는 데만 쓰는 최소 이미지다.
# 한글 렌더를 위해 나눔 폰트를 넣는다. 코딩(고정폭)이 있으면 그걸, 없으면 일반 나눔고딕을 쓴다.
FROM python:3.12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends fonts-nanum \
 && (apt-get install -y --no-install-recommends fonts-nanum-coding || true) \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir pillow

WORKDIR /work
# 스크립트는 마운트한 저장소에서 읽는다. 코드를 고쳐도 재빌드가 필요 없다.
ENTRYPOINT ["python", "/work/tools/render/render.py"]
