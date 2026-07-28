# 트랙 V·X 근거 조사: V01~V08, X1~X4 (2026-07-28)

> 진행 상태(2026-07-28): **V01, V02 조사 완료 / V03~V08, X1~X4 미조사.** 일괄 조사 배치가 중간에 끊겨 파일명이 가리키는 범위를 다 채우지 못했습니다. 이어서 조사할 때 이 파일 아래에 같은 형식으로 덧붙이고 이 줄을 갱신하세요.

## V01 필터 recall
- 주장: 필터+ANN에서 recall 붕괴. pgvector README "조건이 10% 행 매치 시 기본 ef_search 40에서 평균 4행만 매치", Weaviate ACORN 벤치마크상 선택도 20%가 변곡점
- 출처: pgvector README https://github.com/pgvector/pgvector : "If a condition matches 10% of rows, with HNSW and the default hnsw.ef_search of 40, only 4 rows will match on average" 원문 그대로 확인. hnsw.iterative_scan(strict_order/relaxed_order) 옵션도 실재 (원문)
- 출처: Weaviate ACORN 블로그 https://weaviate.io/blog/speed-up-filtered-vector-search : 50% 선택도에선 sweeping이 우세, 20% 선택도에선 ACORN이 훨씬 빠르고 sweeping QPS가 절반 수준으로 하락. Weaviate 1.27(2024-11) 도입 (원문)
- 판정: E2 유지 : 두 인용 모두 벤더 공식 문서·블로그 원문과 일치, 재현 설계(iterative_scan 전후 비교)와 정합
- 메모: 정확한 교차점(변곡점)은 20~50% 사이 어딘가로, 블로그가 "20%가 변곡점"이라고 명시하진 않음. 글에선 "20%에서 sweeping 처리량이 절반으로 떨어진다" 수준으로 쓰는 게 안전. 수치 인용 금지 목록의 pgvector "600배"는 이 행에 없음 — 계속 미인용 유지

## V02 HNSW 스윕
- 주장: pgvector 기본값 m=16, ef_construction=64, ef_search=40, IVFFlat probes=1이 검색 품질 문제의 흔한 원인
- 출처: pgvector README https://github.com/pgvector/pgvector : "m (16 by default)", "ef_construction (64 by default)", hnsw.ef_search "40 by default", IVFFlat probes "1 by default" 전부 원문 일치 (원문)
- 판정: E2 유지 : 기본값 4개 전부 공식 README와 정확히 일치. "최다 원인"은 사실 주장이 아닌 편집 문구라 등급에 영향 없음
- 메모: 블로그화 시 "최다 원인"보다 "기본값이 품질보다 속도 쪽으로 잡혀 있다" 정도로 쓰는 게 안전
