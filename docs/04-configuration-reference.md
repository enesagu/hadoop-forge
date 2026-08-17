# 04 — Configuration reference

Every parameter this repository sets, what it does, and what to change before
production. The XML files carry the same reasoning inline; this page is the
lookup table.

Values shown are what [`conf/cluster/`](../conf/cluster) uses unless noted.

## Contents

- [core-site.xml](#core-sitexml)
- [hdfs-site.xml](#hdfs-sitexml)
- [mapred-site.xml](#mapred-sitexml)
- [yarn-site.xml](#yarn-sitexml)
- [hadoop-env.sh](#hadoop-envsh)
- [The memory arithmetic](#the-memory-arithmetic)
- [Which file wins](#which-file-wins)

## core-site.xml

| Parameter | Set to | What it does | Production note |
|---|---|---|---|
| `fs.defaultFS` | `hdfs://master:9000` | Default filesystem URI; every client resolves bare paths against it | With HA this must be the **nameservice ID** (`hdfs://forge-ns`), never a hostname — a hostname defeats client-side failover |
| `hadoop.tmp.dir` | `/data/hdfs/tmp` | Root that many other paths derive from | Never leave it under `/tmp`: most distributions clear that on reboot, so a restart loses NameNode state |
| `io.file.buffer.size` | `65536` | Read/write buffer for sequential I/O | The 4 KB default is a relic; 64 KB is measurably faster on scans |
| `hadoop.security.authentication` | `simple` | Authentication mode | **`kerberos`.** `simple` means a client asserts its username and is believed |
| `hadoop.security.authorization` | `true` | Enables service-level ACLs | Keep on |
| `fs.trash.interval` | `1440` (min) | Retention for `hdfs dfs -rm` | Non-zero on any shared cluster. It is the only undo HDFS has |
| `net.topology.script.file.name` | `rack-topology.sh` | Resolves host → rack | Generate it from your CMDB. Unset means every node reports `/default-rack` and rack-failure tolerance is silently lost |
| `ha.zookeeper.quorum` | HA only | ZK ensemble for ZKFC and the RM store | Odd count, spread across racks |

## hdfs-site.xml

### Durability

| Parameter | Set to | What it does | Production note |
|---|---|---|---|
| `dfs.replication` | `3` | Replicas per block | 3 survives a node **and** a rack failure. It is a per-file property — lower it on cold data with `hdfs dfs -setrep` to save real money |
| `dfs.namenode.name.dir` | two paths | Where FsImage and EditLog live | **Always more than one, on different physical disks.** The NameNode writes all of them synchronously; this is the cheapest insurance in the stack |
| `dfs.datanode.data.dir` | one per disk | Block storage | One path per spindle (JBOD). Never RAID — HDFS already replicates across machines, so RAID pays twice and caps throughput at the slowest disk |
| `dfs.datanode.failed.volumes.tolerated` | `1` | Failed disks before the DataNode quits | Without it a single dead disk takes the whole node offline |
| `dfs.datanode.du.reserved` | 10 GB | Space held back per volume | A DataNode that fills the root filesystem takes the machine with it |

### Sizing and throughput

| Parameter | Set to | What it does | Production note |
|---|---|---|---|
| `dfs.blocksize` | `134217728` (128 MB) | Block size | 256 MB helps clusters dominated by very large files: fewer blocks, less NameNode heap, less scheduling overhead. Per-file at creation time |
| `dfs.namenode.handler.count` | `32` | NameNode RPC threads | 10 suffices for a handful of nodes; go to 100–200 past ~100 DataNodes or the NameNode becomes the bottleneck under concurrent submission |
| `dfs.datanode.handler.count` | `16` | DataNode transfer threads | Too low and the re-replication storm after a node loss crawls |

### Checkpointing and membership

| Parameter | Set to | What it does | Production note |
|---|---|---|---|
| `dfs.namenode.checkpoint.period` | `1800` | Seconds between checkpoints | Unbounded EditLog growth turns a 30-second restart into an hour |
| `dfs.namenode.checkpoint.txns` | `500000` | Transactions between checkpoints | Whichever trigger fires first |
| `dfs.hosts` / `dfs.hosts.exclude` | include/exclude files | Which hosts may be DataNodes | Decommission by adding to exclude and running `hdfs dfsadmin -refreshNodes`, then **wait for the state to flip** before powering the machine off |
| `dfs.permissions.enabled` | `true` | POSIX-style permission checks | `false` only in the pseudo and docker sets, and marked as such |

### HA additions

| Parameter | What it does |
|---|---|
| `dfs.nameservices` | Logical cluster name clients address |
| `dfs.ha.namenodes.<ns>` | Members of the nameservice |
| `dfs.namenode.shared.edits.dir` | `qjournal://…` — the JournalNode quorum holding the shared EditLog |
| `dfs.namenode.servicerpc-address.*` | Separate port for DataNode traffic, so client RPC floods cannot starve heartbeats |
| `dfs.client.failover.proxy.provider.<ns>` | How clients find the current Active |
| `dfs.ha.fencing.methods` | How the deposed Active is silenced — see [05](05-high-availability.md) |

## mapred-site.xml

| Parameter | Set to | What it does | Production note |
|---|---|---|---|
| `mapreduce.framework.name` | `yarn` | Execution framework | `local` is for debugging only |
| `mapreduce.application.classpath` | Hadoop share dirs | Container classpath | Missing this gives `ClassNotFoundException` on `MRAppMaster` — one of the most common first-run failures |
| `mapreduce.map.memory.mb` | `2048` | Map container size | Must not exceed `yarn.scheduler.maximum-allocation-mb`, or the job sits in `ACCEPTED` forever |
| `mapreduce.reduce.memory.mb` | `4096` | Reduce container size | Reducers hold the merge buffer, so they are usually larger than mappers |
| `mapreduce.map.java.opts` | `-Xmx1638m` | Task heap | **~80% of the container.** The remainder covers thread stacks, metaspace and off-heap buffers; exceed the container and the NodeManager kills the task |
| `mapreduce.task.io.sort.mb` | `512` | Map-output sort buffer | Bigger buffer, fewer spills. Taken from the task heap, so it must stay well below `-Xmx` |
| `mapreduce.task.io.sort.factor` | `64` | Streams merged at once | Higher means fewer merge passes at the cost of open file descriptors |
| `mapreduce.reduce.shuffle.parallelcopies` | `16` | Concurrent fetches per reducer | Raise on wide clusters; too high hammers the NodeManagers serving shuffle |
| `mapreduce.job.reduce.slowstart.completedmaps` | `0.8` | When reducers may start | The `0.05` default parks idle reducers in containers that mappers still need — classic reduce-slot hoarding |
| `mapreduce.map.output.compress` | `true` | Compress shuffle | Snappy: cheap CPU for a large cut in disk and network I/O. Almost always a win |
| `mapreduce.map.speculative` | `true` | Re-run stragglers | Useful on heterogeneous hardware, wasteful when tasks are uniformly slow because of data skew |
| `mapreduce.reduce.speculative` | `false` | Same for reducers | Off by default here: a duplicated reducer re-reads the entire shuffle |
| `mapreduce.jobhistory.address` | `master:10020` | JobHistory server | Without it, finished jobs vanish from the RM UI |

## yarn-site.xml

| Parameter | Set to | What it does | Production note |
|---|---|---|---|
| `yarn.nodemanager.resource.memory-mb` | `12288` | Memory this node gives YARN | **Not** total RAM. Leave the OS, the DataNode JVM and page cache their share — 75–80% of physical is the usual start. Give YARN everything and you guarantee swapping |
| `yarn.nodemanager.resource.cpu-vcores` | `8` | vcores offered | Roughly physical cores |
| `yarn.scheduler.minimum-allocation-mb` | `1024` | Smallest container | A tiny minimum yields a swarm of containers whose JVM startup dominates the work |
| `yarn.scheduler.maximum-allocation-mb` | `12288` | Largest container | Cannot usefully exceed a single node's capacity |
| `yarn.nodemanager.aux-services` | `mapreduce_shuffle` | Shuffle service | Omit it and **every** MapReduce job fails during shuffle |
| `yarn.resourcemanager.scheduler.class` | `CapacityScheduler` | Scheduler | Capacity for multi-tenant guarantees, Fair for equal progress |
| `yarn.log-aggregation-enable` | `true` | Collect container logs into HDFS | Turns log hunting into `yarn logs -applicationId <id>` |
| `yarn.nodemanager.local-dirs` | one per disk | Container scratch and shuffle spills | Spread across spindles to parallelise I/O |
| `yarn.nodemanager.disk-health-checker.max-disk-utilization-per-disk-percentage` | `90` | Unhealthy threshold | Past it the node stops receiving containers instead of failing every task on it |
| `yarn.nodemanager.vmem-check-enabled` | `false` | Virtual memory enforcement | Unreliable with modern JVMs and glibc arenas; it kills healthy tasks. Physical limits still apply |
| `yarn.resourcemanager.recovery.enabled` | `true` | Survive an RM restart | Otherwise every in-flight job dies with the RM |

### capacity-scheduler.xml

| Parameter | Set to | Note |
|---|---|---|
| `…root.queues` | `etl,adhoc,ml` | Sibling capacities must sum to exactly 100 or the RM refuses to start |
| `…<queue>.capacity` | guaranteed share | The floor a tenant can always claim |
| `…<queue>.maximum-capacity` | elastic ceiling | How far it may grow when others are idle |
| `…maximum-am-resource-percent` | `0.3` | **Important.** Uncapped, enough concurrent submissions fill the cluster with ApplicationMasters all waiting for task containers that can never be granted — a deadlock that looks like every job stuck in `ACCEPTED` |
| `…node-locality-delay` | `40` | Scheduling opportunities to wait for a node-local container before settling for rack-local |

## hadoop-env.sh

Sourced directly by the start scripts, which do **not** read your `~/.bashrc`.
`JAVA_HOME` must be set here even if your shell already exports it.

| Variable | Set to | Note |
|---|---|---|
| `HDFS_NAMENODE_OPTS` | `-Xms8g -Xmx8g -XX:+UseG1GC` | Sized by object count: ~150 bytes of heap per block, file and directory, plus headroom. G1 because a long NameNode GC pause is indistinguishable from an outage to every client |
| `HDFS_DATANODE_OPTS` | `-Xms2g -Xmx2g` | Largely independent of stored volume — it holds block metadata, not blocks |
| `YARN_RESOURCEMANAGER_OPTS` | `-Xms4g -Xmx4g` | Grows with cluster size and application count |
| `HDFS_*_USER` | `hadoop` | Refuses to start as root |
| `HADOOP_SSH_OPTS` | `BatchMode=yes` | The start scripts SSH to workers; an interactive prompt would hang them |
| `-Dcom.sun.management.jmxremote.port` | 9010–9012 | Exposes JMX for the Prometheus exporter — see [08](08-monitoring.md) |

## The memory arithmetic

Get this wrong and jobs hang in `ACCEPTED` or get killed mid-flight. The chain,
from the outside in:

```
physical RAM (16 GB)
 └── yarn.nodemanager.resource.memory-mb      12288   ~75%, OS keeps the rest
      └── yarn.scheduler.maximum-allocation-mb 12288   one container's ceiling
           └── mapreduce.reduce.memory.mb       4096   the container
                └── -Xmx3276m                          ~80% of the container
                     └── mapreduce.task.io.sort.mb 512  taken from that heap
```

Three rules:

1. **Container ≤ scheduler max ≤ node capacity.** Break the first and the job
   waits forever; break the second and no node can ever satisfy it.
2. **Heap ≈ 80% of the container.** Thread stacks, metaspace, code cache and
   off-heap buffers live in the remaining 20%. A heap equal to its container is
   killed by the NodeManager the moment it grows into the gap.
3. **Sort buffer well below the heap.** It is allocated *from* the heap.

`tests/validate-configs.sh` checks all three on every push, because these are
easier to verify statically than to diagnose at 3 a.m.

## Which file wins

Precedence, lowest to highest:

1. `*-default.xml` inside the Hadoop jars
2. `$HADOOP_CONF_DIR/*-site.xml`
3. `-D key=value` on the command line — **only if the driver uses `ToolRunner`**
4. `conf.set()` in job code

Properties marked `<final>true</final>` in a site file cannot be overridden by
1–4, which is how an administrator pins a value users must not change.

Two traps worth knowing:

- A **duplicated `<name>`** in one file silently wins or loses by parse order.
  Nothing warns you. `tests/validate-configs.sh` rejects it.
- A driver with a plain `main()` instead of `ToolRunner` **ignores `-D` entirely**
  and reports no error. See [examples/](../examples).

Next: [05 — High availability](05-high-availability.md) ·
[07 — Tuning](07-tuning.md)
