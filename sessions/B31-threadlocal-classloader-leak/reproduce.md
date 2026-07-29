# 재현 기록

실행한 명령과 출력을 원문 그대로 남깁니다. 요약하지 않습니다.

## 환경

- 호스트: Rocky Linux 9 (aarch64), Docker 29.4.2, Docker Compose v5.1.3
- 최소 재현: eclipse-temurin:21-jdk-alpine, JDK 21.0.11+10-LTS (컨테이너에서 컴파일·실행)
- 실제 스택: Spring Boot 3.3.5 WAR를 Apache Tomcat 10.1.57에 배포 (tomcat:10.1-jdk21-temurin, JVM 21.0.11+10-LTS)
- 일시: 2026-07-28
- 계측: 폐기한 클래스로더마다 `WeakReference`를 걸어 두고 `System.gc()` 5회 뒤 생존 수를 셉니다. Metaspace는 `MemoryPoolMXBean`의 `Metaspace` 풀 사용량입니다. OOM을 기다리지 않으므로 300 사이클 실행이 30초 안에 끝납니다.
- 재현성: 생존 수는 난수도 시간 측정도 없는 값이라 실행마다 같습니다. 최종 코드로 2회 실행해 300/0/1이 동일함을 확인했습니다. Metaspace 사용량은 GC 시점에 따라 0.1MB 단위로 흔들립니다.

## 1. 최소 재현: 세 조건 대조 (재배포 300회)

웹앱 역할 클래스를 실행기 클래스패스 밖(`/tmp/webapp`)에 따로 컴파일해, `URLClassLoader`만 그 클래스를 적재하게 합니다.

```console
$ docker compose up --abort-on-container-exit
 Network b31-threadlocal-classloader-leak_default Created
 Container lab-b31-leak Started
lab-b31-leak  | == B31 ThreadLocal·ClassLoader 누수 재현 (JDK 21.0.11+10-LTS) ==
lab-b31-leak  |   웹앱 클래스 경로 = /tmp/webapp (실행기 클래스패스에는 없다)
lab-b31-leak  |   JVM 인자 = []
lab-b31-leak  |   계측 = 폐기한 클래스로더에 WeakReference를 걸고 GC 후 생존 수를 센다
lab-b31-leak  |
lab-b31-leak  | [구조 확인] 재배포 1회분으로 참조 고리를 확인한다
lab-b31-leak  |   웹앱 클래스   = webapp.RequestContextHolder  <- webapp-probe (URLClassLoader)
lab-b31-leak  |   키(맵에 들어갈 ThreadLocal)를 담은 static 필드 = RequestContextHolder.CTX (java.lang.ThreadLocal, ThreadLocal 여부 true)
lab-b31-leak  |   값 타입       = webapp.RequestContextHolder$Ctx  <- webapp-probe
lab-b31-leak  |   값과 키의 클래스로더가 같은가 = true   <- 값에서 클래스로더를 거쳐 키로 되짚어진다, 그래서 약한참조 키가 죽지 않는다
lab-b31-leak  |
lab-b31-leak  | [실험 1] 누수: ThreadLocal이 웹앱 클래스로더 안 static 필드 + remove() 없음
lab-b31-leak  |   재배포(새 클래스로더) 300회, 워커 스레드 1개를 끝까지 유지
lab-b31-leak  |   생존 클래스로더 = 300 / 300   <- 폐기했어야 할 클래스로더가 전부 남았다
lab-b31-leak  |   Metaspace 증가분 = 2.0 MB (총 3.1 MB)
lab-b31-leak  |
lab-b31-leak  | [실험 2] 해소: 같은 조건에서 try/finally로 remove() 호출
lab-b31-leak  |   재배포(새 클래스로더) 300회, 워커 스레드 1개를 끝까지 유지
lab-b31-leak  |   생존 클래스로더 = 0 / 300   <- 전부 수거됐다
lab-b31-leak  |   Metaspace 증가분 = 0.2 MB (총 3.3 MB)
lab-b31-leak  |
lab-b31-leak  | [실험 3] 대조: ThreadLocal이 웹앱 클래스로더 밖 + remove() 없음
lab-b31-leak  |   재배포(새 클래스로더) 300회, 워커 스레드 1개를 끝까지 유지
lab-b31-leak  |   생존 클래스로더 = 1 / 300   <- 마지막 값 하나만 남는다. 덮어쓰기가 이전 것을 놓아주기 때문이다
lab-b31-leak  |   Metaspace 증가분 = 0.0 MB (총 3.4 MB)
lab-b31-leak  |
lab-b31-leak  | [해소 2] 누수 실험의 워커 스레드를 종료(스레드 갱신)한 뒤 다시 셈
lab-b31-leak  |   생존 클래스로더 = 0 / 300   <- 스레드가 죽으면 그 스레드의 ThreadLocalMap도 같이 죽는다
lab-b31-leak  |   Metaspace 총 사용량 = 1.9 MB
lab-b31-leak  |
lab-b31-leak  | == 요약 (재배포 300회, JDK 21) ==
lab-b31-leak  |   누수 (웹앱 안 ThreadLocal, remove 없음)    생존 300 / 300  Metaspace 증가분 2.0 MB
lab-b31-leak  |   해소 (같은 조건 + try/finally remove)      생존 0 / 300    Metaspace 증가분 0.2 MB
lab-b31-leak  |   대조 (ThreadLocal이 웹앱 밖, remove 없음)  생존 1 / 300    Metaspace 증가분 0.0 MB
lab-b31-leak exited with code 0
```

