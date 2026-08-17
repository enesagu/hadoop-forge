#!/usr/bin/env bash
#
# Role dispatcher for the hadoop-forge image.
#
#   entrypoint.sh namenode | datanode | resourcemanager | nodemanager
#                 | historyserver | gateway | <any command>
#
# Every daemon runs in the FOREGROUND. Docker's process supervision only works
# if PID 1 is the thing being supervised — `hdfs --daemon start namenode`
# forks and exits, so the container would report healthy while holding nothing.

set -euo pipefail

ROLE="${1:-gateway}"
shift || true

log()  { printf '[entrypoint] %s\n' "$*"; }
die()  { printf '[entrypoint] FATAL: %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# Configuration overrides
#
# HADOOP_CONF_OVERRIDES lets a Compose file retune the cluster without a second
# copy of the XML — e.g. the single-node topology setting dfs.replication=1:
#
#   HADOOP_CONF_OVERRIDES: |
#     hdfs-site.xml:dfs.replication=1
#     yarn-site.xml:yarn.nodemanager.resource.memory-mb=4096
# --------------------------------------------------------------------------
apply_conf_overrides() {
  [[ -n "${HADOOP_CONF_OVERRIDES:-}" ]] || return 0
  log "Applying configuration overrides"
  HADOOP_CONF_OVERRIDES="${HADOOP_CONF_OVERRIDES}" \
  HADOOP_CONF_DIR="${HADOOP_CONF_DIR}" python3 - <<'PY'
import os, re, sys
import xml.etree.ElementTree as ET

conf_dir = os.environ["HADOOP_CONF_DIR"]
changes = {}
for raw in os.environ["HADOOP_CONF_OVERRIDES"].splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if ":" not in line or "=" not in line:
        sys.exit(f"malformed override (expected file.xml:key=value): {line!r}")
    filename, kv = line.split(":", 1)
    key, value = kv.split("=", 1)
    changes.setdefault(filename.strip(), []).append((key.strip(), value.strip()))

for filename, pairs in changes.items():
    path = os.path.join(conf_dir, filename)
    tree = ET.parse(path)
    root = tree.getroot()
    for key, value in pairs:
        for prop in root.findall("property"):
            name = prop.find("name")
            if name is not None and name.text == key:
                prop.find("value").text = value
                break
        else:
            prop = ET.SubElement(root, "property")
            ET.SubElement(prop, "name").text = key
            ET.SubElement(prop, "value").text = value
        print(f"[entrypoint]   {filename}: {key} = {value}")
    tree.write(path, encoding="utf-8", xml_declaration=True)
PY
}

# --------------------------------------------------------------------------
# Startup ordering
#
# Compose `depends_on` waits for a container to start, not for a daemon to be
# ready. A DataNode that starts before the NameNode's RPC port is listening
# retries with backoff and eventually gives up, so wait explicitly.
# --------------------------------------------------------------------------
wait_for_port() {
  local host="$1" port="$2" timeout="${3:-120}" waited=0
  log "Waiting for ${host}:${port} (timeout ${timeout}s)"
  until (echo > "/dev/tcp/${host}/${port}") >/dev/null 2>&1; do
    sleep 2
    waited=$((waited + 2))
    (( waited >= timeout )) && die "${host}:${port} did not become reachable within ${timeout}s"
  done
  log "${host}:${port} is reachable"
}

ensure_dir() {
  mkdir -p "$1"
  # A DataNode refuses to use a directory whose permissions are looser than
  # dfs.datanode.data.dir.perm (default 700).
  chmod "${2:-0755}" "$1"
}

# --------------------------------------------------------------------------
# Roles
# --------------------------------------------------------------------------
start_namenode() {
  local name_dir="${HADOOP_DATA_DIR}/namenode"
  ensure_dir "${name_dir}" 0700
  ensure_dir "${HADOOP_DATA_DIR}/tmp"

  if [[ -f "${name_dir}/current/VERSION" ]]; then
    log "Namespace already initialised — not formatting"
  else
    log "Empty metadata directory: formatting a fresh namespace"
    hdfs namenode -format -force -nonInteractive -clusterId "${CLUSTER_ID:-hadoop-forge}"
  fi

  # Bootstrap the directories YARN and the JobHistory server need, in the
  # background, once the NameNode is serving. Doing it here rather than in the
  # historyserver container means it happens exactly once.
  (
    wait_for_port localhost 9000 180
    hdfs dfsadmin -safemode wait >/dev/null
    hdfs dfs -mkdir -p /tmp /user/hadoop /mr-history/tmp /mr-history/done /app-logs
    hdfs dfs -chmod -R 1777 /tmp /mr-history
    hdfs dfs -chmod -R 1777 /app-logs
    log "HDFS bootstrap directories ready"
  ) &

  exec hdfs namenode
}

start_datanode() {
  ensure_dir "${HADOOP_DATA_DIR}/datanode" 0700
  wait_for_port "${NAMENODE_HOST:-namenode}" 9000
  exec hdfs datanode
}

start_resourcemanager() {
  wait_for_port "${NAMENODE_HOST:-namenode}" 9000
  exec yarn resourcemanager
}

start_nodemanager() {
  ensure_dir "${HADOOP_DATA_DIR}/yarn/local"
  ensure_dir "${HADOOP_DATA_DIR}/yarn/log"
  wait_for_port "${RESOURCEMANAGER_HOST:-resourcemanager}" 8032
  exec yarn nodemanager
}

start_historyserver() {
  wait_for_port "${NAMENODE_HOST:-namenode}" 9000
  # The NameNode creates /mr-history; give that bootstrap a moment to land
  # rather than crash-looping on a missing directory.
  until hdfs dfs -test -d /mr-history/done 2>/dev/null; do
    log "Waiting for /mr-history/done in HDFS"
    sleep 3
  done
  exec mapred historyserver
}

start_gateway() {
  # A client container with the cluster configuration and no daemon, for
  # `docker compose exec gateway hdfs dfs -ls /`.
  log "Gateway ready — exec into this container to run client commands"
  exec tail -f /dev/null
}

# --------------------------------------------------------------------------
main() {
  apply_conf_overrides

  case "${ROLE}" in
    namenode)        start_namenode ;;
    datanode)        start_datanode ;;
    resourcemanager) start_resourcemanager ;;
    nodemanager)     start_nodemanager ;;
    historyserver)   start_historyserver ;;
    gateway)         start_gateway ;;
    *)               log "Executing: ${ROLE} $*"; exec "${ROLE}" "$@" ;;
  esac
}

main "$@"
