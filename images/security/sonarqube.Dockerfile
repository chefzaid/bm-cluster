# SonarQube Community 26.8, same application and database version.
# Keep verified dependency bytecode and checksums together when updating.
FROM docker.io/library/sonarqube@sha256:68b6c1924482d0483514b229019718293e421fff1e994d23eb56f3226d11ab70 AS upstream
FROM cgr.dev/chainguard/wolfi-base@sha256:918a593b8268c222afd4e2c4f06860ac984e60719b4697e4c71d796bc8fcd042 AS libraries
RUN apk add --no-cache python3 ca-certificates
COPY --from=upstream /opt/sonarqube/ /opt/sonarqube/
COPY sonarqube-libraries.py sonarqube-maven-lock.json /build/
RUN python3 /build/sonarqube-libraries.py --root /opt/sonarqube --cache /build/maven \
      --lock /build/sonarqube-maven-lock.json

FROM cgr.dev/chainguard/wolfi-base@sha256:918a593b8268c222afd4e2c4f06860ac984e60719b4697e4c71d796bc8fcd042
RUN apk upgrade --no-cache && apk add --no-cache openjdk-25 bash curl unzip tzdata fontconfig freetype libstdc++ openssl ca-certificates \
    && addgroup -g 10001 sonarqube && adduser -D -u 10001 -G sonarqube sonarqube \
    && mkdir -p /opt/java && ln -s /usr/lib/jvm/java-25-openjdk /opt/java/openjdk
COPY --from=libraries --chown=10001:10001 /opt/sonarqube/ /opt/sonarqube/
ENV PATH="/opt/java/openjdk/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV JAVA_HOME="/opt/java/openjdk"
ENV LANG="C.UTF-8"
ENV LANGUAGE="C.UTF-8"
ENV LC_ALL="C.UTF-8"
ENV JAVA_VERSION="25.0.4.1"
ENV DOCKER_RUNNING="true"
ENV SONARQUBE_HOME="/opt/sonarqube"
ENV SONAR_VERSION="26.8.0.126808"
ENV SQ_DATA_DIR="/opt/sonarqube/data"
ENV SQ_EXTENSIONS_DIR="/opt/sonarqube/extensions"
ENV SQ_LOGS_DIR="/opt/sonarqube/logs"
ENV SQ_TEMP_DIR="/opt/sonarqube/temp"
ENV ES_TMPDIR="/opt/sonarqube/temp"
USER 10001:10001
WORKDIR /opt/sonarqube
EXPOSE 9000
VOLUME ["/opt/sonarqube/data", "/opt/sonarqube/extensions", "/opt/sonarqube/logs", "/opt/sonarqube/temp"]
ENTRYPOINT ["/opt/sonarqube/docker/entrypoint.sh"]
STOPSIGNAL SIGINT
