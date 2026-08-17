# 07 — Performance tuning

Ordered by how much difference each usually makes. Fix the top of this list
before touching the bottom: no amount of shuffle tuning saves a cluster drowning
in small files.

## Contents

- [1. The small file problem](#1-the-small-file-problem)
- [2. Data locality](#2-data-locality)
- [3. Shuffle](#3-shuffle)
- [4. Compression](#4-compression)
- [5. File formats](#5-file-formats)
- [6. Speculative execution](#6-speculative-execution)
- [7. JVM and garbage collection](#7-jvm-and-garbage-collection)
- [8. Hardware and network](#8-hardware-and-network)
- [How to actually find the bottleneck](#how-to-actually-find-the-bottleneck)

## 1. The small file problem

The most common serious problem in real clusters, and the one with the worst
symptoms.

The NameNode holds roughly **150 bytes of heap per file, block and directory**.
Ten million 4 KB files consume the metadata budget of a petabyte of properly sized
data while storing 40 GB. The NameNode heap fills, GC pauses lengthen, and every
client sees a slow cluster.

It hurts compute too: one map task per split, one split per file. Ten million tiny
files means ten million tasks whose JVM startup cost exceeds the work each does.

Fixes, in order of preference:

1. **Fix the writer.** Batch at the ingest boundary — Flume/NiFi/Kafka Connect
   roll-over thresholds, or a Spark job with sensible `coalesce`. Everything else
   is cleanup after the fact.
2. **Container formats.** Parquet, ORC or Avro with target file sizes at or above
   the block size. This also buys columnar pruning.
3. **Compaction jobs.** Periodic merges of yesterday's small partitions. Standard
   practice on a Hive warehouse.
4. **HAR archives** (`hadoop archive`). Reduce NameNode pressure but are clumsy to
   read and cannot be updated. A last resort.

Find out whether you have it:

```bash
# Total files and blocks — compare against your NameNode heap
hdfs dfsadmin -report | head -5
hdfs fsck / | grep -E 'Total (files|blocks)'

# Average block size; well under dfs.blocksize means small files
hdfs fsck / | grep 'Average block size'
```

## 2. Data locality

Reading a block from the local disk costs nothing on the network. Reading it from
another rack crosses your most contended link.

YARN prefers node-local placement automatically, but locality degrades when the
cluster is busy — there may be no free container on the node holding the data.
`yarn.scheduler.capacity.node-locality-delay` controls how many scheduling
opportunities to pass up while waiting for a local slot.

Check what you actually got in the job counters:

```
Data-local map tasks     1842
Rack-local map tasks      312
Other local map tasks       4
```

A high rack-local ratio usually means one of three things: the cluster is
saturated so nothing local was free; replication is too low to give the scheduler
choices; or the rack topology is wrong so everything looks equidistant.

That last one is worth checking first, because it is free to fix:

```bash
hdfs dfsadmin -report | grep Rack
# /default-rack everywhere means net.topology.script.file.name is not configured
```

With a flat topology, HDFS cannot make rack-aware placements *and* the scheduler
cannot make rack-aware decisions. You lose performance and rack-failure tolerance
simultaneously, with no warning anywhere in the UI.

## 3. Shuffle

Shuffle and sort is where MapReduce jobs spend their time. It is disk-heavy,
network-heavy, and the phase most worth tuning.

| Parameter | Default | Effect |
|---|---|---|
| `mapreduce.task.io.sort.mb` | 100 | Map-output buffer. Larger means fewer spills to disk |
| `mapreduce.map.sort.spill.percent` | 0.80 | Fill level that triggers a spill |
| `mapreduce.task.io.sort.factor` | 10 | Streams merged per pass. Higher means fewer passes, more open descriptors |
| `mapreduce.reduce.shuffle.parallelcopies` | 5 | Concurrent fetches per reducer |
| `mapreduce.reduce.shuffle.input.buffer.percent` | 0.70 | Share of reducer heap for shuffle data |
| `mapreduce.job.reduce.slowstart.completedmaps` | 0.05 | When reducers may start |

Two of these deserve more than a table row.

**`io.sort.mb` is taken from the task heap.** Setting it to 512 in a container
with `-Xmx614m` leaves 100 MB for everything else, and the task dies. Keep the
buffer well under the heap, and the heap at ~80% of the container.

**`slowstart` at its 0.05 default is usually wrong.** Reducers that start when 5%
of mappers are done sit idle, holding containers that mappers still need. On a
busy cluster this is self-inflicted starvation. 0.8 is a better default; go lower
only when the shuffle is genuinely the long pole and you want the copy phase
overlapped.

### The combiner

A local mini-reduce before anything crosses the network. In WordCount it collapses
5,000 emissions of `("the", 1)` into one `("the", 5000)`.

Measure it rather than assuming:

```
Combine input records    2400000
Combine output records     15000
```

That difference is network traffic you did not pay for.

The constraint is real: a combiner must be **associative and commutative**,
because the framework decides freely whether to run it, how often, and over which
subsets. `sum`, `min`, `max`, `count` are fine. `average` is not — and nothing in
the API will stop you writing it.

### Skew

If one reducer runs for an hour while the others finish in two minutes, the
problem is not shuffle configuration — it is that one key holds most of the data.
Tuning buffers will not help. Options: a custom partitioner, salting the hot key
across N reducers with a second aggregation pass, or handling the hot key
separately (a map-side join for the skewed value).

Skew is the single most common cause of "my job is slow" that no parameter fixes.

## 4. Compression

Usually the cheapest large win available.

| Codec | Ratio | Speed | Splittable | Use for |
|---|---|---|---|---|
| **Snappy** | low | very fast | no | Map output, intermediate data. Nearly always correct here |
| **LZ4** | low | very fast | no | Same, marginally faster |
| **Zstd** | good | fast | no | Modern default for stored data — the ratio of gzip near the speed of Snappy |
| **Gzip** | good | slow | no | Cold archives |
| **Bzip2** | best | very slow | **yes** | Rarely worth it; the speed penalty is severe |

```xml
<property>
  <name>mapreduce.map.output.compress</name>
  <value>true</value>
</property>
<property>
  <name>mapreduce.map.output.compress.codec</name>
  <value>org.apache.hadoop.io.compress.SnappyCodec</value>
</property>
```

**Splittability matters more than ratio for input data.** A 10 GB gzip file is one
split and therefore one map task, however large the cluster. The same data as
Parquet with Snappy block compression splits freely. This is the difference
between a job that scales and one that does not, and it is invisible until you
wonder why only one mapper is running.

Verify native codecs are actually loaded — the pure-Java fallbacks are much
slower and load silently:

```bash
hadoop checknative -a
```

## 5. File formats

| Format | Shape | When |
|---|---|---|
| Text/CSV | row, no schema | Ingest boundary only |
| SequenceFile | row, binary | Legacy intermediate data |
| Avro | row, schema | Streaming, schema evolution, whole-record reads |
| **Parquet** | columnar | Analytics — the default |
| **ORC** | columnar | Analytics, Hive-native, strong predicate pushdown |

Columnar formats win on analytical queries for two reasons: reading three of forty
columns touches three columns' worth of bytes, and per-column encoding compresses
far better than mixed row data. Combined with predicate pushdown, a well-organised
Parquet dataset routinely reads 5–20× fewer bytes than the CSV equivalent.

Partition by what you filter on — usually a date — and keep files at or above the
block size. Over-partitioning recreates the small file problem with extra steps.

## 6. Speculative execution

Re-runs a straggler on another node and takes whichever copy finishes first.

```xml
<name>mapreduce.map.speculative</name>      <value>true</value>
<name>mapreduce.reduce.speculative</name>   <value>false</value>
```

Worth having for maps on heterogeneous hardware, where one slow disk or a noisy
neighbour genuinely creates outliers.

Turn it off when tasks are slow for reasons duplication cannot fix — data skew,
or a task writing to an external system where running it twice is not idempotent.
Reduce speculation is off in this repository's cluster set because a duplicated
reducer re-fetches its entire shuffle input, which is expensive enough that it
rarely pays for itself.

## 7. JVM and garbage collection

### The NameNode

The heap holds the entire namespace, so it is large and long-lived — the profile
G1 was designed for.

```bash
export HDFS_NAMENODE_OPTS="-Xms8g -Xmx8g \
  -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+ParallelRefProcEnabled \
  -Xlog:gc*:file=/var/log/hadoop/namenode-gc.log:time,uptime:filecount=10,filesize=64M"
```

Three things matter:

- **`-Xms` equal to `-Xmx`.** Heap resizing on a NameNode causes pauses for no
  benefit.
- **G1 with a pause target.** A multi-second stop-the-world pause is
  indistinguishable from a NameNode outage to every client — and in an HA cluster
  it can trip a needless failover when the ZKFC loses its session.
- **GC logging, always on.** When the NameNode "hangs", the GC log is the first
  place to look, and enabling it after the fact is too late.

Size from object count: ~150 bytes per block/file/directory, plus generous
headroom. Raise it before you need to; a NameNode restart on a large cluster is a
planned event, not something to do under pressure.

### Container JVMs

Short-lived, small heaps. Defaults are fine. The one rule is heap ≈ 80% of the
container — see [04](04-configuration-reference.md#the-memory-arithmetic).

`mapreduce.job.jvm.numtasks` lets a JVM be reused across sequential tasks,
amortising startup. It mattered a great deal in Hadoop 1.x and much less now, but
it is still worth trying on jobs consisting of very many very short tasks.

### Host settings

| Setting | Value | Why |
|---|---|---|
| `vm.swappiness` | 1 | A swapped-out heap turns a 200 ms GC pause into tens of seconds |
| Transparent huge pages defrag | `never` | Stalls large heaps |
| `nofile` | 65536 | One descriptor per block replica plus per connection |

`scripts/10-install-prerequisites.sh` applies all three.

## 8. Hardware and network

- **JBOD, not RAID,** on DataNodes. HDFS replicates across machines already; RAID
  pays for redundancy twice and caps throughput at the slowest disk in the array.
- **More spindles beats bigger spindles.** Twelve 4 TB disks give twelve
  concurrent streams; three 16 TB disks give three.
- **SSD for NameNode metadata**, on RAID for the one component whose loss is
  unrecoverable. This is the one place RAID belongs.
- **10 GbE minimum within a rack.** Shuffle is all-to-all; a 1 GbE ToR uplink
  becomes the bottleneck for every job at once.
- **Size the spine for shuffle, not for ingest.** Peak inter-rack traffic is a
  shuffle, not a data load.
- **Erasure coding for cold data.** RS(6,3) stores 9 blocks where 3× replication
  stores 18 — 50% overhead instead of 200%. Reconstruction reads are far more
  expensive, so it suits archives, not working sets.

## How to actually find the bottleneck

Guessing at parameters is the slow path. Measure first.

**1. Read the counters.** Every job prints them, and they answer most questions
before you open a UI:

```bash
mapred job -counter <job_id> org.apache.hadoop.mapreduce.TaskCounter REDUCE_INPUT_RECORDS
```

| Counter | What a bad value tells you |
|---|---|
| `Rack-local map tasks` high | Locality is failing — topology, replication, or saturation |
| `Spilled Records` ≫ map output | `io.sort.mb` too small; heavy disk churn in the map phase |
| `Combine input` ≈ `Combine output` | The combiner is not helping — reconsider it |
| `GC time elapsed` a large share of CPU | Container heap too small, or object churn in your code |
| `Physical memory bytes` near the container | About to be killed; raise the container, not the heap |

**2. Compare task durations, not the total.** The ResourceManager UI shows
per-task timing. One reducer at 10× the median is skew; all tasks uniformly slow
is a resource or configuration problem. These have completely different fixes and
the job total cannot distinguish them.

**3. Check the cluster before the job.** `./scripts/health-check.sh`. An
under-replicated cluster, an unhealthy NodeManager or a full disk explains more
slowdowns than any tuning parameter.

**4. Then change one thing at a time.** Tuning five parameters at once tells you
nothing about which one mattered.

Next: [08 — Monitoring](08-monitoring.md) ·
[09 — Troubleshooting](09-troubleshooting.md)
