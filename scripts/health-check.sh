#!/usr/bin/env bash
#
# Health report for a running cluster.
#
#   ./scripts/health-check.sh          # bare metal, as the hadoop user
#   make health                        # inside the containerised cluster
#
# Read-only. Exit code 0 = healthy, 1 = at least one FAIL, 2 = warnings only.
#
# Ordered the way you would triage by hand: can I reach the NameNode, is it
# accepting writes, are the blocks intact, are the workers alive, is YARN able to
# schedule anything.

set -uo pipefail

HADOOP_HOME="${HADOOP_HOME:-/opt/hadoop}"
PATH="${HADOOP_HOME}/bin:${HADOOP_HOME}/sbin:${PATH}"
export PATH

if [[ -t 1 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; Z=$'\033[0m'
else
  R=''; G=''; Y=''; B=''; Z=''
fi

FAILS=0
WARNS=0

section() { printf '\n%s── %s %s\n' "$B" "$*" "$Z"; }
pass()    { printf '  %s✓%s %s\n' "$G" "$Z" "$*"; }
warn()    { printf '  %s!%s %s\n' "$Y" "$Z" "$*"; WARNS=$((WARNS + 1)); }
fail()    { printf '  %s✗%s %s\n' "$R" "$Z" "$*"; FAILS=$((FAILS + 1)); }
info()    { printf '    %s\n' "$*"; }

printf '%shadoop-forge health check — %s%s\n' "$B" "$(date -Is)" "$Z"

# ---------------------------------------------------------------------------
section "Client configuration"
if ! command -v hdfs >/dev/null 2>&1; then
  fail "hdfs is not on PATH (HADOOP_HOME=${HADOOP_HOME})"
  printf '\nCannot continue without the Hadoop client.\n'
  exit 1
fi
DEFAULT_FS="$(hdfs getconf -confKey fs.defaultFS 2>/dev/null || echo unknown)"
pass "fs.defaultFS = ${DEFAULT_FS}"
info "Hadoop $(hadoop version 2>/dev/null | head -n1 | awk '{print $2}')"

# ---------------------------------------------------------------------------
section "Local daemons"
if command -v jps >/dev/null 2>&1; then
  RUNNING="$(jps -l 2>/dev/null || true)"
  # Only report what should be here. In the containerised topology each daemon
  # lives in its own container, so an absent NameNode locally is expected.
  for daemon in NameNode DataNode SecondaryNameNode ResourceManager NodeManager JobHistoryServer; do
    if grep -q "\.${daemon}\$\|\.${daemon} " <<<"${RUNNING}"; then
      pass "${daemon} running"
    else
      info "${daemon} not in this JVM namespace (expected if it runs elsewhere)"
    fi
  done
else
  warn "jps unavailable — skipping local process check"
fi

# ---------------------------------------------------------------------------
section "HDFS availability"
if ! hdfs dfs -ls / >/dev/null 2>&1; then
  fail "Cannot list / — the NameNode is unreachable at ${DEFAULT_FS}"
  info "Check the NameNode is running and that fs.defaultFS matches its address"
else
  pass "NameNode is answering client RPC"

  SAFEMODE="$(hdfs dfsadmin -safemode get 2>/dev/null | head -n1)"
  case "${SAFEMODE}" in
    *OFF*) pass "Safe mode is OFF — writes accepted" ;;
    *ON*)  fail "Safe mode is ON — the filesystem is read-only"
           info "At startup this clears itself once enough block reports arrive."
           info "If it persists, DataNodes are not registering. Force it only when"
           info "you know why: hdfs dfsadmin -safemode leave" ;;
    *)     warn "Could not determine safe mode state" ;;
  esac
fi

# ---------------------------------------------------------------------------
section "Capacity"
REPORT="$(hdfs dfsadmin -report 2>/dev/null || true)"
if [[ -n "${REPORT}" ]]; then
  CONFIGURED="$(awk -F': ' '/^Configured Capacity/ {print $2; exit}' <<<"${REPORT}")"
  USED_PCT="$(awk -F': ' '/^DFS Used%/ {gsub(/%/,"",$2); print $2; exit}' <<<"${REPORT}")"
  info "Configured capacity: ${CONFIGURED:-unknown}"

  if [[ -n "${USED_PCT}" ]]; then
    # awk rather than bash arithmetic: DFS Used% is a decimal.
    verdict="$(awk -v p="${USED_PCT}" 'BEGIN {print (p>90)?"fail":((p>75)?"warn":"pass")}')"
    case "${verdict}" in
      pass) pass "DFS used ${USED_PCT}%" ;;
      warn) warn "DFS used ${USED_PCT}% — plan capacity before it becomes urgent" ;;
      fail) fail "DFS used ${USED_PCT}% — writes will start failing"
            info "dfs.datanode.du.reserved protects the OS but not the cluster" ;;
    esac
  fi

  LIVE="$(awk -F': ' '/^Live datanodes/ {gsub(/[^0-9]/,"",$1$2); print $0; exit}' <<<"${REPORT}" \
          | grep -oP '\(\K[0-9]+' || echo 0)"
  DEAD="$(awk -F': ' '/^Dead datanodes/ {print $0; exit}' <<<"${REPORT}" \
          | grep -oP '\(\K[0-9]+' || echo 0)"
  if (( LIVE > 0 )); then
    pass "${LIVE} live DataNode(s)"
  else
    fail "No live DataNodes — HDFS cannot store anything"
  fi
  if (( DEAD > 0 )); then
    fail "${DEAD} dead DataNode(s)"
    info "The NameNode declares a node dead after ~10.5 minutes of missed heartbeats"
    info "and starts re-replicating its blocks. Expect elevated network traffic."
  fi

  # Rack topology left at the default silently costs rack-failure tolerance.
  if grep -q 'Rack: /default-rack' <<<"${REPORT}"; then
    warn "Some DataNodes report /default-rack"
    info "Replica placement degrades to 'any N nodes' — configure"
    info "net.topology.script.file.name to regain rack-failure tolerance"
  fi