같은 내용이 [results/run-output.txt](results/run-output.txt)에 있습니다.

## 2. Metaspace를 좁게 잡고 OOM까지

`-Xmx256m -XX:MaxMetaspaceSize=24m`으로 고정하고 같은 코드를 두 번 돌립니다. 먼저 순진한 설계(ThreadLocal 하나를 계속 덮어쓰기)로 10,000회, 다음에 누수 조건으로 6,000회입니다. 힙을 넉넉히 준 것은 힙 OOM이 먼저 터져 원인이 흐려지는 것을 막기 위해서입니다.

```console
$ docker compose --profile oom up oom --abort-on-container-exit
lab-b31-oom  | == B31 ThreadLocal·ClassLoader 누수 재현 (JDK 21.0.11+10-LTS) ==
lab-b31-oom  |   웹앱 클래스 경로 = /tmp/webapp (실행기 클래스패스에는 없다)
lab-b31-oom  |   JVM 인자 = [-Xmx256m, -XX:MaxMetaspaceSize=24m]
lab-b31-oom  |   계측 = 폐기한 클래스로더에 WeakReference를 걸고 GC 후 생존 수를 센다
lab-b31-oom  |
lab-b31-oom  | [부하] 순진한 설계(ThreadLocal 하나를 계속 덮어쓰기)으로 재배포 10,000회를 돌린다
lab-b31-oom  |     2,000 사이클: Metaspace 11.5 MB
lab-b31-oom  |     4,000 사이클: Metaspace 9.7 MB
lab-b31-oom  |     6,000 사이클: Metaspace 3.4 MB
lab-b31-oom  |     8,000 사이클: Metaspace 13.1 MB
lab-b31-oom  |    10,000 사이클: Metaspace 13.6 MB
lab-b31-oom  |   10,000 사이클 완주, OOM 없음. Metaspace 13.6 MB
lab-b31-oom  | == B31 ThreadLocal·ClassLoader 누수 재현 (JDK 21.0.11+10-LTS) ==
lab-b31-oom  |   웹앱 클래스 경로 = /tmp/webapp (실행기 클래스패스에는 없다)
lab-b31-oom  |   JVM 인자 = [-Xmx256m, -XX:MaxMetaspaceSize=24m]
lab-b31-oom  |   계측 = 폐기한 클래스로더에 WeakReference를 걸고 GC 후 생존 수를 센다
lab-b31-oom  |
lab-b31-oom  | [부하] 누수 조건(웹앱 안 ThreadLocal + remove 없음)으로 재배포 6,000회를 돌린다
lab-b31-oom  |     2,000 사이클: Metaspace 11.4 MB
lab-b31-oom  |     3,773 사이클에서 java.lang.OutOfMemoryError: Metaspace
lab-b31-oom  | Exception in thread "main" java.lang.OutOfMemoryError: Metaspace
lab-b31-oom  | 	at java.base/java.lang.ClassLoader.defineClass1(Native Method)
lab-b31-oom  | 	at java.base/java.lang.ClassLoader.defineClass(ClassLoader.java:1027)
lab-b31-oom  | 	at java.base/java.security.SecureClassLoader.defineClass(SecureClassLoader.java:150)
lab-b31-oom  | 	at java.base/java.net.URLClassLoader.defineClass(URLClassLoader.java:524)
lab-b31-oom  | 	at java.base/java.net.URLClassLoader$1.run(URLClassLoader.java:427)
lab-b31-oom  | 	at java.base/java.net.URLClassLoader$1.run(URLClassLoader.java:421)
lab-b31-oom  | 	at java.base/java.security.AccessController.executePrivileged(AccessController.java:809)
lab-b31-oom  | 	at java.base/java.security.AccessController.doPrivileged(AccessController.java:714)
lab-b31-oom  | 	at java.base/java.net.URLClassLoader.findClass(URLClassLoader.java:420)
lab-b31-oom  | 	at java.base/java.lang.ClassLoader.loadClass(ClassLoader.java:593)
lab-b31-oom  | 	at java.base/java.lang.ClassLoader.loadClass(ClassLoader.java:526)
lab-b31-oom  | 	at LeakLab.deploy(LeakLab.java:135)
lab-b31-oom  | 	at LeakLab.stress(LeakLab.java:219)
lab-b31-oom  | 	at LeakLab.main(LeakLab.java:63)
```

