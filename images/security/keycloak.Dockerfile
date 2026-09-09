# Preserve Keycloak 26.7.3 and its database schema.
FROM quay.io/keycloak/keycloak@sha256:ff4257d0d64efbe99ed1ddfaf07765cc3c36dc7518bf8324d41961327f441c54 AS vendor
FROM cgr.dev/chainguard/wolfi-base@sha256:918a593b8268c222afd4e2c4f06860ac984e60719b4697e4c71d796bc8fcd042 AS libraries
RUN apk add --no-cache python3 ca-certificates
COPY --from=vendor /opt/keycloak/ /opt/keycloak/
COPY keycloak-libraries.py keycloak-maven-lock.json /build/
RUN python3 /build/keycloak-libraries.py --root /opt/keycloak --lock /build/keycloak-maven-lock.json

FROM cgr.dev/chainguard/wolfi-base@sha256:918a593b8268c222afd4e2c4f06860ac984e60719b4697e4c71d796bc8fcd042
RUN apk upgrade --no-cache \
    && apk add --no-cache openjdk-25 bash curl tzdata ca-certificates libstdc++ \
    && addgroup -g 10001 keycloak && adduser -D -u 10001 -G keycloak keycloak
COPY --from=libraries --chown=10001:10001 /opt/keycloak/ /opt/keycloak/
COPY --chown=10001:10001 keycloak-tests/KeycloakLibraryTest.java /tmp/KeycloakLibraryTest.java
ENV JAVA_HOME=/usr/lib/jvm/java-25-openjdk LANG=C.UTF-8
ENV PATH=/usr/lib/jvm/java-25-openjdk/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
USER 10001:10001
WORKDIR /opt/keycloak
# Build-time options match the platform. Runtime database credentials and realm
# imports are supplied by Kubernetes; none are present in this build.
RUN KC_DB=postgres KC_HEALTH_ENABLED=true KC_METRICS_ENABLED=true KC_HTTP_RELATIVE_PATH=/auth /opt/keycloak/bin/kc.sh build \
    && library_classpath=/tmp \
    && for library in /opt/keycloak/lib/lib/main/io.netty.*.jar \
         /opt/keycloak/lib/lib/main/io.opentelemetry.opentelemetry-api-[0-9]*.jar \
         /opt/keycloak/lib/lib/main/io.opentelemetry.opentelemetry-context-*.jar \
         /opt/keycloak/lib/lib/main/io.opentelemetry.opentelemetry-common-*.jar \
         /opt/keycloak/lib/lib/main/com.microsoft.sqlserver.mssql-jdbc-*.jar; do \
         library_classpath="$library_classpath:$library"; \
       done \
    && javac -d /tmp -cp "$library_classpath" /tmp/KeycloakLibraryTest.java \
    && java -cp "$library_classpath" KeycloakLibraryTest \
    && rm /tmp/KeycloakLibraryTest.java /tmp/KeycloakLibraryTest*.class
EXPOSE 8080 9000
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
CMD ["start", "--optimized", "--import-realm"]