else
  warn "dfsadmin -report returned nothing"
fi

# ---------------------------------------------------------------------------
section "Block health"
FSCK="$(hdfs fsck / 2>/dev/null || true)"
if [[ -n "${FSCK}" ]]; then
  if grep -q 'Status: HEALTHY' <<<"${FSCK}"; then
    pass "fsck / reports HEALTHY"
  elif grep -q 'Status: CORRUPT' <<<"${FSCK}"; then
    fail "fsck / reports CORRUPT"
    info "List the damage: hdfs fsck / -list-corruptfileblocks"
  fi

  for metric in "Under-replicated blocks" "Missing blocks" "Corrupt blocks"; do
    value="$(grep -oP "${metric}:\s*\K[0-9]+" <<<"${FSCK}" | head -n1 || true)"
    [[ -z "${value}" ]] && continue
    if (( value == 0 )); then
      pass "${metric}: 0"
    elif [[ "${metric}" == "Under-replicated blocks" ]]; then
      warn "${metric}: ${value}"
      info "Normal transiently after a node loss or a setrep. Persistent means"
      info "there are fewer live nodes than dfs.replication requires."
    else
      fail "${metric}: ${value} — this is data loss"
    fi
  done
else
  warn "fsck produced no output"
fi

# ---------------------------------------------------------------------------
section "YARN"
if ! command -v yarn >/dev/null 2>&1; then
  warn "yarn is not on PATH — skipping"
elif ! NODES="$(yarn node -list -all 2>/dev/null)"; then
  fail "Cannot reach the ResourceManager"
  info "Check yarn.resourcemanager.hostname and that the RM is running"
else
  RUNNING_NM="$(grep -c 'RUNNING' <<<"${NODES}" || true)"
  UNHEALTHY_NM="$(grep -c 'UNHEALTHY' <<<"${NODES}" || true)"
  LOST_NM="$(grep -c 'LOST' <<<"${NODES}" || true)"

  if (( RUNNING_NM > 0 )); then
    pass "${RUNNING_NM} NodeManager(s) RUNNING"
  else
    fail "No RUNNING NodeManagers — nothing can be scheduled"
  fi
  (( UNHEALTHY_NM > 0 )) && {
    fail "${UNHEALTHY_NM} NodeManager(s) UNHEALTHY"
    info "Almost always disk utilisation past"
    info "yarn.nodemanager.disk-health-checker.max-disk-utilization-per-disk-percentage"
  }
  (( LOST_NM > 0 )) && fail "${LOST_NM} NodeManager(s) LOST"

  METRICS="$(yarn top -help >/dev/null 2>&1 && echo ok || echo skip)"
  if [[ "${METRICS}" == "ok" ]]; then
    PENDING="$(yarn application -list -appStates ACCEPTED 2>/dev/null | grep -c 'application_' || true)"
    if (( PENDING > 0 )); then
      warn "${PENDING} application(s) stuck in ACCEPTED"
      info "The scheduler cannot satisfy the container request. Compare"
      info "mapreduce.map.memory.mb against yarn.nodemanager.resource.memory-mb,"
      info "and check the queue's maximum-am-resource-percent."
    else
      pass "No applications waiting in ACCEPTED"
    fi
  fi
fi

# ---------------------------------------------------------------------------
section "Summary"
if (( FAILS > 0 )); then
  printf '  %s%d failure(s), %d warning(s)%s\n\n' "$R" "$FAILS" "$WARNS" "$Z"
  exit 1
elif (( WARNS > 0 )); then
  printf '  %s%d warning(s), no failures%s\n\n' "$Y" "$WARNS" "$Z"
  exit 2
fi
printf '  %sCluster is healthy%s\n\n' "$G" "$Z"
