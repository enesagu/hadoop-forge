#!/usr/bin/env bash
#
# 10 — Install OS packages Hadoop depends on.
#
#   sudo ./scripts/10-install-prerequisites.sh
#
# Idempotent: apt install on an already-installed package is a no-op.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_linux
require_root "$@"

heading "Refreshing package index"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

heading "Installing packages"
# openssh-server         — start-dfs.sh/start-yarn.sh launch daemons over SSH
# rsync                  — distributing configuration to workers
# net-tools / iproute2   — port and interface inspection during triage
# libsnappy1v5           — native Snappy for shuffle compression
apt-get install -y -qq \
  "${JAVA_PACKAGE}" \
  openssh-server \
  openssh-client \
  curl \
  wget \
  tar \
  rsync \
  vim \
  net-tools \
  iproute2 \
  libsnappy1v5 \
  ca-certificates

ok "Packages installed"

heading "Verifying Java"
java -version
major="$(java_major_version)"
[[ "$major" == "8" || "$major" == "11" ]] \
  || die "Installed Java major version ${major} is unsupported by Hadoop ${HADOOP_VERSION}"

java_home="$(detect_java_home)" || die "Could not resolve JAVA_HOME"
ok "JAVA_HOME=${java_home}"

# Make JAVA_HOME available system-wide so daemons started by init or cron see it.
if ensure_line_in_file "export JAVA_HOME=${java_home}" /etc/profile.d/java.sh; then
  chmod 0644 /etc/profile.d/java.sh
  ok "Exported JAVA_HOME in /etc/profile.d/java.sh"
else
  skip "JAVA_HOME already exported in /etc/profile.d/java.sh"
fi

heading "Kernel tuning for HDFS"
# Transparent Huge Pages defragmentation causes multi-second stalls in large
# JVM heaps — exactly the NameNode's profile. Hadoop distributions all
# recommend disabling it.
if [[ -w /sys/kernel/mm/transparent_hugepage/defrag ]]; then
  echo never > /sys/kernel/mm/transparent_hugepage/defrag
  ok "THP defrag disabled for this boot (make it permanent via GRUB or tuned)"
else
  skip "THP defrag not tunable on this kernel"
fi

# HDFS daemons open a file descriptor per block replica plus one per connection;
# the default 1024 limit is exhausted quickly on a real DataNode.
cat > /etc/security/limits.d/hadoop.conf <<EOF
# Raised for Hadoop daemons: one descriptor per block replica and per connection.
${HADOOP_USER}  soft  nofile  65536
${HADOOP_USER}  hard  nofile  65536
${HADOOP_USER}  soft  nproc   32768
${HADOOP_USER}  hard  nproc   32768
EOF
ok "Raised nofile/nproc limits for ${HADOOP_USER} (takes effect on next login)"

# Swapping a JVM heap out is worse than the memory pressure it relieves: GC
# touching swapped pages turns a 200 ms pause into tens of seconds.
if sysctl -w vm.swappiness=1 >/dev/null 2>&1; then
  ensure_line_in_file "vm.swappiness = 1" /etc/sysctl.d/99-hadoop.conf >/dev/null || true
  ok "vm.swappiness set to 1"
fi

ok "Step 10 complete"