남아 있는 OOM 실행 기록은 위 1회분뿐입니다. 전문이 [results/oom-output.txt](results/oom-output.txt)에 있고, 그 파일에도 1회분만 들어 있습니다. 3,773이라는 지점이 실행마다 반복되는지는 확인하지 않았습니다.

이 3,773이라는 수 자체에는 의미가 없습니다. `MaxMetaspaceSize=24m`은 결과를 30초 안에 보려고 인위적으로 조인 값입니다. 이 플래그의 JVM 기본값은 무제한입니다.

```console
$ docker run --rm eclipse-temurin:21-jdk-alpine java -XX:+PrintFlagsFinal -version | grep MaxMetaspaceSize
   size_t MaxMetaspaceSize                         = 18446744073709551615                      {product} {default}
```

그래서 현실의 실패는 대개 이 오류로 오지 않습니다. Metaspace가 컨테이너 메모리 한도를 밀어 올려 커널이 프로세스를 OOM-Kill로 죽이거나, 클래스 메타데이터가 쌓이면서 GC 압박이 커져 응답이 느려지는 쪽으로 나타납니다. 이 세션은 두 경로 중 어느 쪽도 재현하지 않았습니다. 위 실행이 보여 주는 것은 메타데이터가 실제로 해제되지 않고 한 방향으로만 쌓인다는 사실까지입니다.

## 3. 실제 스택: Spring Boot WAR를 Tomcat 10.1에 올리고 내리기

`spring/drive.sh`가 기동, 요청, 언디플로이, 로그 확인, 정리를 순서대로 몰아줍니다. 워커 스레드는 `maxThreads="1"`로 고정해 두 요청이 반드시 같은 스레드에서 처리되게 했습니다.

