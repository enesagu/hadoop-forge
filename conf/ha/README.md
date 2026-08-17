# HA configuration set

An **overlay** on [`../cluster`](../cluster), not a standalone set.
`scripts/50-apply-config.sh ha` installs the cluster set first and then these
files on top, so YARN and MapReduce sizing, the rack script and the include and
exclude host lists are all inherited.

| File | Replaces | Adds |
|---|---|---|
| `core-site.xml` | cluster's | Nameservice as `fs.defaultFS`, ZooKeeper quorum |
| `hdfs-site.xml` | cluster's | NameNode pair, JournalNode quorum, failover proxy, fencing |
| `yarn-site.xml` | cluster's | ResourceManager pair, ZK state store, work-preserving recovery |

## Hosts this set assumes

| Name | Role |
|---|---|
| `nn1`, `nn2` | NameNode + ZKFC + ResourceManager |
| `jn1`, `jn2`, `jn3` | JournalNode |
| `zk1`, `zk2`, `zk3` | ZooKeeper |
| `worker1..N` | DataNode + NodeManager |

Rename the nameservice (`forge-ns`) and these hostnames to match your
environment. The nameservice ID appears in five property **names**, not just
values — `dfs.ha.namenodes.forge-ns`,
`dfs.namenode.rpc-address.forge-ns.nn1` and so on — so a partial rename produces
a cluster that starts and then cannot elect a leader.

## Before applying

ZooKeeper and the JournalNodes are prerequisites, not part of this set. Bring the
JournalNode quorum up **before** the NameNodes: a NameNode with nowhere to write
its edits exits during startup.

Full sequence, including the `-bootstrapStandby` step that must not be a
`-format`: [docs/05-high-availability.md](../../docs/05-high-availability.md).
