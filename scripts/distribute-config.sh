#!/usr/bin/env bash
#
# Push $HADOOP_HOME/etc/hadoop to every worker.
#
#   ./scripts/distribute-config.sh                # hosts from the workers file
#   ./scripts/distribute-config.sh worker1 worker2
#   ./scripts/distribute-config.sh --check        # report drift, change nothing
#
# Fine for a handful of nodes. Past roughly ten, configuration belongs in
# Ansible/Puppet/Chef with the cluster config in version control and rollout
# gated on review — hand-run rsync is how two nodes end up with a different
# dfs.replication than the rest and nobody notices for a month.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_cmd rsync ssh

CONF_DIR="${HADOOP_CONF_DIR:-${HADOOP_HOME}/etc/hadoop}"
CHECK_ONLY=0

args=()
for a in "$@"; do
  case "$a" in
    --check|-n) CHECK_ONLY=1 ;;
    -h|--help)  sed -n '2,14p' "$0"; exit 0 ;;
    *)          args+=("$a") ;;
  esac
done

[[ -d "${CONF_DIR}" ]] || die "No configuration directory at ${CONF_DIR}"

if (( ${#args[@]} > 0 )); then
  WORKERS=("${args[@]}")
else
  [[ -f "${CONF_DIR}/workers" ]] || die "No workers file at ${CONF_DIR}/workers and no hosts given"
  mapfile -t WORKERS < <(grep -vE '^\s*(#|$)' "${CONF_DIR}/workers")
fi

(( ${#WORKERS[@]} > 0 )) || die "No worker hosts to sync"
log "Targets: ${WORKERS[*]}"

RSYNC_OPTS=(--archive --compress --delete --human-readable
            --itemize-changes
            # Never ship machine-local state to another machine.
            --exclude='*.bak.*' --exclude='*.pid' --exclude='*.log')
(( CHECK_ONLY == 1 )) && RSYNC_OPTS+=(--dry-run)

failed=()
for w in "${WORKERS[@]}"; do
  heading "${w}"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "${HADOOP_USER}@${w}" true 2>/dev/null; then
    err "${w} unreachable over passwordless SSH"
    failed+=("${w}")
    continue
  fi

  # Trailing slashes matter: copy the *contents* of CONF_DIR into the remote
  # CONF_DIR, not the directory itself into it.
  if rsync "${RSYNC_OPTS[@]}" "${CONF_DIR}/" "${HADOOP_USER}@${w}:${CONF_DIR}/"; then
    (( CHECK_ONLY == 1 )) && ok "${w}: drift listed above" || ok "${w}: synchronised"
  else
    err "${w}: rsync failed"
    failed+=("${w}")
  fi
done

if (( ${#failed[@]} > 0 )); then
  die "Failed on: ${failed[*]}"
fi

if (( CHECK_ONLY == 0 )); then
  cat <<EOF

$( ok "Configuration distributed" )

Most parameters are read once at daemon startup, so a sync alone changes
nothing. Depending on what you edited:

  hdfs dfsadmin -refreshNodes     include/exclude host lists
  yarn rmadmin -refreshQueues     capacity-scheduler.xml
  rolling restart                 heap sizes, directories, ports
EOF
fi
