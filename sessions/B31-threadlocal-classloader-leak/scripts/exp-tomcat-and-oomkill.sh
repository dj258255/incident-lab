#!/usr/bin/env bash
# README 의 "못 한 것" 세 개를 잡는다.
#
#   1) 실제 Tomcat 재배포를 재현하지 않았습니다
#      웹앱 배포 한 번을 URLClassLoader 하나로 흉내 냈다. catalina.sh 위에서 WAR 를
#      올리고 내리는 경로는 만들지 않았다.
#      → tomcat 이미지에 WAR 를 올렸다 내리기를 반복하고, Tomcat 자신이 남기는
#        누수 경고 로그를 받아 적는다. Tomcat 은 이 문제를 알고 탐지 코드를 갖고 있다.
#        그 로그가 나오는지가 "실제 재배포에서도 같은 일이 벌어지는가"의 답이다.
#
#   2) 현실의 실패 경로 두 가지를 재현하지 않았습니다
#      MaxMetaspaceSize 의 JVM 기본값은 무제한이라 실무의 실패는 대개 컨테이너 메모리
#      한도를 밀어 올려 커널이 OOM-Kill 하거나 GC 압박으로 응답이 느려지는 쪽이다.
#      → Metaspace 상한을 주지 않고 컨테이너 메모리만 좁혀 커널이 죽이는지 본다.
#        JVM 의 OutOfMemoryError 와 커널의 OOM-Kill 은 다른 사건이고, 남는 흔적도 다르다.
#
#   3) 3,773 사이클은 1회분입니다
#      MaxMetaspaceSize=24m 은 결과를 30초 안에 보려고 인위적으로 조인 값이고,
#      그 지점이 반복되는지는 확인하지 않았다.
#      → 같은 조건을 3회 돌려 사이클 수가 모이는지 본다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results"; mkdir -p "$OUT"
IMG=eclipse-temurin:21-jdk-alpine
REPEAT=${REPEAT:-3}

