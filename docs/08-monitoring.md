# 08 — Monitoring and operations

What to watch, why it matters, and what to do when it moves. The stack that
implements this lives in [`monitoring/`](../monitoring).

```bash
make monitoring-up      # cluster + Prometheus + Grafana
```

## Contents

- [The built-in UIs](#the-built-in-uis)
- [Where metrics come from](#where-metrics-come-from)
- [The metrics that matter](#the-metrics-that-matter)
- [Alerts worth having](#alerts-worth-having)
- [Logs](#logs)
- [Routine operations](#routine-operations)

## The built-in UIs

Before any of this, learn the two pages that ship with Hadoop. On a small cluster
they answer most questions faster than a dashboard.

### NameNode — `:9870`

| Page | Read it for |
|---|---|
| **Overview** | Safe mode state, cluster ID, uptime, heap. First stop, always |
| **Summary** | Configured/used/remaining capacity, live and dead DataNodes, **under-replicated and missing blocks** |
| **Datanodes** | Per-node capacity, last contact, **rack**. `/default-rack` everywhere means topology is unconfigured |
| **Browse the filesystem** | A working file browser. Also, a reminder that anyone who reaches this port can read your data — see [06](06-security.md) |
| **Startup Progress** | Why a restart is taking so long: loading FsImage, replaying edits, waiting for block reports |

### ResourceManager — `:8088`

| Page | Read it for |
|---|---|
| **Cluster metrics** | Apps running/pending/failed, memory and vcores allocated versus total |
| **Scheduler** | Per-queue used versus guaranteed capacity. Where you see one tenant starving another |
| **Applications** | Per-app state, elapsed time, and the **counters** after completion |
| **Nodes** | NodeManager state. `UNHEALTHY` almost always means a full disk |

A habit worth forming: after a job finishes, open it and read the counters.
`Rack-local map tasks`, `Spilled Records` and `GC time elapsed` answer most
"why was it slow" questions without any additional tooling. See
[07 — Tuning](07-tuning.md#how-to-actually-find-the-bottleneck).

### JobHistory — `:19888`

The RM forgets applications when they leave. The JobHistory server keeps counters
and task-level timing, which is where post-mortem analysis actually happens.
Without it running, finished jobs vanish and the RM UI apologises unhelpfully.

## Where metrics come from

Every Hadoop daemon exposes its internal metrics three ways:

1. **JMX** — the canonical source. `http://namenode:9870/jmx` returns everything
   as JSON, which is genuinely useful for ad-hoc queries:

   ```bash
   curl -s http://localhost:9870/jmx | grep -i missingblocks
   ```

2. **`/prom`** — the same metrics in Prometheus text format, since Hadoop 3.1
   (`PrometheusMetricsSink`). This is what makes exporter sidecars unnecessary.

3. **Metrics sinks** — `hadoop-metrics2.properties` can push to Graphite,
   StatsD or a file. The pull model is easier to operate; use sinks when
   something already consumes them.

One caveat that costs people an afternoon: **the `/prom` metric names are derived
from JMX names by splitting camel case**, so they shift between versions.
`MissingBlocks` on the `FSNamesystem` record becomes
`fs_namesystem_missing_blocks`. Verify against your own cluster before trusting
any rule you copied from elsewhere, including from this repository:

```bash
curl -s http://localhost:9870/prom | grep -i missing
```

A rule whose expression matches nothing does not fail — it simply never fires,
which is the worst possible failure mode for an alert.

## The metrics that matter

### HDFS integrity — check these first

| Metric | Healthy | Meaning |
|---|---|---|
| `MissingBlocks` | **0** | Every replica of these blocks is gone. This is data loss, not a warning |
| `CorruptBlocks` | 0 | Checksum failures |
| `UnderReplicatedBlocks` | 0 sustained | Normal and transient after a node loss. A *persistent* value means too few live nodes |
| `NumDeadDataNodes` | 0 | Declared dead after ~10.5 minutes of missed heartbeats |
| `Safemode` | off | Read-only. Normal at startup, a problem if it persists |

The distinction between under-replicated and missing is the single most important
one on this page. Under-replicated is the system healing itself and is expected
after any node loss. Missing means the data is gone and no amount of waiting will
bring it back.

### NameNode heap

| Metric | Watch for |
|---|---|
| `MemHeapUsedM` / `MemHeapMaxM` | Sustained above 85% |
| `GcTimeMillis` (rate) | Growing share of wall-clock time |
| `FilesTotal`, `BlocksTotal` | The object count driving the heap |

Budget ~150 bytes of heap per block, file and directory. Two things make this
worth alerting on early rather than at 95%:

- Raising the heap requires a restart, and a NameNode restart on a large cluster
  is a planned event, not something to do under pressure.
- Rising object count with flat stored volume is the **small file problem**
  developing. Raising the heap treats the symptom; see
  [07](07-tuning.md#1-the-small-file-problem).

A long GC pause is indistinguishable from a NameNode outage to every client, and
in an HA cluster can trip a needless failover when the ZKFC loses its ZooKeeper
session.

### Capacity

| Metric | Threshold |
|---|---|
| `CapacityUsed / CapacityTotal` | 80% warn, 90% critical |
| Per-DataNode remaining | Watch the *most* full node, not the average |

Past ~90%, writes start failing with "could only be replicated to 0 nodes".
`dfs.datanode.du.reserved` protects the operating system from a full disk; it does
not protect the cluster from being full.

The average hides imbalance. A cluster at 60% average with one node at 98% has a
real problem — run the balancer:

```bash
hdfs balancer -threshold 10
```

### YARN

| Metric | Watch for |
|---|---|
| `NumUnhealthyNMs` | Any. Almost always disk utilisation past the health-check threshold; the node silently stops accepting containers |
| `AppsPending` | Sustained non-zero, especially with idle capacity |
| `AllocatedMB` vs `AvailableMB` | Fully allocated *with* pending apps is a sizing problem, not a capacity one |
| Per-queue usage vs guaranteed | One tenant starving another |

Applications pending while memory is available means the scheduler cannot satisfy
the *shape* of the request — a container larger than any single node can grant, or
a queue at its AM limit. See
[09 — Troubleshooting](09-troubleshooting.md#job-stays-in-accepted-forever).

## Alerts worth having

Ordered by what should wake someone up. Implemented in
[`monitoring/prometheus/alerts.yml`](../monitoring/prometheus/alerts.yml).

| Alert | Severity | Why |
|---|---|---|
| NameNode down | **critical, page** | Full cluster outage. Every block is unreachable without the namespace |
| Missing blocks > 0 | **critical, page** | Data loss already happened |
| ResourceManager down | critical | HDFS is fine; nothing can be scheduled |
| ≥2 DataNodes down | critical | With replication 3, the next one could mean permanent loss |
| HDFS > 90% | critical | Writes about to fail |
| Under-replicated for 30 min | warning | Healing has stalled |
| NameNode heap > 85% | warning | Plan the restart before it is urgent |
| Unhealthy NodeManager | warning | Capacity quietly shrinking |
| Apps pending 20 min | warning | Usually a misconfiguration, not load |
| HDFS > 80% | warning | Procurement lead time |

Two principles behind the choices:

**Long `for:` windows on transient conditions.** Under-replication after a node
restart is normal; a 30-minute window distinguishes healing from stuck. An alert
that fires during routine operations gets muted, and a muted alert is no alert.

**Prefer `up == 0` where you can.** `up` is synthesised by Prometheus and cannot
be wrong about the metric name. Expression-based rules can silently match nothing.

## Logs

### Locations

| What | Where |
|---|---|
| Daemon logs | `$HADOOP_LOG_DIR/hadoop-<user>-<daemon>-<host>.log` |
| GC logs | Wherever `-Xlog:gc*` points — set in `hadoop-env.sh` |
| Audit log | `hdfs-audit.log` — every namespace operation with its user |
| Container logs | Local until the app ends, then aggregated into HDFS |

### Container logs

```xml
<name>yarn.log-aggregation-enable</name>
<value>true</value>
```

This is the difference between

```bash
yarn logs -applicationId application_1234567890_0001
```

and SSH-ing to every node hunting for the container that failed. Turn it on.

Note the timing: logs move to HDFS **when the application finishes**. While a job
is running they are still on the NodeManagers, reachable through the RM UI's
per-container links.

### Habits worth having

- **Read the daemon log, not just the client error.** The client message is
  usually a symptom several layers removed from the cause.
- **Ship logs off-host.** A local log is editable by whoever compromised the host,
  and gone with the disk that failed.
- **Keep the audit log.** It is usually the actual compliance requirement, and it
  is the only record of who deleted what.
- **Enable GC logging before you need it.** Turning it on after the NameNode
  starts pausing is too late for the pause you are investigating.

## Routine operations

### Daily

```bash
./scripts/health-check.sh
```

Under-replicated block count, dead nodes, disk utilisation, unhealthy
NodeManagers. Five seconds, and it catches most developing problems.

### Weekly

```bash
hdfs fsck / | tail -30                 # block health summary
hdfs dfsadmin -report                  # per-node capacity
hdfs balancer -threshold 10            # if nodes have drifted apart
```

### Before any maintenance

```bash
hdfs dfsadmin -safemode enter          # read-only, stop the namespace changing
hdfs dfsadmin -saveNamespace           # checkpoint: merge EditLog into FsImage
# ... maintenance ...
hdfs dfsadmin -safemode leave
```

`saveNamespace` requires safe mode and shortens the next restart considerably.

### Decommissioning a node properly

```bash
echo worker3 >> $HADOOP_CONF_DIR/dfs.exclude
hdfs dfsadmin -refreshNodes
hdfs dfsadmin -report | grep -A5 worker3     # wait for Decommissioned
```

**Wait for the state to actually flip.** The NameNode re-replicates that node's
blocks elsewhere first; powering the machine off early turns a planned removal
into data at risk. On a full node this takes hours, not minutes.

### Backing up the namespace

```bash
hdfs dfsadmin -fetchImage /backup/fsimage-$(date +%F)
```

HDFS replication is not a backup — `hdfs dfs -rm -r` replicates faithfully to all
three copies. The FsImage is small and cheap to keep; keep it somewhere that is
not the cluster.

Next: [09 — Troubleshooting](09-troubleshooting.md)
