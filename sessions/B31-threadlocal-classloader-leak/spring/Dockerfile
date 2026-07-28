# 멀티스테이지: gradle로 WAR를 만들고, 실행은 실제 Tomcat 10.1에 배포한다.
# 내장 톰캣이 아니라 외부 컨테이너에 올려야 재배포(언디플로이) 때 Tomcat이 무엇을 하는지 볼 수 있다.
FROM gradle:8.10-jdk21 AS build
WORKDIR /src
COPY settings.gradle build.gradle ./
COPY src ./src
RUN gradle --no-daemon bootWar

FROM tomcat:10.1-jdk21-temurin
# 워커 스레드를 1개로 고정한다. 순차 요청이 반드시 같은 스레드에서 처리되게 해 조건을 고정하려는 것이다.
RUN sed -i 's|<Connector port="8080" protocol="HTTP/1.1"|<Connector port="8080" protocol="HTTP/1.1" maxThreads="1" minSpareThreads="1"|' conf/server.xml
COPY --from=build /src/build/libs/lab.war /usr/local/tomcat/webapps/lab.war