{
echo "# 실제 Tomcat 재배포, 커널 OOM-Kill, 사이클 수 반복"
echo "# 각 조건 1회 실행이고 3절만 ${REPEAT}회입니다."
echo

# ── 3) 사이클 수 반복 ───────────────────────────────────────────────────
echo "=================================================================="
echo "## 3) MaxMetaspaceSize=24m 에서 몇 사이클에 터지는가"
echo "=================================================================="
echo "  발행된 3,773 사이클이 반복되는 값인지 봅니다."
echo
CYCLES=()
for run in $(seq 1 "$REPEAT"); do
  LOG="$OUT/oom-run${run}.txt"
  docker run --rm -v "$ROOT/app":/app -w /app "$IMG" sh -c \
    "javac -d /tmp/webapp webapp/RequestContextHolder.java &&
     javac -d /tmp/lab LeakLab.java &&
     java -cp /tmp/lab -Xmx256m -XX:MaxMetaspaceSize=24m LeakLab /tmp/webapp leak 20000" \
    > "$LOG" 2>&1 || true
  # 마지막으로 찍힌 사이클 번호를 뽑는다. 형식이 바뀌어도 숫자만 걷도록 넉넉히 잡는다.
  # OutOfMemoryError 가 난 줄에서 사이클 수를 뽑는다. 진행 로그의 마지막 줄을 잡으면
  # 2,000 같은 중간 지점이 "터진 지점"으로 기록된다. 실제로 그렇게 나왔다.
  N=$(grep -E "OutOfMemoryError" "$LOG" | grep -oE '[0-9,]+ *사이클' | head -1 | grep -oE '[0-9,]+' | tr -d ',')
  [ -n "${N:-}" ] || N="OOM 줄 없음"
  CYCLES+=("${N:-읽기실패}")
  OOM=$(grep -c "OutOfMemoryError" "$LOG" || true)
  printf "  run%d  마지막 사이클 %-10s OutOfMemoryError %s회\n" "$run" "${N:-?}" "$OOM"
done
echo "  회차별 사이클: ${CYCLES[*]}"
echo

# ── 2) 커널 OOM-Kill ────────────────────────────────────────────────────
echo "=================================================================="
echo "## 2) Metaspace 상한 없이 컨테이너 메모리만 좁히면"
echo "=================================================================="
echo "  MaxMetaspaceSize 의 JVM 기본값은 무제한입니다. 그러면 Metaspace 가 자라도"
echo "  JVM 은 OutOfMemoryError 를 던지지 않고 컨테이너 메모리를 계속 밀어 올립니다."
echo "  한도에 닿으면 죽이는 것은 JVM 이 아니라 커널입니다."
echo
LOG="$OUT/oomkill.txt"
NAME=b31-oomkill
docker rm -f "$NAME" >/dev/null 2>&1 || true
# Metaspace 상한을 주지 않는다. 컨테이너 메모리만 좁힌다.
docker run -d --name "$NAME" --memory 320m --memory-swap 320m \
  -v "$ROOT/app":/app -w /app "$IMG" sh -c \
  "javac -d /tmp/webapp webapp/RequestContextHolder.java &&
   javac -d /tmp/lab LeakLab.java &&
   java -cp /tmp/lab -Xmx192m LeakLab /tmp/webapp leak 200000" >/dev/null
for _ in $(seq 1 90); do
  ST=$(docker inspect "$NAME" -f '{{.State.Status}}' 2>/dev/null)
  [ "$ST" = "exited" ] && break
  sleep 2
done
docker logs "$NAME" > "$LOG" 2>&1 || true
EXIT=$(docker inspect "$NAME" -f '{{.State.ExitCode}}' 2>/dev/null)
KILLED=$(docker inspect "$NAME" -f '{{.State.OOMKilled}}' 2>/dev/null)
LASTCYCLE=$(grep -oE '^[0-9,]+' "$LOG" | tail -1)
echo "  종료 코드 = ${EXIT:-?}, OOMKilled = ${KILLED:-?}"
echo "  마지막 사이클 = ${LASTCYCLE:-읽기실패}"
echo "  JVM 의 OutOfMemoryError = $(grep -c 'OutOfMemoryError' "$LOG" || true)회"
docker rm -f "$NAME" >/dev/null 2>&1 || true
echo
echo "  읽는 법. OOMKilled=true 이고 OutOfMemoryError 가 0회면 **JVM 은 아무 말도 못 하고"
echo "  죽은 것**입니다. 스택 트레이스도 힙 덤프도 남지 않습니다. 종료 코드 137 은"
echo "  SIGKILL(128+9)이고, 이것이 실무에서 더 흔한 실패 경로입니다."
echo "  MaxMetaspaceSize 를 걸어 두면 적어도 JVM 이 유언을 남깁니다."
echo

# ── 1) 실제 Tomcat 재배포 ───────────────────────────────────────────────
echo "=================================================================="
echo "## 1) 실제 Tomcat 에 WAR 를 올렸다 내리기"
echo "=================================================================="
echo "  Tomcat 은 이 문제를 알고 탐지 코드를 갖고 있습니다(WebappClassLoaderBase)."
echo "  재배포 때 ThreadLocal 이 웹앱 클래스로더가 적재한 값을 붙잡고 있으면 경고를"
echo "  남깁니다. 그 로그가 나오는지가 이 절의 답입니다."
echo
WORK="$OUT/tomcat"
rm -rf "$WORK"; mkdir -p "$WORK/src/leakapp"

# 서블릿 하나짜리 웹앱. 요청을 받으면 ThreadLocal 에 자기 클래스로더가 적재한 객체를 넣고
# 지우지 않는다. 이것이 이 세션이 재현한 조건과 같다.
cat > "$WORK/src/leakapp/LeakServlet.java" <<'JAVA'
package leakapp;

import java.io.IOException;
import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

/**
 * 요청 컨텍스트를 ThreadLocal 에 넣고 지우지 않는다.
 * 담기는 값의 클래스가 이 웹앱의 클래스로더에 적재된 것이라, 워커 스레드가 살아 있는 한
 * 그 클래스로더 전체가 회수되지 않는다. 재배포해도 마찬가지다.
 */
@WebServlet("/leak")
public class LeakServlet extends HttpServlet {
    static final ThreadLocal<Ctx> HOLDER = new ThreadLocal<>();

    public static class Ctx {
        final byte[] pad = new byte[4096];
        final String who = LeakServlet.class.getClassLoader().toString();
    }

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse res)
            throws ServletException, IOException {
        HOLDER.set(new Ctx());          // remove() 를 부르지 않는다
        res.setContentType("text/plain");
        res.getWriter().println("ok " + HOLDER.get().who);
    }
}
JAVA

