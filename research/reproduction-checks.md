# 재현 설계 검증 기록 (2026-07-28)

근거 조사 중에 "카탈로그에 적힌 대로 만들면 장애가 재현되지 않는다"고 판정한 세션들을, 실제로 돌려서 재현 조건을 확정한 기록입니다.
전부 이 서버의 도커에서 직접 실행했고, 아래 수치는 그 출력입니다.

환경: Rocky Linux 9 (aarch64), Docker. PostgreSQL 16.14 (postgres:16-alpine), JDK 21.0.11 (eclipse-temurin:21-jdk-alpine).

---

## B43 expand-contract — 상수 기본값으로는 재현 불가, volatile 기본값이 정답

3,000,000행(196MB) 테이블에 컬럼을 추가하며 시간을 쟀습니다.

| 방식 | 소요 시간 |
|---|---|
| `ADD COLUMN c1 int NOT NULL DEFAULT 0` (상수) | **4.885 ms** |
| `ADD COLUMN c2 uuid NOT NULL DEFAULT gen_random_uuid()` (volatile) | **16,859.704 ms** |
| 컬럼 추가 → `UPDATE` 300만 행 → `SET NOT NULL` | **36,999.461 ms** |

상수 기본값은 4.9밀리초에 끝납니다. 카탈로그대로 "수백만 행에 ADD COLUMN NOT NULL"을 걸면 **재현에 실패합니다.** PG 11부터 상수 기본값은 메타데이터만 갱신하기 때문입니다.

락이 실제로 전 쿼리를 막는지도 확인했습니다. volatile 기본값 ALTER를 걸어둔 채 다른 세션에서 `SELECT count(*)`를 실행했습니다.

- 락 없을 때: 311.691 ms / 302.593 ms / 261.036 ms
- ALTER 진행 중: **19,412.089 ms** (약 62배)

`lock_timeout` 기본값은 `0`(무제한)이었습니다. 그래서 대기하던 SELECT가 잘리지 않고 19초를 그대로 기다립니다.

**확정된 재현 레시피**: PG 11 이상에서 재현하려면 기본값을 `gen_random_uuid()` 같은 volatile 함수로 주어 테이블 재작성을 유발해야 합니다. 상수 기본값과 나란히 놓고 "4.9ms vs 16.9초"를 보여주는 편이 오히려 글의 논점이 선명해집니다. 세션에서 쓸 PG 버전을 반드시 명시하세요.

---

## B18 DST 존재하지 않는 시간 — java.time으로는 예외가 안 난다

`TZ=America/New_York`에서 2024-03-10 02:30(spring-forward로 존재하지 않는 시각)을 다섯 경로로 다뤄봤습니다.

| 경로 | 결과 |
|---|---|
| `ZonedDateTime.of(...)` | 예외 없음 → `2024-03-10T03:30-04:00` |
| `LocalDateTime.atZone(...)` | 예외 없음 → `2024-03-10T03:30-04:00` |
| `GregorianCalendar` (기본 lenient) | 예외 없음 → `Sun Mar 10 03:30:00 EDT 2024` |
| `GregorianCalendar` + `setLenient(false)` | **`IllegalArgumentException: HOUR_OF_DAY: 2 -> 3`** |
| `java.sql.Timestamp.valueOf("2024-03-10 02:30:00")` | 예외 없음 → `2024-03-10 03:30:00.0` |

`setLenient(false)` 경로에서 나온 예외 문자열이 Atlassian KB에 적힌 것(`HOUR_OF_DAY: 1 -> 2`, `2 -> 3`, `3 -> 4`)과 정확히 일치합니다.

**확정된 재현 레시피**: 두 경로를 나란히 보여주는 구성이 맞습니다. 한쪽은 `setLenient(false)`로 시끄럽게 터지는 그림, 다른 쪽은 `java.time`이 아무 신호 없이 02:30을 03:30으로 바꿔놓는 그림입니다. 후자가 오히려 무서운 쪽이고, 원본 데이터가 한 시간 밀린 채 저장되는 게 실무에서 더 자주 사고로 이어집니다.

---

## B39 billion laughs — JDK 기본 파서가 이미 막고 있다

773바이트짜리 고전 billion laughs(9단계 × 10배)를 JDK 21 기본 `DocumentBuilderFactory`에 넣었습니다.

