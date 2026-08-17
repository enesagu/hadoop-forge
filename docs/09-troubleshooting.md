# 09 — Troubleshooting

Symptom → cause → fix. Start with the triage order, then jump to your symptom.

## Triage order

Work outwards. Most "Hadoop is broken" reports resolve in the first three steps.

```bash
./scripts/health-check.sh          # everything below, in one pass
hdfs dfsadmin -safemode get        # is the filesystem writable at all?
hdfs dfsadmin -report              # are the DataNodes alive?
yarn node -list                    # are the NodeManagers alive?
jps                                # are the local daemons even running?
yarn logs -applicationId <id>      # what did the job itself say?
```

The single most useful habit: **read the actual daemon log**, not just the client
error. `$HADOOP_LOG_DIR/hadoop-hadoop-namenode-*.log`. The client message is
usually a symptom several layers removed from the cause.

## Contents

- [Startup](#startup)
- [HDFS](#hdfs)
- [YARN and jobs](#yarn-and-jobs)
- [Performance](#performance)
- [Docker-specific](#docker-specific)
- [HA-specific](#ha-specific)

## Startup

### `Connection refused` connecting to the NameNode

```
java.net.ConnectException: Call From host to localhost:9000 failed on
connection exception: java.net.ConnectException: Connection refused
```

Three candidates, in order of likelihood:

1. The NameNode is not running. `jps | grep NameNode`, then read the log — it
   almost always says why it exited.
2. `fs.defaultFS` does not match where the NameNode is listening. Compare
   `hdfs getconf -confKey fs.defaultFS` with `ss -ltnp | grep 9000`.
3. The NameNode bound to the wrong interface. In containers or on multi-homed
   hosts set `dfs.namenode.rpc-bind-host=0.0.0.0`.

### DataNode does not appear in `jps`

Read `hadoop-hadoop-datanode-*.log`. The usual cause:

```
java.io.IOException: Incompatible clusterIDs in /data/hdfs/datanode:
namenode clusterID = CID-abc...; datanode clusterID = CID-xyz...
```

The NameNode was reformatted while the DataNode kept its old data. The DataNode
refuses to serve blocks belonging to a namespace that no longer exists — which is
correct behaviour, not a bug.

```bash
# Only if you accept losing this node's blocks.
hdfs --daemon stop datanode
rm -rf /data/hdfs/datanode/*
hdfs --daemon start datanode
```

If **all** DataNodes report this, you reformatted a live cluster and the blocks
are orphaned. This is why `scripts/60-format-and-start.sh` refuses to format over
an existing namespace without `FORGE_FORCE_FORMAT=1`.

### `JAVA_HOME is not set and could not be found`

The start scripts source `hadoop-env.sh` and do **not** read your `~/.bashrc`. Set
it in `$HADOOP_CONF_DIR/hadoop-env.sh` as well. `scripts/50-apply-config.sh` pins
it automatically to a path that exists on the machine.

### Startup hangs with no output

`start-dfs.sh` is waiting on an SSH prompt it cannot answer. Verify:

```bash
ssh -o BatchMode=yes localhost true
ssh -o BatchMode=yes worker1 true
```

Non-zero exit means step 30 has not been run, or `authorized_keys` is
group-writable — sshd silently ignores it in that case.

### `Attempting to operate on hdfs namenode as root`

```bash
ERROR: Attempting to operate on hdfs namenode as root
ERROR: but there is no HDFS_NAMENODE_USER defined. Aborting operation.
```

Hadoop is refusing to run as root, correctly. Run as the `hadoop` user. Setting
`HDFS_NAMENODE_USER=root` silences it and is a bad idea — every MapReduce
container would inherit root.

## HDFS

### Safe mode will not turn off

```
Name node is in safe mode. The reported blocks 412 needs additional 88 blocks
to reach the threshold 0.9990 of total blocks 500.
```

The NameNode is waiting for DataNodes to report enough replicas. At startup this
clears itself in a minute or two. If it persists, the DataNodes are not
registering — check the DataNode logs, not the NameNode's.

```bash
hdfs dfsadmin -safemode get
hdfs dfsadmin -safemode leave   # forces it — understand why first
```

Forcing it with genuinely missing blocks gives you a writable filesystem with
unreadable files. Diagnose before overriding.

### `Permission denied` on HDFS operations

```
org.apache.hadoop.security.AccessControlException: Permission denied:
user=enes, access=WRITE, inode="/user/enes":hdfs:supergroup:drwxr-xr-x
```

HDFS has its own permissions, unrelated to your local filesystem. Usually the
user's home directory does not exist:

```bash
hdfs dfs -mkdir -p /user/enes
hdfs dfs -chown enes:enes /user/enes
```

Remember that in `simple` auth mode, `HADOOP_USER_NAME` sets your identity — which
is convenient here and the reason this is not security. See [06](06-security.md).

### `File could only be replicated to 0 nodes instead of minReplication (=1)`

The NameNode accepted the file creation but has no DataNode to place a block on.
Causes:

- No live DataNodes (`hdfs dfsadmin -report`).
- Every DataNode is out of space, or below `dfs.datanode.du.reserved`.
- All DataNodes are excluded — check `dfs.hosts.exclude`.
- The client cannot reach the DataNodes directly. The NameNode returns addresses
  and the client connects itself; a firewall on port 9866, or a client outside a
  Docker network, produces exactly this error while `-ls` works fine.

### Under-replicated blocks that never recover

```bash
hdfs fsck / | grep -i replicat
```

Transient after a node loss or a `setrep`. Persistent means fewer live DataNodes
than `dfs.replication` requires — three replicas need three nodes. Either add
nodes or lower replication for the affected paths.

### Missing or corrupt blocks

```bash
hdfs fsck / -list-corruptfileblocks
hdfs fsck /path -delete            # deletes the FILES; this is data loss
```

Every replica of those blocks is gone. There is no recovery from within HDFS —
restore from backup. If this appeared without a hardware failure, check whether
someone reformatted a NameNode or wiped a DataNode directory.

### The NameNode takes forever to start

It is replaying the EditLog onto the FsImage. A very long EditLog means
checkpointing has not been running: the Secondary NameNode is down, or the Standby
is not tailing the journal. Check `dfs.namenode.checkpoint.period` and that the
checkpointing role is actually alive.

## YARN and jobs

### Job stays in `ACCEPTED` forever

The most common YARN ticket there is. The scheduler cannot satisfy the request:

```bash
yarn application -list -appStates ACCEPTED
yarn node -list                       # any RUNNING NodeManagers?
```

| Cause | Check |
|---|---|
| Container larger than any node offers | `mapreduce.map.memory.mb` vs `yarn.nodemanager.resource.memory-mb` |
| Container above the scheduler ceiling | vs `yarn.scheduler.maximum-allocation-mb` |
| Queue is full | Queue capacity in the RM UI |
| Cluster is full of ApplicationMasters | `maximum-am-resource-percent` — enough concurrent submissions deadlock, with every AM waiting for containers that can never be granted |
| No healthy NodeManagers | `yarn node -list -all`, look for `UNHEALTHY` |

`tests/validate-configs.sh` catches the first two statically.

### `Container killed on request. Exit code is 143`

The container exceeded its memory limit. Either raise the container size or
shrink the heap — and note the direction:

```xml
<name>mapreduce.map.memory.mb</name>   <value>2048</value>   <!-- container -->
<name>mapreduce.map.java.opts</name>   <value>-Xmx1638m</value>  <!-- ~80% -->
```

Raising only `-Xmx` makes this **more** frequent. The container is the hard limit;
the heap must fit inside it with room for stacks, metaspace and off-heap buffers.

### `Container beyond virtual memory limits`

```
Container is running beyond virtual memory limits. Current usage: 1.0 GB of
1 GB physical memory used; 2.7 GB of 2.1 GB virtual memory used.
```

Note the physical usage is fine. YARN's virtual memory accounting is unreliable
with modern JVMs and glibc arenas:

```xml
<name>yarn.nodemanager.vmem-check-enabled</name>
<value>false</value>
```

Physical memory limits still apply, which is the check that matters.

### `ClassNotFoundException` on `MRAppMaster`

`mapreduce.application.classpath` is missing or wrong, so the container starts
without Hadoop's own classes. All three of these need to be set — see
[`conf/cluster/mapred-site.xml`](../conf/cluster/mapred-site.xml):

```xml
mapreduce.application.classpath
yarn.app.mapreduce.am.env       HADOOP_MAPRED_HOME=/opt/hadoop
mapreduce.admin.user.env        HADOOP_MAPRED_HOME=/opt/hadoop
```

### Job works locally, fails on the cluster with `ClassNotFoundException` on *your* class

Missing `job.setJarByClass(YourDriver.class)`. Without it YARN does not know which
jar to ship to the containers. Locally it works because the classes were already
on the classpath.

### Shuffle failures

```
org.apache.hadoop.mapreduce.task.reduce.Shuffle$ShuffleError:
error in shuffle in fetcher#1
```

Check first that the shuffle service is registered — its absence fails **every**
MapReduce job:

```xml
<name>yarn.nodemanager.aux-services</name>
<value>mapreduce_shuffle</value>
```

Otherwise: reducer out of memory during the merge (lower
`mapreduce.reduce.shuffle.input.buffer.percent`), a NodeManager that died holding
map output, or a full `yarn.nodemanager.local-dirs`.

### `-D` has no effect

The driver does not use `ToolRunner`. A plain `main()` ignores `-D`, `-files`,
`-libjars` and `-archives`, silently. See
[examples/](../examples#tool-and-toolrunner).

### `Output directory already exists`

Deliberate — it stops a re-run from half-overwriting results. Delete it
explicitly, or use the example's `-D wordcount.output.overwrite=true`.

## Performance

### One task takes 20× longer than the rest

Data skew. One key holds most of the data. No parameter fixes this — see
[07 — Tuning](07-tuning.md#skew) for partitioner and salting approaches.

### Everything is slow after a node failure

Expected. The NameNode is re-replicating the dead node's blocks, which saturates
disks and network. Throttle it if it is hurting production:

```xml
<name>dfs.namenode.replication.max-streams</name>
<value>2</value>
```

### The cluster slows down over months

Usually the small file count creeping up. See
[07 — Tuning](07-tuning.md#1-the-small-file-problem).

```bash
hdfs fsck / | grep -E 'Total (files|blocks)|Average block size'
```

## Docker-specific

| Symptom | Cause and fix |
|---|---|
| Containers restart in a loop | Docker has less memory than the topology needs. Raise it, or `make single` |
| `bind: address already in use` | A local process holds 9870/8088/9000. `NAMENODE_UI_PORT=19870 make up` |
| NameNode never healthy | DataNodes not registering. `make logs` and read the DataNode output |
| Client on the host cannot read files | Host resolves the NameNode but not the DataNodes. Use the gateway container (`make shell`) or add the DataNode names to your hosts file |
| Data gone after a restart | You ran `down -v` (or `make purge`). `make down` keeps the volumes |
| `docker compose: unknown command` | Compose v1. Upgrade, or `COMPOSE="docker-compose" make up` |

## HA-specific

### Both NameNodes are Standby

Nobody won the election. Check the ZKFCs are running and that ZooKeeper is
reachable:

```bash
hdfs haadmin -getAllServiceState
jps | grep DFSZKFailoverController
```

If `hdfs zkfc -formatZK` was never run, the election znode does not exist.

### `-bootstrapStandby` fails

The first NameNode must be **running** when you bootstrap the second, and the
JournalNode quorum must be up. Bootstrapping copies the namespace over RPC.

### NameNode exits at startup in HA mode

```
org.apache.hadoop.hdfs.qjournal.client.QuorumException:
Unable to check if JNs are ready for formatting
```

The JournalNodes are not running. Start the quorum **before** the NameNodes; a
NameNode with nowhere to write edits refuses to start rather than risk diverging.

### Failover happens repeatedly with nothing wrong

`ha.zookeeper.session-timeout.ms` is shorter than the NameNode's worst GC pause,
so a pause looks like a death. Fix the GC first (bounded G1 pause targets, see
[07](07-tuning.md#the-namenode)) and only then consider raising the timeout.

## When none of this helps

1. `./scripts/health-check.sh` — the full picture, in order.
2. `yarn logs -applicationId <id>` — the job's own words.
3. `$HADOOP_LOG_DIR/*.log` on the daemon that is misbehaving, not the client.
4. `hdfs fsck / -files -blocks -locations` — what HDFS believes about your data.
5. `hadoop checknative -a` — silently missing native codecs are much slower.
6. The NameNode and ResourceManager UIs. Under-replicated blocks, unhealthy nodes
   and queue saturation are all visible there at a glance.
