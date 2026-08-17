# 01 — Architecture

Hadoop is three independent layers that happen to ship together: a storage layer
(HDFS), a resource layer (YARN), and a compute engine (MapReduce) that is merely
the first of many tenants YARN can host. Understanding where one ends and the
next begins is what makes the configuration files stop looking arbitrary.

## Contents

- [The design philosophy](#the-design-philosophy)
- [HDFS](#hdfs)
- [YARN](#yarn)
- [MapReduce](#mapreduce)
- [The ecosystem around the core](#the-ecosystem-around-the-core)

## The design philosophy

Three assumptions drove every decision in the original GFS and MapReduce papers,
and they still explain Hadoop's behaviour today.

**1. Failure is routine, not exceptional.** On a cluster of thousands of
commodity machines, a disk dies, a NIC flaps, or a node panics *every day*.
Anything that treats failure as an error path will spend its life in the error
path. So durability comes from replication rather than expensive hardware,
liveness comes from heartbeats, and recovery is automatic.

**2. Move computation to the data, not data to the computation.** Network
bandwidth is the scarce resource. Shipping a petabyte across a spine switch to
reach the CPU is absurd when you can ship a few kilobytes of code to the machine
already holding the bytes. This single idea is why HDFS exposes block locations
to schedulers at all — a normal filesystem would consider that an implementation
detail.

**3. Write once, read many.** HDFS is optimised for large files that are written
once and scanned repeatedly: logs, sensor dumps, batch exports. There is no
in-place random write. Fighting this assumption — millions of small mutable
files — is the origin of most HDFS pain in the field.

A fourth idea arrived later with Hadoop 2.0 and matters just as much:
**separate resource management from the programming model.** In Hadoop 1.x the
JobTracker was both scheduler and MapReduce runtime, so nothing but MapReduce
could run on the cluster. YARN split those roles, and the cluster became a
general-purpose operating system that Spark, Tez and Flink could all target.

## HDFS

HDFS follows a master/worker design in which metadata and data travel on
completely separate paths.

```
                       ┌──────────────────────────┐
        metadata ops   │        NameNode          │
      ┌───────────────▶│  FsImage + EditLog       │
      │                │  block map (in RAM only) │
      │                └──────────┬───────────────┘
      │                           │ heartbeats (3s)
      │                           │ block reports (~6h)
┌─────┴──────┐          ┌─────────┴──────────┬──────────────────┐
│   Client   │          │                    │                  │
└─────┬──────┘    ┌─────▼─────┐        ┌─────▼─────┐      ┌─────▼─────┐
      │           │ DataNode  │        │ DataNode  │      │ DataNode  │
      └──────────▶│  blk_1001 │───────▶│  blk_1001 │─────▶│  blk_1001 │
        bulk data └───────────┘  write └───────────┘ pipe └───────────┘
```

### NameNode

The NameNode owns the namespace: the directory tree, file-to-block mapping, and
permissions. It persists exactly two things:

- **FsImage** — a checkpoint of the entire namespace at a point in time.
- **EditLog** — the ordered journal of every mutation since that checkpoint.

Startup replays the EditLog onto the FsImage. That is why an EditLog that never
gets checkpointed turns a 30-second restart into an hour-long one.

Critically, **block locations are not persisted.** They live only in memory and
are rebuilt at startup from *block reports* sent by every DataNode. The NameNode
does not know where anything is until the workers tell it — which is also why a
cluster spends its first minutes after boot in safe mode, waiting for enough
reports to satisfy the configured replication threshold before allowing writes.

Real data never flows through the NameNode. Clients ask it *where*, then talk to
DataNodes directly. This is the whole reason a single master can front a cluster
serving hundreds of gigabytes per second.

The memory cost is roughly **150 bytes of heap per block, file and directory**.
Multiply that by your object count and you have your NameNode heap sizing — and
the arithmetic behind the small-file problem.

### DataNode

Each DataNode stores opaque blocks as ordinary files on local disks and:

- sends a **heartbeat** every 3 seconds (`dfs.heartbeat.interval`); after
  10.5 minutes of silence the NameNode declares it dead and re-replicates its
  blocks elsewhere,
- sends a **block report** periodically (`dfs.blockreport.intervalMsec`,
  6 hours by default) enumerating everything it holds,
- serves client reads and writes directly, and forwards writes down the pipeline,
- verifies checksums on read and reports corruption so the NameNode can schedule
  a fresh copy.

DataNode disks are deliberately **JBOD, never RAID**. HDFS already provides
redundancy across machines; RAID would pay for it twice and cap throughput at
the slowest spindle in the array.

### Secondary NameNode — a misleading name

The Secondary NameNode is **not a standby and provides no failover.** Its only
job is checkpointing: fetch the FsImage and EditLog, merge them, hand the new
FsImage back. Without it the EditLog grows without bound. When HA is enabled the
Standby NameNode performs checkpointing itself and the Secondary NameNode is not
deployed at all — see [05 — High availability](05-high-availability.md).

### Blocks and replication

Files are split into fixed-size **blocks**, 128 MB by default. A 300 MB file
becomes 128 + 128 + 44 MB; the last block occupies only what it needs. Two
opposing forces set that size:

- Smaller blocks mean more metadata objects, and NameNode heap is finite.
- Larger blocks amortise disk seek time against transfer time, which is what
  makes sequential scans fast.

Each block is replicated three times by default, placed with **rack awareness**:

1. first replica on the writing client's node (or a random node if the client is
   outside the cluster),
2. second replica on a node in a *different* rack,
3. third replica on another node in the *same rack as the second*.

That layout survives both a node failure and a whole-rack failure while sending
only one copy across the rack boundary — a purely random placement would triple
inter-rack traffic for the same durability.

Rack topology is resolved by a script named in `net.topology.script.file.name`,
which maps an IP to a rack path such as `/dc1/rack3`. The same information feeds
scheduler locality decisions.

Hadoop 3 adds **erasure coding** as an alternative to replication: a RS(6,3)
policy stores 9 blocks instead of 18 for the same fault tolerance as 3x
replication, cutting storage overhead from 200% to 50% at the cost of far more
expensive reconstruction reads. It suits cold data, not hot working sets.

### Write path

1. The client calls `create()`. The NameNode checks that the path is free and
   permissions allow it, then records the file — **with no blocks yet** — and
   grants the client a lease.
2. The client buffers data locally and splits it into 64 KB packets.
3. When the first block fills, the client asks the NameNode for a block ID and an
   ordered list of DataNodes, one per replica.
4. The client streams packets to the first DataNode, which persists them *and*
   forwards them to the second, which forwards to the third — a **pipeline**.
   The client's uplink carries the data once, not three times.
5. Each DataNode acknowledges packets; ACKs travel back up the pipeline. If a
   DataNode fails mid-write, it is removed from the pipeline, the block is given
   a new generation stamp, and the write continues with the survivors — the
   NameNode restores the replication factor later.
6. On `close()` the client releases its lease and the NameNode commits the
   final block list to the EditLog.

### Read path

1. The client asks the NameNode for the file's block list.
2. For each block the NameNode returns DataNode addresses **sorted by network
   distance** from the client.
3. The client connects to the nearest DataNode per block and streams the bytes.
   The NameNode is out of the loop entirely; if a DataNode is unreachable or a
   checksum fails, the client transparently retries the next replica.

## YARN

YARN (Yet Another Resource Negotiator) allocates CPU and memory across the
cluster and knows nothing about what runs inside the containers it hands out.

```
   ┌────────────────────────────────────────────────────────┐
   │                   ResourceManager                      │
   │   Scheduler          │       ApplicationsManager       │
   │   (pure allocation)  │  (accepts jobs, launches AMs)   │
   └───────┬──────────────┴──────────────────┬──────────────┘
           │ resource offers                 │ launch AM
   ┌───────▼───────┐  ┌───────────────┐  ┌───▼───────────┐
   │ NodeManager   │  │ NodeManager   │  │ NodeManager   │
   │ ┌───────────┐ │  │ ┌───────────┐ │  │ ┌───────────┐ │
   │ │ container │ │  │ │ container │ │  │ │    AM     │ │
   │ └───────────┘ │  │ └───────────┘ │  │ └───────────┘ │
   └───────────────┘  └───────────────┘  └───────────────┘
```

### ResourceManager

The single authority on cluster resources, with two distinct halves:

- **Scheduler** — allocates resources and nothing else. It does not monitor
  applications, does not restart failed tasks, and offers no guarantees about
  what happens inside a container. Pluggable: FIFO, Capacity or Fair.
- **ApplicationsManager** — accepts submissions, allocates the very first
  container for each application's ApplicationMaster, and restarts an AM that
  dies.

### NodeManager

One per worker. It launches, monitors and kills containers on its node, reports
resource usage and health to the RM, and enforces isolation (cgroups for CPU and
memory, optionally Docker as the container runtime in Hadoop 3). It also serves
the shuffle as an auxiliary service — that is what
`yarn.nodemanager.aux-services=mapreduce_shuffle` enables, and why MapReduce jobs
fail mysteriously when it is missing.

### ApplicationMaster

One **per application**, and it dies with the application. Launched by the RM in
the first container, it negotiates further containers, places tasks on them,
tracks progress, and re-runs failures. Crucially it is **framework-specific**:
MapReduce ships its own AM, Spark ships another. YARN does not care — it only
grants resources. This is precisely the separation Hadoop 1.x lacked.

### Container

A lease on a specific amount of memory and vcores on a specific node. Every task
— a map task, a reduce task, a Spark executor — runs inside one.

### Submission flow

1. Client submits an application to the RM.
2. RM allocates container 0 and tells that node's NM to launch the AM.
3. AM registers with the RM and requests containers, optionally expressing
   **locality preferences** ("give me a container on the node holding block X").
4. The Scheduler grants containers as capacity frees up.
5. The AM asks the relevant NMs to start tasks in those containers.
6. Tasks report to the AM; the AM reports to the RM.
7. On completion the AM unregisters and all containers are released.

### Schedulers

| Scheduler | Behaviour | When to use |
|---|---|---|
| **FIFO** | Strict queue order | Never in production — one large job starves everything behind it |
| **Capacity** | Resources partitioned into hierarchical queues with guaranteed shares; idle capacity is lent out elastically | Multi-tenant enterprise clusters; default in Cloudera/CDP |
| **Fair** | Every job converges to an equal share over time; new jobs start quickly by reclaiming from running ones | Dynamic, interactive, mixed workloads |

The practical difference: Capacity guarantees a *floor* per tenant, Fair
guarantees *equal progress*. Pick based on whether your organisation charges
back by team or optimises for latency.

## MapReduce

MapReduce is divide-and-conquer with a mandatory sort in the middle.

### Map phase

The input is divided into **InputSplits** — normally one split per HDFS block, on
purpose, so a map task can read locally. Each split feeds one map task, which
emits `<key, value>` pairs.

### Shuffle and sort — the expensive part

Map output is partitioned (a hash of the key decides the target reducer),
buffered in memory (`mapreduce.task.io.sort.mb`), spilled to local disk when the
buffer crosses its threshold, merged, then pulled across the network by the
reducers and merge-sorted by key on arrival.

This phase is where jobs go to die. It is disk-heavy, network-heavy, and it is
the reason `mapreduce.task.io.sort.mb`, output compression and combiners exist.
Spark's shuffle is a different implementation of the same fundamental step —
which is why understanding it here pays off there.

### Combiner

An optional local mini-reduce applied to a map task's output *before* it crosses
the network. In WordCount, a combiner turns 5,000 emissions of `("the", 1)` into
one `("the", 5000)`. It must be associative and commutative, because the
framework decides freely whether to run it, once, twice, or not at all.

### Reduce phase

Each reducer receives every value for its keys in sorted order, aggregates, and
writes results to HDFS — one output file per reducer, `part-r-00000` onwards.

### WordCount, conceptually

```
map(split):
  for line in split:
    for word in tokenize(line):
      emit(word, 1)

shuffle & sort:
  all (word, 1) pairs for the same word converge on one reducer, sorted by word

reduce(word, counts):
  emit(word, sum(counts))
```

A runnable, unit-tested version lives in [../examples/wordcount](../examples/wordcount).

Almost nobody writes raw MapReduce today — Hive and Spark abstract it away. The
reason to learn it anyway is that it makes shuffle, partitioning, skew and
locality concrete, and those concepts outlive the API.

## The ecosystem around the core

| Project | Role |
|---|---|
| **Hive** | SQL over HDFS; compiles HiveQL to MapReduce/Tez/Spark jobs, with table schemas in a Metastore (MySQL/PostgreSQL) |
| **HBase** | Bigtable-style column-family NoSQL store on HDFS, coordinated by ZooKeeper, for millisecond random reads/writes |
| **Spark** | In-memory general-purpose engine; runs on YARN, reads HDFS |
| **Sqoop** | Bulk parallel transfer between RDBMS and HDFS over JDBC, using map-only jobs |
| **Flume** | Source → Channel → Sink pipelines that land log/event streams in HDFS |
| **Oozie** | XML-defined workflow and coordinator scheduling for Hadoop jobs |
| **ZooKeeper** | Distributed coordination: leader election for NameNode/RM failover, HBase region assignment, locks |
| **Kerberos** | Authentication — *who are you* |
| **Ranger** | Authorisation and audit — *what may you touch* |

Next: [02 — Bare-metal installation](02-installation-bare-metal.md).
