#!/usr/bin/env bash
#
# One-command pseudo-distributed install.
#
#   sudo ./scripts/install-pseudo-distributed.sh
#
# Runs steps 00 through 60 in order, switching to the hadoop user where a step
# must not run as root. Each step is idempotent, so re-running after fixing a
# problem resumes rather than restarts.

source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_linux
require_root "$@"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

as_hadoop() {
  # -H so HOME points at the hadoop user's home, and the environment written by
  # step 40 is actually loaded.
  sudo -H -u "${HADOOP_USER}" \
    env HADOOP_VERSION="${HADOOP_VERSION}" \
        HADOOP_HOME="${HADOOP_HOME}" \
        HADOOP_USER="${HADOOP_USER}" \
        HADOOP_DATA_ROOT="${HADOOP_DATA_ROOT}" \
        FORGE_ASSUME_YES="${FORGE_ASSUME_YES:-0}" \
        bash -lc "$*"
}

heading "hadoop-forge — pseudo-distributed install of Hadoop ${HADOOP_VERSION}"
log "Install prefix : ${HADOOP_HOME}"
log "Service account: ${HADOOP_USER}"
log "Data root      : ${HADOOP_DATA_ROOT}"

# Preflight is read-only and reports as the invoking user, which is fine.
"${SCRIPT_DIR}/00-preflight.sh" || die "Preflight failed"

"${SCRIPT_DIR}/10-install-prerequisites.sh"
"${SCRIPT_DIR}/20-create-hadoop-user.sh"

# SSH keys belong to the service account, not to root.
as_hadoop "'${SCRIPT_DIR}/30-setup-ssh.sh'"

"${SCRIPT_DIR}/40-install-hadoop.sh"
"${SCRIPT_DIR}/50-apply-config.sh" pseudo

as_hadoop "'${SCRIPT_DIR}/60-format-and-start.sh'"

heading "Verifying"
as_hadoop "'${SCRIPT_DIR}/smoke-test.sh'" || warn "Smoke test reported problems — see the output above"

ok "Install finished"
