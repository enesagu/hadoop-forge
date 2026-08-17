# 05 — High availability

A single NameNode is a single point of failure. Not "a risk" — the namespace is
the only thing that knows where blocks live, so when it dies, every byte on every
DataNode becomes unreachable. Designing a production cluster without HA is not a
defensible trade-off.

Configuration set: [`conf/ha/`](../conf/ha). It overlays `conf/cluster/`.

## Contents

- [The topology](#the-topology)
- [How the pieces work](#how-the-pieces-work)
- [Fencing and split brain](#fencing-and-split-brain)
- [Bringing HA up](#bringing-ha-up)
- [Operating it](#operating-it)
- [ResourceManager HA](#resourcemanager-ha)

## The topology

```
        ┌──────────── ZooKeeper ensemble ────────────┐
        │      zk1          zk2          zk3         │
        └──────┬─────────────┬────────────┬──────────┘
               │  leader election (ZKFC)  │
        ┌──────▼──────┐              ┌────▼────────┐
        │  nn1 ACTIVE │              │ nn2 STANDBY │
        │   + ZKFC    │              │   + ZKFC    │
        └──────┬──────┘              └────┬────────┘
     writes    │                          │  tails
     EditLog   │                          │  EditLog
        ┌──────▼──────────────────────────▼──────────┐
        │   jn1          jn2          jn3            │
        │        JournalNode quorum                  │
        └────────────────────────────────────────────┘

     DataNodes heartbeat and block-report to BOTH NameNodes.
```

Note what is **absent**: there is no Secondary NameNode. Checkpointing — its only
job — is performed by the Standby.

| Role | Count | Why that count |
|---|---|---|
| NameNode | 2 (Hadoop 3 allows more) | One Active, one Standby |
| JournalNode | 3, 5 — always odd | A quorum of N tolerates (N−1)/2 losses; 4 costs more than 3 and tolerates the same one |
| ZooKeeper | 3, 5 — always odd | Same arithmetic |
| ZKFC | 1 per NameNode | Runs beside the NameNode it manages |

Spread the JournalNode and ZooKeeper ensembles **across racks**. Putting all three
in one rack means the rack failure you were protecting against takes the quorum
with it, and a NameNode that cannot reach a journal quorum shuts itself down
rather than risk diverging.

## How the pieces work

### The shared edit log

The Active NameNode writes each EditLog transaction to the JournalNode quorum and
only acknowledges the client once a **majority has persisted it**. The Standby
continuously tails the same journal, so its in-memory namespace stays within
seconds of the Active's.

```xml
<name>dfs.namenode.shared.edits.dir</name>
<value>qjournal://jn1:8485;jn2:8485;jn3:8485/forge-ns</value>
```

An NFS mount can serve this role instead (`NFS`-based HA), but it reintroduces a
single point of failure — precisely what HA exists to remove.

### Nameservice addressing

```xml
<name>fs.defaultFS</name>
<value>hdfs://forge-ns</value>
```

Clients address the **service**, never a NameNode host. The client-side
`ConfiguredFailoverProxyProvider` tries each configured NameNode and uses
whichever answers as Active. There is no load balancer and no virtual IP — the
failover happens in the client library.

This is why a `fs.defaultFS` pointing at a hostname defeats HA completely, and
why every client's `hdfs-site.xml` must know the nameservice members.

### Why DataNodes report to both

Each DataNode heartbeats and block-reports to **every** NameNode. The Standby
therefore already has a complete, current block map. If it did not, promotion
would mean waiting for a full block report cycle — minutes of unavailability on a
large cluster — which would make failover nearly pointless.

### ZKFC and leader election

The ZKFailoverController runs beside each NameNode and does three things: health
checks its local NameNode, holds an ephemeral ZooKeeper lock while that NameNode
is Active, and initiates failover when the lock is lost.

```xml
<name>ha.zookeeper.session-timeout.ms</name>
<value>10000</value>
```

This value is a genuine trade-off. Too short and a long GC pause on the Active
triggers a needless failover. Too long and a real outage lasts longer than it
needs to. Ten seconds is a reasonable default *given* that the NameNode heap is
tuned with G1 and bounded pause times — see
[`conf/cluster/hadoop-env.sh`](../conf/cluster/hadoop-env.sh).

## Fencing and split brain

This is the part that gets skipped, and the reason skipping it is expensive.

**A NameNode that stops responding is not necessarily dead.** It may be in a
multi-second GC pause, or partitioned from ZooKeeper while still perfectly
reachable by DataNodes and clients. Promote the Standby without dealing with the
old Active and you have two nodes that both believe they are Active — *split
brain* — and a namespace that diverges.

Hadoop defends in two independent layers:

**1. Epoch numbers in the journal.** Every NameNode that becomes Active claims a
new, higher epoch number from the JournalNodes. The quorum then refuses writes
carrying an older epoch. This makes namespace *corruption* impossible: the
deposed Active physically cannot commit another transaction.

**2. Fencing.** The epoch check stops writes but not reads. A zombie Active can
still answer client queries with a namespace that is now stale. Fencing removes
it:

```xml
<name>dfs.ha.fencing.methods</name>
<value>sshfence
shell(/bin/true)</value>
```

`sshfence` connects to the old Active and kills the process holding the NameNode
port. `shell(/bin/true)` is a fallback meaning "proceed even if sshfence could
not run" — acceptable only because the epoch check backs it up. In a Kerberised
or partition-prone environment, replace it with a real STONITH-style power fence;
"the network is broken" is exactly the scenario where SSH-based fencing cannot
work.

## Bringing HA up

Order matters. Each step depends on the previous one being complete.

```bash
# 1. Configuration on every node
sudo ./scripts/50-apply-config.sh ha
./scripts/distribute-config.sh

# 2. Start the JournalNode quorum FIRST — a NameNode with nowhere to write its
#    edits refuses to start.
#    On jn1, jn2, jn3:
hdfs --daemon start journalnode

# 3. On the first NameNode only: initialise the namespace
hdfs namenode -format -clusterId forge-cluster
hdfs --daemon start namenode

# 4. On the second NameNode: copy the namespace from the first. Do NOT format it
#    — two independently formatted NameNodes have different cluster IDs and will
#    never join the same nameservice.
hdfs namenode -bootstrapStandby
hdfs --daemon start namenode

# 5. Initialise the ZooKeeper znode used for election, once, from either
#    NameNode.
hdfs zkfc -formatZK

# 6. Start a ZKFC beside each NameNode.
hdfs --daemon start zkfc

# 7. DataNodes
hdfs --daemon start datanode      # on every worker

# 8. Verify
hdfs haadmin -getAllServiceState
```

Expected output:

```
nn1:8021    active
nn2:8021    standby
```

### The two mistakes that cost an afternoon

- **Formatting the second NameNode.** Use `-bootstrapStandby`. Two formats mean
  two cluster IDs and a nameservice that never converges.
- **Starting NameNodes before JournalNodes.** The NameNode has nowhere to write
  edits and exits. The log says so, but it says so in the middle of a stack
  trace.

## Operating it

```bash
# State of every NameNode
hdfs haadmin -getAllServiceState

# Health of one
hdfs haadmin -checkHealth nn1

# Planned failover — this fences the current Active first
hdfs haadmin -failover nn1 nn2

# Journal quorum lag: the Standby should be within a few transactions
hdfs dfsadmin -metasave /tmp/metasave.txt
```

**Test failover before you need it.** A configuration that has never failed over
is a configuration that does not work; fencing in particular fails silently until
exercised. Kill the Active NameNode process and watch:

```bash
# On the Active
jps | grep NameNode
kill -9 <pid>

# From a client — writes should resume within seconds
hdfs dfs -put /etc/hostname /tmp/failover-test
hdfs haadmin -getAllServiceState
```

Watch the ZKFC log on the surviving node. It will record the lost lock, the
fencing attempt and the transition. If fencing was skipped, the log says so — and
that is what you are testing for.

## ResourceManager HA

NameNode HA alone still loses the cluster when the ResourceManager dies: nothing
can be scheduled. [`conf/ha/yarn-site.xml`](../conf/ha/yarn-site.xml) adds an
Active/Standby RM pair, again elected through ZooKeeper, with the failover
controller embedded in the RM process rather than a separate daemon.

Two properties do the heavy lifting:

```xml
<name>yarn.resourcemanager.store.class</name>
<value>...recovery.ZKRMStateStore</value>

<name>yarn.resourcemanager.work-preserving-recovery.enabled</name>
<value>true</value>
```

The state store lets the newly Active RM recover running applications instead of
killing every job in flight. Work-preserving recovery keeps the **containers
themselves** alive across the transition rather than re-running them. Together
they turn an RM failover from a multi-minute setback into a pause your users may
not notice.

```bash
yarn rmadmin -getAllServiceState
yarn rmadmin -failover rm1 rm2
```

Next: [06 — Security](06-security.md)
