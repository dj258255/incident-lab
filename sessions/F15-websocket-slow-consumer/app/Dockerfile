# 멀티스테이지: gradle로 bootJar를 만들고, 실행은 JDK 이미지에서 한다.
FROM gradle:8.10-jdk21 AS build
WORKDIR /src
COPY settings.gradle build.gradle ./
COPY src ./src
RUN gradle --no-daemon bootJar

FROM eclipse-temurin:21-jdk-alpine
WORKDIR /app
COPY --from=build /src/build/libs/quotestream-0.0.1.jar app.jar
# 힙 크기는 compose.yml의 JAVA_TOOL_OPTIONS로 주입한다.
ENTRYPOINT ["java", "-jar", "app.jar"]
