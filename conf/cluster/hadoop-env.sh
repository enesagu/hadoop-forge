# shellcheck shell=bash
# ---------------------------------------------------------------------------
# hadoop-env.sh — multi-node cluster
#
# This file is distributed to every node, so it must not contain host-specific
# values. Role-specific settings are keyed by daemon name instead.
# ---------------------------------------------------------------------------

export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-11-openjdk-amd64}
export HADOOP_HOME=${HADOOP_HOME:-/opt/hadoop}
export HADOOP_CONF_DIR=${HADOOP_CONF_DIR:-$HADOOP_HOME/etc/hadoop}
export HADOOP_LOG_DIR=${HADOOP_LOG_DIR:-/var/log/hadoop}
export HADOOP_PID_DIR=${HADOOP_PID_DIR:-/var/run/hadoop}

# Never run daemons as root.
export HDFS_NAMENODE_USER=hadoop
export HDFS_DATANODE_USER=hadoop
export HDFS_SECONDARYNAMENODE_USER=hadoop
export YARN_RESOURCEMANAGER_USER=hadoop
export YARN_NODEMANAGER_USER=hadoop

export HADOOP_HEAPSIZE_MAX=2048m

# NameNode heap: ~150 bytes of metadata per block/file/directory, plus headroom.
# 8 GB comfortably holds tens of millions of objects. Raise it before you need
# to, because raising it later requires a restart, and a NameNode restart on a
# large cluster is a planned event.
export HDFS_NAMENODE_OPTS="-Xms8g -Xmx8g \
  -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+ParallelRefProcEnabled \
  -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=${HADOOP_LOG_DIR} \
  -Xlog:gc*:file=${HADOOP_LOG_DIR}/namenode-gc.log:time,uptime,level,tags:filecount=10,filesize=64M \
  -Dcom.sun.management.jmxremote \
  -Dcom.sun.management.jmxremote.port=9010 \
  -Dcom.sun.management.jmxremote.authenticate=false \
  -Dcom.sun.management.jmxremote.ssl=false"

export HDFS_DATANODE_OPTS="-Xms2g -Xmx2g -XX:+UseG1GC \
  -Dcom.sun.management.jmxremote \
  -Dcom.sun.management.jmxremote.port=9011 \
  -Dcom.sun.management.jmxremote.authenticate=false \
  -Dcom.sun.management.jmxremote.ssl=false"

export HDFS_SECONDARYNAMENODE_OPTS="-Xms8g -Xmx8g -XX:+UseG1GC"

export YARN_RESOURCEMANAGER_OPTS="-Xms4g -Xmx4g -XX:+UseG1GC \
  -Dcom.sun.management.jmxremote \
  -Dcom.sun.management.jmxremote.port=9012 \
  -Dcom.sun.management.jmxremote.authenticate=false \
  -Dcom.sun.management.jmxremote.ssl=false"

export YARN_NODEMANAGER_OPTS="-Xms2g -Xmx2g -XX:+UseG1GC"

export HADOOP_OPTS="${HADOOP_OPTS} -Djava.library.path=${HADOOP_HOME}/lib/native"
export HADOOP_OPTS="${HADOOP_OPTS} -Djava.net.preferIPv4Stack=true"

# start-dfs.sh / start-yarn.sh SSH to every entry in `workers`. Do not prompt on
# first connection, but keep host key checking meaningful by pre-seeding
# known_hosts via scripts/30-setup-ssh.sh.
export HADOOP_SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o SendEnv=HADOOP_CONF_DIR"
