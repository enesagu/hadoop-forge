#!/usr/bin/env bash
#
# Stop the cluster, optionally wiping its data.
#
#   ./scripts/teardown.sh                # stop daemons, keep data
#   ./scripts/teardown.sh --purge-data   # stop daemons AND delete /data/hdfs
#
# Stops in reverse dependency order — YARN first, then HDFS — so running
# applications are not killed by the filesystem vanishing underneath them.

source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

refuse_root

PATH="${HADOOP_HOME}/bin:${HADOOP_HOME}/sbin:${PATH}"
export PATH

PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge-data) PURGE=1 ;;
    -h|--help)    sed -n '2,10p' "$0"; exit 0 ;;
    *)            die "Unknown option: $arg" ;;
  esac
done

heading "Draining YARN"
if command -v yarn >/dev/null 2>&1 && yarn node -list >/dev/null 2>&1; then
  running="$(yarn application -list -appStates RUNNING 2>/dev/null | grep -c 'application_' || true)"
  if (( running > 0 )); then
    warn "${running} application(s) still running; they will be killed by the shutdown"
    confirm "Continue?" || die "Aborted"
  else
    ok "No running applications"
  fi
fi

heading "Stopping the JobHistory server"
mapred --daemon stop historyserver 2>/dev/null && ok "Stopped" || skip "Not running"

heading "Stopping YARN"
if [[ -x "${HADOOP_HOME}/sbin/stop-yarn.sh" ]]; then
  stop-yarn.sh || warn "stop-yarn.sh reported errors"
else
  skip "stop-yarn.sh not found"
fi

heading "Stopping HDFS"
if [[ -x "${HADOOP_HOME}/sbin/stop-dfs.sh" ]]; then
  stop-dfs.sh || warn "stop-dfs.sh reported errors"
else
  skip "stop-dfs.sh not found"
fi

heading "Remaining Hadoop processes"
if command -v jps >/dev/null 2>&1; then
  remaining="$(jps -l | grep -E 'hadoop|hdfs|yarn|mapred' || true)"
  if [[ -n "${remaining}" ]]; then
    warn "Still running:"
    printf '  %s\n' "${remaining}"
    info_pids="$(awk '{print $1}' <<<"${remaining}" | tr '\n' ' ')"
    log "Kill them with: kill ${info_pids}"
  else
    ok "All daemons stopped"
  fi
fi

if (( PURGE == 1 )); then
  heading "Purging data"
  err "This deletes the NameNode namespace and every stored block under ${HADOOP_DATA_ROOT}."
  err "There is no undo, and no trash — the data is gone."
  confirm "Type y to permanently delete ${HADOOP_DATA_ROOT}" || die "Aborted — nothing was deleted"

  for sub in namenode datanode tmp; do
    target="${HADOOP_DATA_ROOT}/${sub}"
    if [[ -d "${target}" ]]; then
      # Delete the contents, not the directory: ownership and the 0700 mode on
      # namenode/ were set up by step 20 and the NameNode depends on them.
      find "${target}" -mindepth 1 -delete 2>/dev/null \
        && ok "Emptied ${target}" \
        || warn "Could not fully empty ${target} (permissions?)"
    fi
  done
  ok "Data purged — the next start needs a fresh format"
  log "Re-run: sudo -iu ${HADOOP_USER} ${REPO_ROOT}/scripts/60-format-and-start.sh"
else
  log "Data kept. Restart with: start-dfs.sh && start-yarn.sh"
fi

ok "Teardown complete"
