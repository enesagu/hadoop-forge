#!/usr/bin/env bash
#
# A guided tour of the HDFS commands worth knowing, each with the reason it
# matters. Read it as much as run it.
#
#   make shell
#   bash /examples/hdfs-basics.sh

set -euo pipefail

PLAY="${PLAY:-/tmp/hdfs-basics}"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
run()  { printf '\033[36m$ %s\033[0m\n' "$*"; eval "$@"; }

step "Where am I pointed?"
# Resolves fs.defaultFS. If this is not what you expect, nothing below will be
# either — a surprising number of "HDFS is broken" reports are a client reading
# the wrong core-site.xml.
run "hdfs getconf -confKey fs.defaultFS"

step "Cluster health"
run "hdfs dfsadmin -report | head -25"

step "Directories and files"
run "hdfs dfs -mkdir -p ${PLAY}/ingest"
run "hdfs dfs -ls -R /tmp | head"

step "Copying data in"
# -put and -copyFromLocal are the same command. -moveFromLocal deletes the
# local copy on success, which you want in an ingest pipeline and almost never
# want interactively.
run "echo 'block placement is rack aware' > /tmp/note.txt"
run "hdfs dfs -put -f /tmp/note.txt ${PLAY}/ingest/"
run "hdfs dfs -ls ${PLAY}/ingest"

step "Reading data back"
run "hdfs dfs -cat ${PLAY}/ingest/note.txt"
# -tail reads the last kilobyte only, which is how you inspect a multi-gigabyte
# log without pulling it across the network.
run "hdfs dfs -tail ${PLAY}/ingest/note.txt"

step "How much space is this using?"
# -du shows logical size; -du -s -h adds the replicated footprint. A 1 GB file
# at replication 3 occupies 3 GB of cluster capacity, and confusing the two is
# how capacity planning goes wrong.
run "hdfs dfs -du -s -h ${PLAY}"
run "hdfs dfs -df -h /"

step "Where do the blocks actually live?"
# The single most illuminating command in HDFS: block IDs, their replicas, and
# the DataNode plus rack holding each one.
run "hdfs fsck ${PLAY}/ingest/note.txt -files -blocks -locations"

step "Per-file replication"
# Replication is a per-file property, not a cluster-wide constant. Raising it on
# a hot file spreads read load; lowering it on cold data saves real money.
run "hdfs dfs -setrep -w 2 ${PLAY}/ingest/note.txt"
run "hdfs dfs -stat '%r replicas, %b bytes, block %o' ${PLAY}/ingest/note.txt"

step "Deleting, and the safety net"
# -rm moves to .Trash when fs.trash.interval > 0. -skipTrash bypasses it and is
# genuinely irreversible.
run "hdfs dfs -rm ${PLAY}/ingest/note.txt"
run "hdfs dfs -ls -R ${PLAY} || true"

step "Safe mode"
# Read-only state the NameNode enters at startup, and that you enter manually
# before maintenance. Forgetting to leave it looks exactly like a broken cluster.
run "hdfs dfsadmin -safemode get"

step "Cleaning up"
run "hdfs dfs -rm -r -f -skipTrash ${PLAY}"

printf '\n\033[1mDone.\033[0m Next: bash /examples/run-wordcount.sh\n'
