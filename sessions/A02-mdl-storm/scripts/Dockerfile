# 부하 생성기와 계측 스크립트를 담는 최소 이미지.
# 호스트에 파이썬 패키지를 설치하지 않으려고 컨테이너에 가뒀다. tools/render와 같은 이유다.
FROM python:3.12-slim
# cryptography 가 필요하다. MySQL 8 의 기본 인증 플러그인 caching_sha2_password 는
# 서버 캐시가 비어 있을 때 RSA 공개키 교환을 하고, pymysql 이 그것을 하려면 이 패키지가
# 있어야 한다. 볼륨을 새로 만든 뒤 첫 연결에서만 걸리므로 한 번 성공하면 그 뒤로는
# 캐시 덕에 없어도 붙는다. 그래서 반복 측정에서만 조용히 깨진다.
RUN pip install --no-cache-dir pymysql==1.1.1 cryptography==44.0.0
