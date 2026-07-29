# R14 재현 기록

## 환경

| 항목 | 값 |
|---|---|
| 호스트 | **기록하지 않았습니다.** `uname -srm`·`nproc`·`free -g`를 남기지 않아 어느 장비였는지 확인되지 않습니다. 이 세션은 지연도 처리량도 재지 않아 결론이 흔들리지는 않지만, 아래 "약 1분"을 다른 세션의 시간과 비교하면 안 됩니다 |
| MySQL | 8.4.3 공식 Docker 이미지, 기본 설정 |
| 자원 상한 | 걸지 않았습니다 (성능 측정이 아니라 동작 재현) |
| 클라이언트 | mysql CLI, 접속 문자셋 `--default-character-set=utf8mb4` 고정 |
| 기본값 확인 | character_set_server=utf8mb4, collation=utf8mb4_0900_ai_ci, sql_mode에 STRICT_TRANS_TABLES 포함 (`results/00-defaults.txt`) |
| 일시 | 2026-07-29 |

## 실행

```console
$ docker compose up -d
$ ./scripts/run-experiments.sh     # 6개 실험 일괄, 약 1분 (중간에 컨테이너 재시작 1회 포함)
```

출력 원문 전체가 `results/0*-*.txt`에 남습니다. 아래는 핵심 발췌입니다.

## 1. utf8mb3 이모지 (results/01-truncation.txt)

```console
-- strict(기본값)
ERROR 1366 (HY000): Incorrect string value: '\xF0\x9F\x98\x80 \xED...' for column 'body'

-- non-strict(sql_mode='')
Warning 1366 · 저장은 성공
| 좋은 방송 ? 후원했어요 |     ← 절단이 아니라 ? 치환 (8.4 동작)
```

## 2. 인덱스 767바이트 (results/02-index-limit.txt)

```console
COMPACT + utf8mb4 VARCHAR(255) 인덱스
ERROR 1071 (42000): Specified key was too long; max key length is 767 bytes
KEY(name(191))  → 성공
DYNAMIC + 255   → 성공
```

## 3. CONVERT_TZ (results/03-convert-tz.txt)

```console
-- Docker 이미지 초기 상태: 이미 적재됨 (문서 서술과 다름)
| tz_rows | 1792 |

-- 타임존 테이블을 비우고 재시작한 뒤 (tarball 설치 직후 상태)
| tz_rows | 0 |
| kst_day | daily_sum |
| NULL    |     54000 |          ← 에러 없이 일별 집계가 NULL 한 줄

-- mysql_tzinfo_to_sql /usr/share/zoneinfo 적재 후
| 2026-07-27 |     10000 |
| 2026-07-28 |     44000 |
```

## 4. TIMESTAMP vs DATETIME (results/04-timestamp.txt)

```console
서울 세션 저장 '2026-07-28 21:00:00' → 뉴욕 세션 조회:
| ts 2026-07-28 08:00:00 | dt 2026-07-28 21:00:00 |

'2038-01-19 03:14:08' → ERROR 1292 (TIMESTAMP 상한 초과)
```

## 5. 언어별 (results/05-languages.txt)

한국어·일본어·중국어 기본 한자 무사, 이모지와 한자 확장 B만 `?` 치환.

## 6. 접속 문자셋 착시 (results/06-mojibake.txt)

```console
latin1 접속으로 INSERT '후원 😀 감사' → 에러 없음, 같은 접속으로 읽으면 멀쩡해 보임
utf8mb4 접속으로 읽으면:
| í›„ì› ðŸ˜€ ê°ì‚¬ | C3ADE280BAE2809EC3AC |
```
