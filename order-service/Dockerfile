FROM eclipse-temurin:25-jdk-alpine AS builder
WORKDIR /workspace

COPY mvnw .
COPY .mvn .mvn
COPY pom.xml .

COPY infra-shared/pom.xml infra-shared/pom.xml
COPY infra-database/pom.xml infra-database/pom.xml
COPY auth-service/pom.xml auth-service/pom.xml
COPY order-service/pom.xml order-service/pom.xml

RUN ./mvnw dependency:go-offline -B -pl order-service -am

COPY infra-shared infra-shared
COPY infra-database infra-database
COPY order-service order-service

RUN ./mvnw -B package -pl order-service -am -DskipTests

FROM eclipse-temurin:25-jre-alpine
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app

COPY --from=builder /workspace/order-service/target/*.jar app.jar

USER appuser
EXPOSE 8082

ENTRYPOINT ["java", \
  "-XX:+UseZGC", \
  "-XX:+ZGenerational", \
  "-Djava.security.egd=file:/dev/./urandom", \
  "-jar", "app.jar"]