```console
$ sh spring/drive.sh
== 1. 기동 (Spring Boot 3.3.5 WAR -> Tomcat 10.1) ==
  배포 대기.. 완료
  Server version: Apache Tomcat/10.1.57
  JVM Version:    21.0.11+10-LTS

== 2. remove() 누락 경로 ==
$ curl -H 'X-User: alice' http://localhost:18031/lab/api/leaky/whoami
  thread=http-nio-8080-exec-1 seenUser=alice requestNo=1
$ curl http://localhost:18031/lab/api/leaky/whoami          # 헤더 없이, 인증 안 한 요청
  thread=http-nio-8080-exec-1 seenUser=alice requestNo=1

== 3. try/finally remove() 경로 ==
$ curl -H 'X-User: bob' http://localhost:18031/lab/api/safe/whoami
  thread=http-nio-8080-exec-1 seenUser=bob requestNo=2
$ curl http://localhost:18031/lab/api/safe/whoami           # 헤더 없이, 인증 안 한 요청
  thread=http-nio-8080-exec-1 seenUser=(none) requestNo=-

== 4. 언디플로이(재배포의 앞단계) 후 Tomcat이 찍는 것 ==
  thread=http-nio-8080-exec-1 seenUser=carol requestNo=3
$ docker compose exec tomcat rm webapps/lab.war
  언디플로이 대기(HostConfig 백그라운드 주기 10초).... 완료
  lab-b31-tomcat  | 28-Jul-2026 22:20:10.353 INFO [Catalina-utility-2] org.apache.catalina.startup.HostConfig.undeploy Undeploying context [/lab]
  lab-b31-tomcat  | 28-Jul-2026 22:20:10.433 SEVERE [Catalina-utility-2] org.apache.catalina.loader.WebappClassLoaderBase.checkThreadLocalMapForLeaks The web application [lab] created a ThreadLocal with key of type [org.springframework.boot.SpringBootExceptionHandler.LoggedExceptionHandlerThreadLocal] (value [org.springframework.boot.SpringBootExceptionHandler$LoggedExceptionHandlerThreadLocal@6ab6dbeb]) and a value of type [org.springframework.boot.SpringBootExceptionHandler] (value [org.springframework.boot.SpringBootExceptionHandler@6b429437]) but failed to remove it when the web application was stopped. Threads are going to be renewed over time to try and avoid a probable memory leak.
  lab-b31-tomcat  | 28-Jul-2026 22:20:10.442 SEVERE [Catalina-utility-2] org.apache.catalina.loader.WebappClassLoaderBase.checkThreadLocalMapForLeaks The web application [lab] created a ThreadLocal with key of type [java.lang.ThreadLocal] (value [java.lang.ThreadLocal@26fce64d]) and a value of type [lab.RequestContext.UserCtx] (value [UserCtx[user=carol, requestNo=3]]) but failed to remove it when the web application was stopped. Threads are going to be renewed over time to try and avoid a probable memory leak.

== 5. 대조군: --add-opens 없이 띄우면 ==
  배포 대기.. 완료
  thread=http-nio-8080-exec-1 seenUser=dave requestNo=1
  언디플로이 대기..... 완료
  lab-b31-tomcat-noopen  | 28-Jul-2026 22:20:40.657 INFO [Catalina-utility-1] org.apache.catalina.startup.HostConfig.undeploy Undeploying context [/lab]
  lab-b31-tomcat-noopen  | 28-Jul-2026 22:20:40.828 WARNING [Catalina-utility-1] org.apache.catalina.loader.WebappClassLoaderBase.checkThreadLocalsForLeaks You need to add "--add-opens=java.base/java.lang=ALL-UNNAMED" to the JVM command line arguments to enable ThreadLocal memory leak detection. Alternatively, you can suppress this warning by disabling ThreadLocal memory leak detection.

== 6. 정리 ==
   Container lab-b31-tomcat-noopen Stopping
   Container lab-b31-tomcat-noopen Stopped
   Container lab-b31-tomcat-noopen Removing
   Container lab-b31-tomcat-noopen Removed
   Network spring_default Removing
   Network spring_default Removed
```

Tomcat 10.1의 `bin/catalina.sh`는 `--add-opens=java.base/java.lang=ALL-UNNAMED`를 기본으로 붙입니다. 5절은 그 줄을 지우고 같은 이미지를 띄운 것이고, 지시는 `compose.yml`의 `tomcat-noopen` 서비스에 있습니다. 전문이 [results/spring-output.txt](results/spring-output.txt)에 있습니다.

## 4. 정리

```console
$ docker compose down
 Container lab-b31-leak Removed
 Network b31-threadlocal-classloader-leak_default Removed
```

`spring/drive.sh`는 마지막 절에서 스스로 `docker compose down`까지 실행합니다.

## 측정값 요약

| 실험 | 조건 | 결과 |
|---|---|---|
| 1 누수 | 웹앱 안 static ThreadLocal, remove 없음, 재배포 300회 | 생존 클래스로더 300/300, Metaspace +2.0MB |
| 2 해소 | 같은 조건 + try/finally remove() | 0/300, +0.2MB |
| 3 대조 | ThreadLocal이 웹앱 밖, remove 없음 | 1/300, +0.0MB |
| 4 스레드 갱신 | 실험 1의 워커 스레드를 종료한 뒤 재계측 | 0/300, Metaspace 총 3.4MB에서 1.9MB로 |
| 5 OOM | `-XX:MaxMetaspaceSize=24m`, 누수 조건 | 3,773 사이클에서 `OutOfMemoryError: Metaspace` (1회 실행, 재현 반복 확인 안 함) |
| 5 대조 | 같은 설정, 순진한 설계(덮어쓰기) 10,000회 | OOM 없음, Metaspace 13.6MB |
| 6 실제 스택 | Tomcat 10.1 + Spring Boot WAR, maxThreads=1 | 헤더 없는 요청이 `seenUser=alice`, 언디플로이 시 `checkThreadLocalMapForLeaks` SEVERE 2건 |
| 7 실제 스택 대조 | 같은 구성에서 `--add-opens` 제거 | 누수 경고 없음, `addExportsThreadLocal` 경고만 |

