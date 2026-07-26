# Multi-stage build for auth-service
FROM eclipse-temurin:25-jdk-alpine AS builder
WORKDIR /workspace

# Copy Maven wrapper and root POM first (layer caching)
COPY mvnw .
COPY .mvn .mvn
COPY pom.xml .

# Copy module POMs
COPY infra-shared/pom.xml infra-shared/pom.xml
COPY infra-database/pom.xml infra-database/pom.xml
COPY rate-limit-starter/pom.xml rate-limit-starter/pom.xml
COPY auth-service/pom.xml auth-service/pom.xml
COPY order-service/pom.xml order-service/pom.xml

# Download dependencies (cached layer)
RUN ./mvnw dependency:go-offline -B -pl auth-service -am

# Copy sources
COPY infra-shared infra-shared
COPY infra-database infra-database
COPY rate-limit-starter rate-limit-starter
COPY auth-service auth-service

# Build
RUN ./mvnw -B package -pl auth-service -am -DskipTests

# Runtime image
FROM eclipse-temurin:25-jre-alpine
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app

COPY --from=builder /workspace/auth-service/target/*.jar app.jar

# Use non-root user
USER appuser

EXPOSE 8083

ENTRYPOINT ["java", \
  "-XX:+UseZGC", \
  "-XX:+ZGenerational", \
  "-Djava.security.egd=file:/dev/./urandom", \
  "-jar", "app.jar"]
