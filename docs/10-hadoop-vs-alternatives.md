# 10 — Hadoop versus the alternatives

"Is Hadoop dead?" is the wrong question, and answering it either way gets you into
trouble. The accurate version: **raw MapReduce lost to Spark, HDFS lost new
greenfield projects to object storage, and the architectural ideas underneath both
became load-bearing infrastructure everywhere else.**

## Contents

- [What actually happened](#what-actually-happened)
- [The comparison](#the-comparison)
- [Choosing](#choosing)
- [Where the ideas went](#where-the-ideas-went)

## What actually happened

Three separate shifts get compressed into "Hadoop died", and they had different
causes.

**MapReduce lost to Spark, decisively.** MapReduce writes to disk between every
stage. A five-stage pipeline is five full materialisations. Spark keeps
intermediates in memory and only spills when it must, which for iterative
workloads — most machine learning, most graph processing — is an order of
magnitude difference. Nobody writes new raw MapReduce jobs, and this is the one
part of "Hadoop is dead" that is simply true.

**HDFS lost greenfield to object storage, on economics.** HDFS couples storage to
compute: to store more you buy machines with CPUs you may not need. S3, ADLS and
GCS decouple them, cost less per terabyte, need no operator, and scale without
planning. The trade-off is real — object stores have higher latency, eventual
consistency in some operations, and no true rename — but for most workloads the
economics win outright.

**YARN lost mindshare to Kubernetes,** for reasons that have little to do with
Hadoop. Organisations wanted one scheduler for everything, not a data-specific
one. Spark on Kubernetes is now the common deployment.

And what did **not** happen: HDFS did not disappear from the installed base. On-
premise finance, telecoms, healthcare and public sector estates run petabytes on
HDFS today, often for regulatory reasons that no cloud migration resolves. That is
not legacy in the pejorative sense; it is infrastructure with a decade of tooling
built on it.

## The comparison

| | **Hadoop** (HDFS+YARN+MR) | **Spark on YARN/K8s** | **Object storage + engine** (S3 + Trino/Databricks) |
|---|---|---|---|
| Storage | Disk, replicated, coupled to compute | None of its own — uses HDFS or S3 | Decoupled, elastic, effectively unbounded |
| Compute | Disk-materialising batch | In-memory DAG, batch + streaming | Whatever engine you attach |
| Latency | Minutes | Seconds to minutes | Seconds to minutes |
| Ops burden | High — hardware, upgrades, NameNode heap, capacity planning | Medium | Low with managed services |
| Cost model | CapEx: buy the cluster | Infrastructure-dependent | OpEx: pay per query and per GB |
| Scaling | Add machines, rebalance | Elastic on K8s | Elastic by default |
| Data locality | Genuine — computation goes to the data | Partial | None; every read crosses the network |
| Best at | Large sequential scans on owned hardware | Iterative and mixed batch/streaming | Elastic analytics, separated storage and compute |
| Worst at | Small files, low latency, elasticity | Being a storage layer | Locality-sensitive work, very high-frequency small reads |

Two rows deserve elaboration.

**Data locality is Hadoop's remaining genuine advantage,** and cloud architectures
simply abandoned it. Fast networks made "just read it over the network" acceptable,
and separating storage from compute was worth more than the locality it cost. But
on a large sequential scan over owned hardware, nothing beats reading from the
local disk.

**Cost model is why the answer differs by organisation, not by technology.** A
cluster you already own has a marginal query cost near zero. The same query on
managed cloud compute has a per-run price. Depending on utilisation, either can be
several times cheaper, and neither is universally right.

## Choosing

### Hadoop/HDFS still makes sense when

- Data cannot leave your premises — regulation, sovereignty, contractual terms.
- You already own the hardware, and it is depreciating whether used or not.
- The workload is large sequential scans, where locality genuinely pays.
- A decade of Hive, Oozie and Sqoop tooling already runs against it. "Migrate
  everything" is a multi-year programme, not a decision.

### Spark makes sense when

- Iterative algorithms, where MapReduce's per-stage disk writes dominate.
- Batch and streaming need to share one codebase.
- You want SQL, DataFrames and MLlib in one engine.
- It runs happily on YARN over HDFS, so this is rarely an either/or with Hadoop.

### Cloud object storage plus a compute engine makes sense when

- New project, no existing estate to preserve.
- Load is spiky — paying for idle capacity is the dominant cost.
- Storage and compute genuinely need to scale independently.
- You would rather not employ anyone to think about NameNode heap.

### The lakehouse question

Iceberg, Delta Lake and Hudi add ACID transactions, schema evolution and time
travel over object storage — the warehouse semantics that plain files lacked.
This is where new architecture is happening, and it is worth knowing that **the
table formats work on HDFS too**. Iceberg over HDFS is a legitimate way to
modernise an existing estate without moving a byte, and it is frequently
overlooked in favour of a full migration.

## Where the ideas went

This is the real reason to learn Hadoop's internals even if you never operate a
cluster. The mechanisms are everywhere:

| Hadoop idea | Where you meet it again |
|---|---|
| Replication across failure domains | Kafka replicas, Cassandra, etcd, every cloud storage service |
| Leader election with a quorum | ZooKeeper, etcd/Raft, Kubernetes control plane |
| Fencing to prevent split brain | Every HA database, every distributed lock |
| Partition, shuffle, sort, merge | Spark, Flink, Presto/Trino — same phases, different implementation |
| Data locality as a scheduling input | Kafka rack awareness, Kubernetes topology-aware scheduling |
| Master holding metadata, workers holding data | Kafka controller, Elasticsearch master nodes, HBase |
| Heartbeat plus timeout for liveness | Every orchestrator ever written |
| Write-ahead log with checkpointing | PostgreSQL, Kafka, RocksDB, etcd |
| Speculative execution | Google's tail-latency work, hedged requests in gRPC |

That is the honest case for this repository. Learning the block report, the write
pipeline, the epoch-number fencing and the shuffle is not learning a 2010
technology. It is learning the vocabulary that Kafka, Kubernetes, Cassandra and
every lakehouse assume you already have.

## One-paragraph summary

Do not build a new platform on MapReduce. Do not assume HDFS is gone — a large
share of the world's regulated data sits on it, and will for years. Do learn how
both work, because the failure modes they were designed around have not changed,
and neither have the mechanisms for surviving them.

Back to the [documentation index](README.md).