cat > "$WORK/build.sh" <<'SH'
set -e
mkdir -p /work/out/WEB-INF/classes
javac -cp /usr/local/tomcat/lib/servlet-api.jar \
      -d /work/out/WEB-INF/classes /work/src/leakapp/LeakServlet.java
cd /work/out && jar cf /work/leakapp.war .
SH

TC=b31-tomcat
docker rm -f "$TC" >/dev/null 2>&1 || true
docker run -d --name "$TC" -p 18081:8080 -v "$WORK":/work tomcat:10.1-jdk21 >/dev/null
# curl -f 는 404 를 실패로 본다. Tomcat 10.1 은 루트에 기본 앱이 없어 404 를 돌려주므로
# -f 를 쓰면 실제로 떴는데 "안 떴다"로 판정한다. 상태 코드가 무엇이든 응답이 오면 뜬 것이다.
tomcat_up(){ [ -n "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:18081/ 2>/dev/null)" ] \
             && [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:18081/ 2>/dev/null)" != "000" ]; }
for _ in $(seq 1 60); do
  tomcat_up && break
  sleep 2
done
if ! tomcat_up; then
  echo "  Tomcat 이 뜨지 않았습니다. 이 절은 건너뜁니다."
  docker logs "$TC" 2>&1 | tail -5 | sed 's/^/    /'
else
  docker exec "$TC" sh /work/build.sh > "$OUT/tomcat-build.txt" 2>&1 \
    || { echo "  WAR 빌드 실패:"; tail -5 "$OUT/tomcat-build.txt" | sed 's/^/    /'; }
  echo "  WAR 를 10회 올렸다 내립니다. 매번 /leak 을 몇 번 찔러 ThreadLocal 을 채웁니다."
  for i in $(seq 1 10); do
    docker exec "$TC" cp /work/leakapp.war /usr/local/tomcat/webapps/leakapp.war
    for _ in $(seq 1 40); do
      [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:18081/leakapp/leak)" = "200" ] && break
      sleep 1
    done
    for _ in $(seq 1 20); do curl -s http://127.0.0.1:18081/leakapp/leak >/dev/null 2>&1; done
    docker exec "$TC" rm -f /usr/local/tomcat/webapps/leakapp.war
    sleep 4
    printf "    %d회차 배포·해제 완료\n" "$i"
  done
  sleep 5
  docker logs "$TC" > "$OUT/tomcat.log" 2>&1 || true
  echo
  echo "  Tomcat 이 남긴 누수 관련 로그:"
  grep -iE "threadlocal|memory leak|failed to stop|appears to have started a thread" \
    "$OUT/tomcat.log" | head -12 | cut -c1-200 | sed 's/^/    /' \
    || echo "    (해당 로그 없음)"
  echo
  N=$(grep -icE "threadlocal|memory leak" "$OUT/tomcat.log" || true)
  echo "  누수 경고 줄 수 = ${N}"
  echo "  Tomcat 은 재배포마다 이전 웹앱의 클래스로더가 회수됐는지 확인하고,"
  echo "  ThreadLocal 이 붙잡고 있으면 위와 같은 경고를 남깁니다. 경고가 있다는 것은"
  echo "  이 세션이 URLClassLoader 로 흉내 낸 조건이 실제 재배포 경로에서도 같다는 뜻입니다."
  docker rm -f "$TC" >/dev/null 2>&1 || true
fi
echo
echo "  Tomcat 탐지 코드가 몇 버전부터 들어갔는지는 여전히 확인하지 못했습니다."
echo "  위 로그는 이 이미지(tomcat:10.1-jdk21)에서 나온 것입니다."
} 2>&1 | tee "$OUT/exp-tomcat-and-oomkill.txt"
