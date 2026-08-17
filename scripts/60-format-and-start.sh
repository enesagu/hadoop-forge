#!/usr/bin/env bash
#
# 60 — Format the NameNode (first run only) and start the daemons.
#
#   sudo -iu hadoop /path/to/scripts/60-format-and-start.sh
#
# `hdfs namenode -format` destroys the namespace. Without the namespace, the
# blocks sitting on the DataNodes are unreachable bytes — formatting a populated
# cluster is effectively deleting it. This script therefore refuses to format
# over existing metadata unless FORGE_FORCE_FORMAT=1 is set explicitly.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

refuse_root

export HADOOP_HOME="${HADOOP_HOME}"
export HADOOP_CONF_DIR="${HADOOP_CONF_DIR:-${HADOOP_HOME}/etc/hadoop}"
PATH="${HADOOP_HOME}/bin:${HADOOP_HOME}/sbin:${PATH}"
export PATH

require_cmd hdfs yarn jps

NAME_DIR="$(
  hdfs getconf -confKey dfs.namenode.name.dir 2>/dev/null \
    | tr ',' '\n' | head -n1 | sed 's#^file://##'
)"
[[ -n "${NAME_DIR}" ]] || die "Could not read dfs.namenode.name.dir from the configuration"
log "NameNode metadata directory: ${NAME_DIR}"

heading "Formatting the NameNode"
if [[ -f "${NAME_DIR}/current/VERSION" ]]; then
  if [[ "${FORGE_FORCE_FORMAT:-0}" == "1" ]]; then
    warn "Existing metadata found and FORGE_FORCE_FORMAT=1 — reformatting"
    warn "Every block already stored becomes unreachable."
    confirm "Really destroy the namespace in ${NAME_DIR}?" || die "Aborted"
    hdfs namenode -format -force -nonInteractive
    ok "NameNode reformatted"
  else
    skip "Namespace already initialised — not reformatting (set FORGE_FORCE_FORMAT=1 to override)"
  fi
else
  hdfs namenode -format -nonInteractive
  ok "NameNode formatted"
fi

heading "Starting HDFS"
start-dfs.sh

heading "Starting YARN"
start-yarn.sh

heading "Starting the JobHistory server"
# Without it, completed applications disappear from the RM UI with
# "The requested application exited too soon" instead of showing counters.
mapred --daemon start historyserver || warn "JobHistory server did not start"

heading "Waiting for HDFS to leave safe mode"
# On startup the NameNode holds writes until enough block reports have arrived.
# Racing it produces confusing "cannot create file" errors in the smoke test.
#
# Bounded, because `-safemode wait` waits forever. If the DataNodes never
# register, an unbounded wait turns a diagnosable failure into a hung terminal.
if timeout 300 hdfs dfsadmin -safemode wait; then
  ok "HDFS is accepting writes"
else
  warn "Still in safe mode after 5 minutes — the DataNodes are not registering"
  log "Check the DataNode log, not the NameNode's: \$HADOOP_LOG_DIR/*datanode*.log"
fi

heading "Running processes"
jps -l | sort

heading "Creating user home directories in HDFS"
# YARN needs /user/<name> to exist to stage job resources; the error when it does
# not is a bare "Permission denied", which sends people down the wrong path.
hdfs dfs -mkdir -p "/user/${USER}"
hdfs dfs -chown "${USER}" "/user/${USER}"
hdfs dfs -mkdir -p /tmp/hadoop-yarn/staging
hdfs dfs -chmod -R 1777 /tmp
ok "HDFS home and staging directories ready"

cat <<EOF

$( ok "Cluster is up" )

  NameNode UI ........ http://localhost:9870
  ResourceManager UI . http://localhost:8088
  JobHistory UI ...... http://localhost:19888

Next:
  ./scripts/health-check.sh     full health report
  ./scripts/smoke-test.sh       end-to-end HDFS + MapReduce verification
EOF
