# 02 — Bare-metal installation

Target: **Ubuntu 22.04 LTS**, Apache Hadoop **3.3.6**, **OpenJDK 11**.

Two paths are covered: a single machine running every daemon in its own JVM
(*pseudo-distributed*), then extending that to four machines. If you only want a
cluster to poke at, use [03 — Docker quickstart](03-docker-quickstart.md)
instead; this document is about understanding what the installation actually
does.

## Contents

- [The one-command path](#the-one-command-path)
- [The steps, individually](#the-steps-individually)
- [Extending to a multi-node cluster](#extending-to-a-multi-node-cluster)
- [Starting and stopping](#starting-and-stopping)

## The one-command path

```bash
git clone https://github.com/enesagu/hadoop-forge.git
cd hadoop-forge
sudo ./scripts/install-pseudo-distributed.sh
```

That runs steps 00–60 in order, dropping to the `hadoop` user where root would
be wrong, and finishes with a smoke test. Every step is idempotent: if step 40
fails because a mirror was down, fix it and re-run the whole thing — completed
steps report `[ skip ]` and move on.

Set `FORGE_ASSUME_YES=1` to skip confirmation prompts in CI.

## The steps, individually

### 00 — Preflight

```bash
./scripts/00-preflight.sh
```

Read-only. It checks the distribution, the Java major version, RAM, free disk,
required commands, that the seven ports Hadoop wants are free, and whether
passwordless SSH to localhost already works. It is separate from the installer
because finding out about a port conflict *before* you have created system users
and unpacked 700 MB is worth the extra command.

### 10 — Prerequisites

```bash
sudo ./scripts/10-install-prerequisites.sh
```

Installs OpenJDK 11, the OpenSSH server and client, `rsync`, and native Snappy.
It also applies three host-level settings that matter more than they look:

| Setting | Why |
|---|---|
| `nofile` 65536 | A DataNode holds a descriptor per block replica plus one per connection. The default 1024 is exhausted by a real workload. |
| `vm.swappiness=1` | A swapped-out JVM heap turns a 200 ms GC pause into tens of seconds, which every client sees as an outage. |
| THP defrag off | Transparent huge page defragmentation stalls large heaps — precisely the NameNode's profile. |

### 20 — Service account

```bash
sudo ./scripts/20-create-hadoop-user.sh
```

Creates the `hadoop` user and group and the data directories under `/data/hdfs`.

Do not skip this and run as root. Every MapReduce container inherits the
daemon's identity, so a root NameNode means arbitrary user-submitted code
executing as root on every node in the cluster. The NameNode also refuses to
start if its metadata directory is group- or world-writable, which is why the
script sets mode `0700`.

### 30 — Passwordless SSH

```bash
sudo -iu hadoop /path/to/scripts/30-setup-ssh.sh
```

`start-dfs.sh` and `start-yarn.sh` use no cluster protocol to launch daemons.
They read the `workers` file and literally SSH to each host to run a command. No
passwordless SSH, no cluster — and the failure mode is a hang, not an error.

The script generates an ed25519 key, authorises it locally, and writes an
`~/.ssh/config` with `StrictHostKeyChecking accept-new` (so first contact does
not block on a prompt nothing can answer) plus connection multiplexing, which
matters once you are launching daemons across dozens of hosts.

It verifies `localhost`, `0.0.0.0` **and** the machine's own hostname, because
Hadoop's scripts use all three.

### 40 — Install the distribution

```bash
sudo ./scripts/40-install-hadoop.sh
```

Downloads `hadoop-3.3.6.tar.gz`, re-fetches its `.sha512` from Apache, and
refuses to install on mismatch. This is not ceremony: you are about to run this
tarball's shell scripts as a privileged service account on every node.

The script falls back from `downloads.apache.org` to `archive.apache.org`
(current releases live on the former, older ones move to the latter), unpacks
into a staging directory and moves the result into place so a failed extraction
never leaves a half-populated `/opt/hadoop`, and refuses to overwrite a different
version already installed there.

It then writes the environment block into `/home/hadoop/.bashrc` between
`# >>> hadoop-forge >>>` markers, rewriting it wholesale on each run instead of
appending a second copy.

### 50 — Apply configuration

```bash
sudo ./scripts/50-apply-config.sh pseudo   # or cluster / ha
```

Copies a whole set from [`conf/`](../conf) into `$HADOOP_HOME/etc/hadoop`, after
backing up what was there. Sets are never merged — a pseudo `hdfs-site.xml`
beside a cluster `core-site.xml` gives you a cluster that half-works, which is
worse than one that refuses to start.

Then it: pins `JAVA_HOME` in `hadoop-env.sh` to the path that actually exists on
this machine, validates every XML file with `xmllint`, and **fails on duplicate
`<name>` elements**. A duplicated property silently wins or loses by parse order
and is a miserable bug to chase in a live cluster.

### 60 — Format and start

```bash
sudo -iu hadoop /path/to/scripts/60-format-and-start.sh
```

`hdfs namenode -format` writes a fresh, empty namespace. Since block locations
live only in the NameNode, formatting a populated cluster leaves the blocks on
disk as unreachable bytes — it is deletion by another name. **The script
therefore refuses to format over existing metadata** unless you set
`FORGE_FORCE_FORMAT=1`, and even then it asks.

After starting HDFS, YARN and the JobHistory server it waits on
`hdfs dfsadmin -safemode wait`. The NameNode holds writes at startup until enough
block reports have arrived; racing it yields confusing "cannot create file"
errors. It finally creates `/user/$USER` and `/tmp/hadoop-yarn/staging`, whose
absence surfaces as a bare `Permission denied` that sends people hunting in the
wrong place.

Expected `jps` output:

```
NameNode
DataNode
SecondaryNameNode
ResourceManager
NodeManager
JobHistoryServer
```

| UI | Address |
|---|---|
| NameNode | http://localhost:9870 |
| ResourceManager | http://localhost:8088 |
| JobHistory | http://localhost:19888 |

## Extending to a multi-node cluster

Topology used by the `cluster` configuration set:

| Host | Roles |
|---|---|
| `master` | NameNode, SecondaryNameNode, ResourceManager, JobHistoryServer |
| `worker1` | DataNode, NodeManager |
| `worker2` | DataNode, NodeManager |
| `worker3` | DataNode, NodeManager |

### 1. Name resolution on every host

```
192.168.1.10  master
192.168.1.11  worker1
192.168.1.12  worker2
192.168.1.13  worker3
```

Half of all "the cluster will not come up" reports are name resolution. Every
host must resolve every other host, and each host's own name must **not** map to
`127.0.1.1` — Ubuntu's default `/etc/hosts` does exactly that, and a DataNode
that resolves itself to loopback registers a useless address with the NameNode.

### 2. Run steps 10, 20, 40 on every node

Every machine needs Java, the service account, the directories and the
distribution. Only the master needs steps 30 (as the key origin), 50 and 60.

### 3. Distribute the SSH key from the master

```bash
sudo -iu hadoop /path/to/scripts/30-setup-ssh.sh worker1 worker2 worker3
```

Passing hostnames makes the script run `ssh-copy-id` to each and then verify that
a `BatchMode=yes` connection actually succeeds — copying a key is not the same as
being able to log in with it.

### 4. Apply the cluster set on the master and push it out

```bash
sudo ./scripts/50-apply-config.sh cluster
./scripts/distribute-config.sh --check     # show drift first
./scripts/distribute-config.sh             # then sync
```

Review [`conf/cluster/`](../conf/cluster) before pushing. It assumes workers with
16 GB of RAM, 8 cores, and two data disks (`/data`, `/data2`). It also expects
`rack-topology.sh` to reflect your real racks — left at the defaults, every node
reports `/default-rack` and replica placement quietly degrades to "any three
nodes", losing rack-failure tolerance without any warning in the UI.

`--check` is a dry run that itemises drift. Use it before every sync on a
cluster you did not configure yourself.

### 5. Format and start, on the master only

```bash
sudo -iu hadoop /path/to/scripts/60-format-and-start.sh
```

`start-dfs.sh` starts the NameNode locally, then SSHes to each host in `workers`
to start DataNodes. `start-yarn.sh` does the same for the ResourceManager and
NodeManagers.

### 6. Verify

```bash
hdfs dfsadmin -report     # per-DataNode capacity, usage, Live/Dead
yarn node -list           # NodeManagers and their available resources
./scripts/health-check.sh # everything above plus safe mode and block health
```

`dfsadmin -report` is the single most useful command in HDFS operations. Confirm
that **all three** DataNodes are `Live` and that `Rack:` shows your real racks
rather than `/default-rack`.

Beyond about ten nodes, replace `distribute-config.sh` with Ansible or Puppet.
Hand-run rsync is how two nodes end up with a different `dfs.replication` than
the rest, and nobody notices for a month.

## Starting and stopping

```bash
start-dfs.sh   / stop-dfs.sh
start-yarn.sh  / stop-yarn.sh
mapred --daemon start historyserver / stop historyserver
```

Stop in reverse order — YARN first, then HDFS — so running applications are not
killed by the filesystem disappearing underneath them.

`./scripts/teardown.sh` stops everything, and with `--purge-data` also wipes
`/data/hdfs` for a clean re-install.

Next: [03 — Docker quickstart](03-docker-quickstart.md) ·
[04 — Configuration reference](04-configuration-reference.md)
