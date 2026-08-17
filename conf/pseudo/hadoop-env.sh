# shellcheck shell=bash
# ---------------------------------------------------------------------------
# hadoop-env.sh — pseudo-distributed
#
# The start/stop scripts source this file directly and do NOT see your
# ~/.bashrc. JAVA_HOME must therefore be set here as well, even if your shell
# already exports it.
# ---------------------------------------------------------------------------

export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-11-openjdk-amd64}
export HADOOP_HOME=${HADOOP_HOME:-/opt/hadoop}
export HADOOP_CONF_DIR=${HADOOP_CONF_DIR:-$HADOOP_HOME/etc/hadoop}
export HADOOP_LOG_DIR=${HADOOP_LOG_DIR:-$HADOOP_HOME/logs}
export HADOOP_PID_DIR=${HADOOP_PID_DIR:-/data/hdfs/pids}

# Default ceiling for any daemon that does not override it below.
export HADOOP_HEAPSIZE_MAX=1024m

# NameNode heap is driven by object count: budget ~150 bytes per block, file
# and directory, then leave generous headroom. G1 keeps pause times bounded as
# the live set grows, which matters because a long NameNode GC pause looks
# exactly like a NameNode outage to every client.
export HDFS_NAMENODE_OPTS="-Xms1g -Xmx1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 \
  -Xlog:gc*:file=${HADOOP_LOG_DIR}/namenode-gc.log:time,uptime:filecount=5,filesize=32M"

# DataNode heap is largely independent of stored volume — it holds block
# metadata, not blocks — so it stays small.
export HDFS_DATANODE_OPTS="-Xms512m -Xmx512m -XX:+UseG1GC"

export HDFS_SECONDARYNAMENODE_OPTS="-Xms1g -Xmx1g -XX:+UseG1GC"
export YARN_RESOURCEMANAGER_OPTS="-Xms1g -Xmx1g -XX:+UseG1GC"
export YARN_NODEMANAGER_OPTS="-Xms512m -Xmx512m -XX:+UseG1GC"

# Fail fast and loudly rather than silently falling back to the pure-Java
# implementations of CRC32 and compression codecs.
export HADOOP_OPTS="${HADOOP_OPTS} -Djava.library.path=${HADOOP_HOME}/lib/native"
export HADOOP_OPTS="${HADOOP_OPTS} -Djava.net.preferIPv4Stack=true"