`MaxMetaspaceSize=24m`은 실무 설정이 아니라 결과를 빨리 보려고 조인 값입니다. 5행의 사이클 수를 실무 수명 예측에 쓰면 안 됩니다.

## 문서와 소스로 확인한 것 (실측 아님)

블로그 4절이 인용하는 스레드 갱신 경로입니다. 이 세션에서 실행해 잰 것이 아니라 Tomcat 10.1.x 소스와 10.1 설정 문서를 읽어 확인한 것이라, 위 측정값 표와 분리해 둡니다.

- `clearReferencesThreadLocals`가 `true`(기본값)여도 Tomcat은 살아 있는 `ThreadLocalMap` 엔트리를 직접 지우지 않습니다. `WebappClassLoaderBase.checkThreadLocalsForLeaks()`가 `expungeStaleEntries()`를 부른 뒤 `checkThreadLocalMapForLeaks()`로 테이블을 훑고, 웹앱이 적재한 키나 값을 만나면 `log.error(...)`를 찍는 것으로 끝납니다. 제거 호출이 없습니다. `expungeStaleEntries()`가 치우는 대상은 이미 키가 끊긴 엔트리뿐이라 이 누수에는 닿지 않습니다. 이 설정이 켜고 끄는 것은 경고이지 회수가 아닙니다.
- 회수를 거는 것은 `ThreadLocalLeakPreventionListener`입니다. `Context`의 `AFTER_STOP_EVENT`에서 커넥터 스레드풀에 정지 시각을 기록하고(`ThreadPoolExecutor.contextStopping()`), 그 시각보다 먼저 만들어진 스레드는 다음 작업을 끝내고 풀로 돌아올 때 `stopCurrentThreadIfNeeded()`에서 `StopPooledThreadException`으로 스스로 죽습니다. 이 리스너는 배포본 `conf/server.xml`에 기본으로 들어 있습니다.
- 갱신 주기 파라미터는 `Executor`의 `threadRenewalDelay`이고 기본값은 1,000ms입니다(`Constants.DEFAULT_THREAD_RENEWAL_DELAY = 1000L`). 문서 원문은 "To avoid renewing all threads at the same time, this option sets a delay between renewal of any 2 threads. The value is in ms, default value is `1000` ms. If value is negative, threads are not renewed."입니다. `Context`의 `renewThreadsWhenStoppingContext`(기본 `true`)도 함께 켜져 있어야 합니다.
- 따라서 갱신은 그 스레드가 작업을 하나 더 끝내고 풀로 돌아와야 일어납니다. 재배포 뒤 트래픽이 없으면 갱신도 일어나지 않습니다.

## 재지 않은 것

- Tomcat이 실제 재배포에서 몇 초 만에 몇 개의 클래스로더를 회수하는지. 최소 재현에서 잰 것은 워커 스레드를 직접 종료했을 때 300개가 회수된다는 사실 하나입니다.
- `renewThreadsWhenStoppingContext="false"`나 `threadRenewalDelay="-1"`에서 재배포를 반복했을 때의 붕괴 지점.
- 실제 WAR의 `WebappClassLoader`가 재배포 1회당 남기는 양. 이 재현의 약 7KB는 클래스 두 개짜리 맨 `URLClassLoader` 기준이고, `WebappClassLoader`는 parent-last 탐색 경로(`delegate` 기본 `false`), JAR 목록과 수정 시각, `resourceEntries` 캐시, `WebResourceRoot` 참조를 함께 들고 있어 자릿수가 다릅니다.
- 컨테이너 OOM-Kill과 GC 압박에 의한 응답 지연. 실무의 실제 실패 모드는 이 두 쪽인데 둘 다 재현하지 않았습니다.
