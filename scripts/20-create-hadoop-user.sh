#!/usr/bin/env bash
#
# 20 — Create the dedicated service account and data directories.
#
#   sudo ./scripts/20-create-hadoop-user.sh
#
# Running Hadoop as root is a genuine anti-pattern: every MapReduce container
# inherits the daemon's identity, so a root NameNode means arbitrary user code
# executing as root on every node in the cluster.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_linux
require_root "$@"

heading "Service account: ${HADOOP_USER}"
if id -u "${HADOOP_USER}" >/dev/null 2>&1; then
  skip "User ${HADOOP_USER} already exists"
else
  # --system would give a shell of /usr/sbin/nologin; the start scripts need a
  # real shell because they SSH in and run commands.
  useradd --create-home --shell /bin/bash --comment "Apache Hadoop service account" "${HADOOP_USER}"
  ok "Created user ${HADOOP_USER}"
fi

if getent group "${HADOOP_GROUP}" >/dev/null 2>&1; then
  skip "Group ${HADOOP_GROUP} already exists"
else
  groupadd "${HADOOP_GROUP}"
  ok "Created group ${HADOOP_GROUP}"
fi
usermod -aG "${HADOOP_GROUP}" "${HADOOP_USER}"

heading "Directories"
dirs=(
  "${HADOOP_DATA_ROOT}/namenode"
  "${HADOOP_DATA_ROOT}/datanode"
  "${HADOOP_DATA_ROOT}/tmp"
  "${HADOOP_DATA_ROOT}/pids"
  "/var/log/hadoop"
  "/var/run/hadoop"
)
for d in "${dirs[@]}"; do
  if [[ -d "$d" ]]; then
    skip "$d exists"
  else
    mkdir -p "$d"
    ok "Created $d"
  fi
  chown -R "${HADOOP_USER}:${HADOOP_GROUP}" "$d"
done

# The NameNode refuses to start if its metadata directory is group- or
# world-writable, so lock the permissions down explicitly.
chmod 0700 "${HADOOP_DATA_ROOT}/namenode"
chmod 0700 "${HADOOP_DATA_ROOT}/datanode"
ok "Tightened permissions on metadata and block directories"

ok "Step 20 complete. Continue as that user: sudo -iu ${HADOOP_USER}"
