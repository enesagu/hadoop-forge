# syntax=docker/dockerfile:1
#
# One image, six roles. Which daemon runs is decided by the entrypoint argument,
# so every container in the cluster shares a layer cache and a single build.

# --------------------------------------------------------------------------
# Stage 1: fetch and verify the distribution
#
# Done in a throwaway stage so neither the 700 MB tarball nor curl ends up in
# the runtime image's layers.
# --------------------------------------------------------------------------
FROM eclipse-temurin:11-jdk-jammy AS fetch

ARG HADOOP_VERSION=3.3.6
ARG HADOOP_MIRROR=https://downloads.apache.org/hadoop/common
ARG HADOOP_ARCHIVE_MIRROR=https://archive.apache.org/dist/hadoop/common

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/fetch

# Verify before unpacking: this tarball's shell scripts run as the service
# account in every container of the cluster.
RUN set -eux; \
    tarball="hadoop-${HADOOP_VERSION}.tar.gz"; \
    path="hadoop-${HADOOP_VERSION}/${tarball}"; \
    curl -fL --retry 3 -o "${tarball}"        "${HADOOP_MIRROR}/${path}" \
      || curl -fL --retry 3 -o "${tarball}"   "${HADOOP_ARCHIVE_MIRROR}/${path}"; \
    curl -fL --retry 3 -o "${tarball}.sha512" "${HADOOP_MIRROR}/${path}.sha512" \
      || curl -fL --retry 3 -o "${tarball}.sha512" "${HADOOP_ARCHIVE_MIRROR}/${path}.sha512"; \
    expected="$(tr -d '\n' < "${tarball}.sha512" | sed -E 's/.*=[[:space:]]*//' | tr -d '[:space:]' | tr 'A-Z' 'a-z')"; \
    case "${#expected}" in 128) ;; *) expected="$(awk '{print tolower($1)}' "${tarball}.sha512" | head -n1)" ;; esac; \
    actual="$(sha512sum "${tarball}" | awk '{print tolower($1)}')"; \
    [ "${expected}" = "${actual}" ] || { echo "checksum mismatch: ${actual} != ${expected}" >&2; exit 1; }; \
    mkdir -p /opt/hadoop; \
    tar -xzf "${tarball}" --strip-components=1 -C /opt/hadoop; \
    rm -rf /opt/hadoop/share/doc

# --------------------------------------------------------------------------
# Stage 2: runtime
# --------------------------------------------------------------------------
FROM eclipse-temurin:11-jdk-jammy

ARG HADOOP_VERSION=3.3.6

LABEL org.opencontainers.image.title="hadoop-forge" \
      org.opencontainers.image.description="Apache Hadoop ${HADOOP_VERSION} — HDFS, YARN and MapReduce in one multi-role image" \
      org.opencontainers.image.source="https://github.com/enesagu/hadoop-forge" \
      org.opencontainers.image.licenses="MIT"

# curl      — container healthchecks hit the daemon web UIs
# libsnappy — native codec for shuffle compression
# procps    — ps/jps for triage inside a running container
# gosu      — clean privilege drop to the service account
#
# Deliberately no interpreter: the entrypoint's configuration templating is awk,
# so nothing here can fail to import at container startup.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      curl libsnappy1v5 procps gosu net-tools less \
 && rm -rf /var/lib/apt/lists/*

ENV HADOOP_VERSION=${HADOOP_VERSION} \
    HADOOP_HOME=/opt/hadoop \
    HADOOP_CONF_DIR=/opt/hadoop/etc/hadoop \
    HADOOP_LOG_DIR=/opt/hadoop/logs \
    HADOOP_DATA_DIR=/hadoop/data \
    JAVA_HOME=/opt/java/openjdk \
    PATH=/opt/hadoop/bin:/opt/hadoop/sbin:/opt/java/openjdk/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY --from=fetch /opt/hadoop /opt/hadoop

# UID 1000 so files written into bind-mounted host directories are owned by the
# typical first non-root account on the host.
RUN groupadd -g 1000 hadoop \
 && useradd -u 1000 -g hadoop -d /home/hadoop -m -s /bin/bash hadoop \
 && mkdir -p "${HADOOP_LOG_DIR}" "${HADOOP_DATA_DIR}" \
 && chown -R hadoop:hadoop /opt/hadoop /hadoop

COPY --chmod=0755 docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chown=hadoop:hadoop conf/docker/ /opt/hadoop/etc/hadoop/

WORKDIR /home/hadoop
USER hadoop

# HDFS: 9000 RPC, 9870 NN UI, 9864 DN UI, 9866 DN data transfer
# YARN: 8088 RM UI, 8032 RM scheduler, 8042 NM UI, 19888 JobHistory UI
EXPOSE 9000 9870 9864 9866 8088 8032 8042 19888

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["gateway"]
