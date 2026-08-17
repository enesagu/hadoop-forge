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
#
# Implemented in awk rather than with an XML parser on purpose. The runtime image
# carries no interpreter beyond the shell's own toolchain, and adding one so that
# a container can edit four lines of XML is a dependency that fails at startup —
# the worst possible place. Hadoop's configuration format is regular enough that
# substring matching is sufficient.
#
# Limitation: single-line <name>/<value> pairs only, which is what every file in
# conf/docker uses.
# --------------------------------------------------------------------------

# Set one property in one file, replacing the existing value or appending a new
# <property> block before </configuration>.
set_property() {
  local file="$1" key="$2" value="$3"

  [[ -f "$file" ]] || die "no such configuration file: ${file}"

  awk -v key="$key" -v value="$value" '
    { line[++n] = $0 }
    END {
      target = 0
      for (i = 1; i <= n; i++) {
        # index() not a regex: a key such as dfs.replication would otherwise
        # have its dots match any character.
        if (index(line[i], "<name>" key "</name>") > 0) { target = i; break }
      }

      if (target > 0) {
        for (i = target + 1; i <= n; i++) {
          p = index(line[i], "<value>")
          q = index(line[i], "</value>")
          if (p > 0 && q > p) {
            # Rebuilt by position rather than with sub(), whose replacement
            # text treats & as "the whole match".
            line[i] = substr(line[i], 1, p + 6) value substr(line[i], q)
            break
          }
        }
        for (i = 1; i <= n; i++) print line[i]
      } else {
        for (i = 1; i <= n; i++) {
          if (index(line[i], "</configuration>") > 0) {
            print "  <property>"
            print "    <name>" key "</name>"
            print "    <value>" value "</value>"
            print "  </property>"
          }
          print line[i]
        }
      }
    }
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

apply_conf_overrides() {
  [[ -n "${HADOOP_CONF_OVERRIDES:-}" ]] || return 0
  log "Applying configuration overrides"

  local raw filename kv key value
  while IFS= read -r raw; do
    # Trim, then skip blanks and comments.
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    [[ -z "$raw" || "$raw" == \#* ]] && continue

    [[ "$raw" == *:*=* ]] || die "malformed override (expected file.xml:key=value): ${raw}"
    filename="${raw%%:*}"
    kv="${raw#*:}"
    key="${kv%%=*}"
    value="${kv#*=}"

    set_property "${HADOOP_CONF_DIR}/${filename}" "$key" "$value"
    log "  ${filename}: ${key} = ${value}"
  done <<< "${HADOOP_CONF_OVERRIDES}"
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