| 설정 | 결과 |
|---|---|
| 완전 기본값 | `SAXParseException: JAXP00010001: The parser has encountered more than "64000" entity expansions in this document; this is the limit imposed by the JDK.` |
| `disallow-doctype-decl=true` (권장 방어) | `SAXParseException: DOCTYPE is disallowed when the feature ... set to true.` |
| `-Djdk.xml.entityExpansionLimit=0` + `-Xmx200m` | **`OutOfMemoryError: Java heap space`** |

즉 요즘 JDK는 기본값으로 이미 안전합니다. 카탈로그의 "기본 파서에 billion laughs → 메모리 폭증"은 **그대로는 재현되지 않습니다.**

**확정된 재현 레시피**: `jdk.xml.entityExpansionLimit=0`으로 한도를 명시적으로 풀어야 OOM이 납니다. 이건 억지가 아니라 오히려 좋은 서사입니다. "왜 이 공격이 옛날 얘기가 됐는가 — JDK가 64,000이라는 한도를 기본으로 넣었기 때문"이고, 한도를 끄는 순간 773바이트가 200MB 힙을 날린다는 걸 보여주면 방어의 가치가 수치로 드러납니다. 다만 글에서 "요즘 파서는 기본으로 막힌다"는 사실을 먼저 밝혀야 정직합니다.

---

## B31 ThreadLocal·ClassLoader 누수 — 조건 세 개가 다 맞아야 샌다

"폐기했어야 할 클래스로더 300개 중 GC 후 몇 개가 살아있나"를 약한참조로 셌습니다. OOM을 기다리는 것보다 빠르고 결과가 딱 떨어집니다.

| 조건 | 생존 클래스로더 | Metaspace |
|---|---|---|
| ThreadLocal이 앱 클래스로더 안 + `remove()` 없음 | **300 / 300** | 1.9 MB |
| 같은 조건 + `remove()` 호출 | 0 / 300 | 1.3 MB |
| ThreadLocal이 앱 클래스로더 **밖** + `remove()` 없음 | 1 / 300 | 1.2 MB |

처음엔 워커 스레드 하나 + 매 사이클 새 클래스로더 + `remove()` 누락으로 짰는데 3,000 사이클을 돌려도 OOM이 나지 않았습니다. 같은 `ThreadLocal`에 계속 덮어쓰면 직전 값만 남고 이전 것들은 정상적으로 수거되기 때문입니다.

누수가 나려면 세 조건이 동시에 필요합니다.

1. 워커 스레드가 재배포 후에도 살아있을 것 (스레드풀)
2. 재배포마다 클래스로더가 새로 생길 것
3. **`ThreadLocal` 객체 자체가 웹앱 클래스로더 안의 static 필드에 있을 것**

3번이 핵심입니다. `ThreadLocalMap`의 키는 약한참조라서 `ThreadLocal`이 죽으면 엔트리가 정리됩니다. 그런데 값 → 웹앱 클래스로더 → 그 안의 클래스 → `static ThreadLocal` 로 참조가 한 바퀴 돌아오면 키가 영영 죽지 않아 엔트리가 stale이 되지 않고, 따라서 정리도 되지 않습니다. 위 표의 세 번째 줄(생존 1개, 마지막 값 하나뿐)이 그 대조군입니다.

**확정된 재현 레시피**: 웹앱 쪽에 `public static final ThreadLocal<Ctx> CTX`를 두고 요청 처리에서 `set()`만 하는 형태로 만들어야 합니다. 실무에서 흔한 유틸 클래스 모양 그대로라 억지스럽지도 않습니다. Tomcat WAR 핫디플로이 없이 `URLClassLoader`만으로 재현되므로 난이도도 "중간"에서 "쉬움"으로 내려갑니다.

Tomcat으로 갈 경우 주의할 점이 하나 더 있습니다. `clearReferencesThreadLocals` 기본값이 `true`라 Tomcat이 스스로 정리하고 스레드를 갱신해버립니다. 이 보호장치를 끄고 비교하는 구성이 오히려 "JVM이 아니라 WAS가 대신 막아주고 있었다"는 좋은 이야기가 됩니다. JDK 9 이상에서는 `--add-opens=java.base/java.lang=ALL-UNNAMED`가 없으면 Tomcat의 누수 탐지 자체가 동작하지 않습니다.
