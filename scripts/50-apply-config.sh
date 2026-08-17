#!/usr/bin/env bash
#
# 50 — Install a configuration set into $HADOOP_HOME/etc/hadoop.
#
#   sudo ./scripts/50-apply-config.sh pseudo|cluster|ha
#
# Sets are copied whole, never merged: mixing a pseudo hdfs-site.xml with a
# cluster core-site.xml produces a cluster that half-works, which is worse than
# one that does not start.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_linux
require_root "$@"

PROFILE="${1:-}"
case "${PROFILE}" in
  pseudo|cluster|ha) ;;
  *) die "Usage: $0 pseudo|cluster|ha" ;;
esac

SRC="${REPO_ROOT}/conf/${PROFILE}"
DST="${HADOOP_HOME}/etc/hadoop"

[[ -d "${SRC}" ]] || die "No such configuration set: ${SRC}"
[[ -d "${DST}" ]] || die "${DST} not found — run scripts/40-install-hadoop.sh first"

heading "Backing up the current configuration"
backup="${DST}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "${DST}" "${backup}"
ok "Previous configuration saved to ${backup}"

heading "Applying the '${PROFILE}' set"
# The 'ha' set is an overlay on 'cluster': it replaces core-site and hdfs-site
# and adds the ZooKeeper/JournalNode wiring, but reuses the cluster's YARN and
# MapReduce sizing.
if [[ "${PROFILE}" == "ha" ]]; then
  log "HA is an overlay — installing the cluster set first"
  for f in "${REPO_ROOT}/conf/cluster"/*; do
    install -m 0644 -o "${HADOOP_USER}" -g "${HADOOP_GROUP}" "$f" "${DST}/$(basename "$f")"
  done
fi

for f in "${SRC}"/*; do
  name="$(basename "$f")"
  [[ "${name}" == "README.md" ]] && continue
  case "${name}" in
    *.sh) mode=0755 ;;
    *)    mode=0644 ;;
  esac
  install -m "${mode}" -o "${HADOOP_USER}" -g "${HADOOP_GROUP}" "$f" "${DST}/${name}"
  ok "${name}"
done

heading "Substituting JAVA_HOME"
java_home="$(detect_java_home)" || die "Could not resolve JAVA_HOME"
# hadoop-env.sh defaults JAVA_HOME with ${JAVA_HOME:-...}; pin the fallback to
# the path that actually exists on this machine.
sed -i -E "s#(JAVA_HOME:-)[^}]*#\1${java_home}#" "${DST}/hadoop-env.sh"
ok "hadoop-env.sh pinned to ${java_home}"

heading "Validating XML"
if command -v xmllint >/dev/null 2>&1; then
  for f in "${DST}"/*-site.xml "${DST}"/capacity-scheduler.xml; do
    [[ -f "$f" ]] || continue
    xmllint --noout "$f" || die "Malformed XML: $f"
    ok "$(basename "$f") is well-formed"
  done
else
  warn "xmllint not installed — skipping XML validation (apt-get install libxml2-utils)"
fi

# A duplicated <name> silently wins or loses depending on parse order, which is
# a miserable class of bug to chase in a running cluster.
heading "Checking for duplicate properties"
for f in "${DST}"/*-site.xml; do
  [[ -f "$f" ]] || continue
  # sed, not grep -oP: PCRE is a GNU extension and refuses to run under some
  # locales, which is a poor reason for an installer to fail on a fresh host.
  dupes="$(sed -n 's/.*<name>\([^<]*\)<\/name>.*/\1/p' "$f" | sort | uniq -d)"
  if [[ -n "${dupes}" ]]; then
    err "Duplicate properties in $(basename "$f"):"
    printf '  %s\n' "${dupes}" >&2
    die "Remove the duplicates before starting the cluster"
  fi
done
ok "No duplicate properties"

ok "Step 50 complete. Next: sudo -iu ${HADOOP_USER} ${REPO_ROOT}/scripts/60-format-and-start.sh"
