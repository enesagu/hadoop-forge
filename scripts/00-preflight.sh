#!/usr/bin/env bash
#
# 00 — Preflight checks.
#
# Read-only. Reports everything that would make the install fail later, rather
# than failing halfway through step 40 with a half-configured machine.
#
#   ./scripts/00-preflight.sh

# shellcheck source=scripts/lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_linux

FAILURES=0
fail_check() { err "$*"; FAILURES=$((FAILURES + 1)); }

heading "Operating system"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  log "Detected: ${PRETTY_NAME:-unknown}"
  case "${ID:-}" in
    ubuntu|debian) ok "Debian-family: apt-based steps apply" ;;
    rhel|centos|rocky|almalinux) warn "RHEL-family: step 10 uses apt — install the equivalents with dnf" ;;
    *) warn "Untested distribution; the installers assume Ubuntu 22.04 LTS" ;;
  esac
else
  warn "Cannot read /etc/os-release"
fi

heading "Java"
if command -v java >/dev/null 2>&1; then
  major="$(java_major_version)"
  log "java -version reports major ${major}"
  if [[ "$major" == "8" || "$major" == "11" ]]; then
    ok "Hadoop ${HADOOP_VERSION} supports JDK ${major}"
  else
    fail_check "JDK ${major} is not a supported runtime for Hadoop ${HADOOP_VERSION}; install JDK 11"
  fi
  if jh="$(detect_java_home)"; then
    ok "JAVA_HOME resolves to ${jh}"
  else
    fail_check "Could not resolve JAVA_HOME from the java binary"
  fi
else
  warn "Java is not installed — step 10 installs ${JAVA_PACKAGE}"
fi

heading "Memory"
if [[ -r /proc/meminfo ]]; then
  total_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  total_gb=$(( total_kb / 1024 / 1024 ))
  log "Total RAM: ${total_gb} GB"
  if (( total_gb < 4 )); then
    fail_check "Under 4 GB of RAM. NameNode, DataNode, ResourceManager and NodeManager JVMs plus one container will not fit"
  elif (( total_gb < 8 )); then
    warn "${total_gb} GB works but leaves little headroom; lower yarn.nodemanager.resource.memory-mb accordingly"
  else
    ok "Sufficient RAM"
  fi
fi

heading "Disk"
target_fs="$(df -Pk / | awk 'NR==2 {print $4}')"
avail_gb=$(( target_fs / 1024 / 1024 ))
log "Available on /: ${avail_gb} GB"
if (( avail_gb < 10 )); then
  fail_check "Under 10 GB free. The distribution tarball alone is ~700 MB and HDFS needs room for blocks"
else
  ok "Sufficient disk"
fi

heading "Required commands"
for cmd in curl tar ssh sha512sum awk sed; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd"
  else
    warn "$cmd missing — step 10 installs it"
  fi
done

heading "Port availability"
# NameNode RPC / NameNode UI / DataNode / SecondaryNN / RM UI / JobHistory UI
declare -A PORTS=(
  [9000]="NameNode RPC"
  [9870]="NameNode web UI"
  [9864]="DataNode web UI"
  [9868]="Secondary NameNode"
  [8088]="ResourceManager web UI"
  [8042]="NodeManager web UI"
  [19888]="JobHistory web UI"
)
for port in "${!PORTS[@]}"; do
  if port_in_use "$port"; then
    fail_check "Port ${port} (${PORTS[$port]}) is already in use"
  else
    ok "Port ${port} free (${PORTS[$port]})"
  fi
done

heading "Localhost SSH"
if [[ -f "${HOME}/.ssh/id_rsa" || -f "${HOME}/.ssh/id_ed25519" ]]; then
  ok "An SSH key pair exists"
else
  warn "No SSH key pair — step 30 generates one"
fi
if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 localhost true 2>/dev/null; then
  ok "Passwordless SSH to localhost works"
else
  warn "Passwordless SSH to localhost not working yet — step 30 configures it"
fi

heading "Result"
if (( FAILURES > 0 )); then
  die "${FAILURES} blocking problem(s) found. Fix them before running the installer."
fi
ok "Preflight passed. Next: ./scripts/install-pseudo-distributed.sh"
