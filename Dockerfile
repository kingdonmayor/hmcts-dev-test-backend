# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# First stage — building the JDK, Gradle distribution and the whole dependency
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jdk-jammy AS builder

WORKDIR /workspace

# Copy the wrapper and build definition
COPY gradlew ./
COPY gradle/ gradle/
COPY build.gradle ./
COPY config/ config/

RUN chmod +x ./gradlew \
    && ./gradlew --no-daemon --console=plain dependencies --configuration runtimeClasspath > /dev/null

# Source changes invalidate only the layers from here down.
COPY src/ src/

# The tests will run in CI as a separate reported stage; making the image lean and build faster
RUN ./gradlew --no-daemon --console=plain bootJar -x test

# ---------------------------------------------------------------------------
# The second stage — runtime. runs JRE only with no build tooling, no source and runs unprivileged.
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jre-jammy AS runtime

# curl is needed for the container HEALTHCHECK below.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

# Dedicated unprivileged account.
RUN groupadd --system --gid 1001 spring \
    && useradd --system --uid 1001 --gid spring --no-create-home spring

WORKDIR /opt/app

COPY --from=builder --chown=spring:spring /workspace/build/libs/test-backend.jar app.jar

USER spring:spring

ENV SERVER_PORT=4000 \
    JAVA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:+UseContainerSupport"

EXPOSE 4000

# /health probe returns UP only when the datasource is reachable
HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=5 \
    CMD curl --fail --silent http://localhost:${SERVER_PORT}/health || exit 1

ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /opt/app/app.jar"]
