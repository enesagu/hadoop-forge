# 03 — Docker quickstart

The fastest way to a real cluster. One image serves six roles; which daemon runs
is decided by the entrypoint argument, so the whole topology shares a single
build and layer cache.

Requires Docker with Compose v2 and about **6 GB** of memory allocated to it
(3 GB for the single-node topology).

## Contents

- [Bring it up](#bring-it-up)
- [The two topologies](#the-two-topologies)
- [Everyday commands](#everyday-commands)
- [How the image works](#how-the-image-works)
- [Things worth trying](#things-worth-trying)
- [When it will not start](#when-it-will-not-start)

## Bring it up

```bash
git clone https://github.com/enesagu/hadoop-forge.git
cd hadoop-forge
make up          # builds the image on first run, then waits for health
make smoke       # HDFS write/read plus a real MapReduce job
```

| UI | Address |
|---|---|
| NameNode | http://localhost:9870 |
| ResourceManager | http://localhost:8088 |
| JobHistory | http://localhost:19888 |

No make? The equivalent is:

```bash
docker compose -f docker/docker-compose.yml up -d
docker compose -f docker/docker-compose.yml exec gateway bash
```

## The two topologies

| | `make up` | `make single` |
|---|---|---|
| Compose file | `docker/docker-compose.yml` | `docker/docker-compose.single.yml` |
| DataNodes | 3 | 1 |
| NodeManagers | 2 | 1 |
| `dfs.replication` | 3 | 1 |
| YARN capacity | 4 GB / 4 vcores | 2 GB / 2 vcores |
| Memory needed | ~6 GB | ~3 GB |

Use the multi-node one. It is the only one where replication, rack placement and
re-replication are observable — with a single DataNode there is nothing to
replicate to, and half of HDFS's interesting behaviour is invisible.

Both topologies share the same configuration in [`conf/docker/`](../conf/docker).
The single-node file does not duplicate the XML; it passes an override to the
entrypoint instead:

```yaml
HADOOP_CONF_OVERRIDES: |
  hdfs-site.xml:dfs.replication=1
```

Any `file.xml:key=value` line works, which is a convenient way to experiment with
a parameter without editing tracked files:

```yaml
HADOOP_CONF_OVERRIDES: |
  hdfs-site.xml:dfs.blocksize=8388608
  yarn-site.xml:yarn.nodemanager.resource.memory-mb=4096
```

## Everyday commands

```bash
make ps            # containers and their health state
make logs          # follow everything
make shell         # shell in the gateway (client) container
make report        # hdfs dfsadmin -report
make nodes         # yarn node -list
make health        # full health report
make smoke         # end-to-end verification
make wordcount     # run the example job from examples/
make pi            # bundled Pi estimator, a CPU-bound benchmark
make down          # stop, KEEPING HDFS data
make purge         # stop and delete the volumes
```

Add `TOPOLOGY=single` to point any of them at the single-node cluster.

`down` keeps the named volumes, so the namespace and blocks survive. Only
`purge` (`docker compose down -v`) destroys them.

## How the image works

### Foreground daemons

Every role `exec`s its daemon in the foreground — `hdfs namenode`, not
`hdfs --daemon start namenode`. The latter forks and exits, which would leave
Docker supervising a process that has already finished and reporting a healthy
container holding nothing.

### Ordering that actually waits

Compose's `depends_on` waits for a container to *start*, not for a daemon to be
*ready*. A DataNode that starts before the NameNode's RPC port is listening
retries with backoff and eventually gives up. So the entrypoint blocks on the
port it needs, and the Compose files gate on `condition: service_healthy`.

The NameNode's health check is deliberately not "does the web UI answer" — the UI
answers during safe mode too, when writes are still refused. It asks the daemon
directly:

```yaml
test: ["CMD-SHELL", "hdfs dfsadmin -safemode get | grep -q OFF"]
```

### Hostnames, not IPs

`dfs.datanode.use.datanode.hostname=true` makes DataNodes register by name.
Container IPs change on every recreate; the Compose service name does not. This
keeps the NameNode UI readable and block locations stable across restarts.

The daemons also bind `0.0.0.0` (`dfs.namenode.rpc-bind-host` and friends).
Without that they bind only the container's own hostname and the published host
ports reach nothing.

### 32 MB blocks

`conf/docker/hdfs-site.xml` sets `dfs.blocksize` to 32 MB rather than 128 MB.
Sample datasets are small, and at the default every file is a single block — you
never see multi-block files, split calculation, or more than one map task.

### Verified build

The Dockerfile fetches the distribution in a throwaway stage, checks its SHA-512
against the checksum published by Apache, and fails the build on mismatch.
Neither the 700 MB tarball nor `curl` ends up in the runtime layers.

## Things worth trying

**Watch re-replication.** With the cluster healthy, put a file in HDFS, then:

```bash
docker compose -f docker/docker-compose.yml stop datanode-3
make report          # datanode-3 goes Dead after ~10.5 minutes
```

The NameNode reports under-replicated blocks and schedules copies onto the
survivors. Start it again and the excess replicas are removed.

**See where blocks live.**

```bash
make shell
hdfs fsck /input -files -blocks -locations
```

**Watch the scheduler.** Submit two jobs at once and follow the queues in the
ResourceManager UI while containers are allocated and released.

**Break it on purpose.** Set `yarn.nodemanager.resource.memory-mb` below
`mapreduce.map.memory.mb` via `HADOOP_CONF_OVERRIDES` and submit a job. It sits
in `ACCEPTED` forever — the single most common YARN support ticket there is, and
worth recognising by sight.

## When it will not start

| Symptom | Cause |
|---|---|
| Containers restart in a loop, logs mention memory | Docker has less memory than the topology needs. Raise it or use `make single`. |
| `bind: address already in use` | Something local holds 9870/8088/9000. Override with `NAMENODE_UI_PORT=19870 make up`. |
| NameNode never becomes healthy | Stuck in safe mode because DataNodes have not reported. Check `make logs` for DataNode registration failures. |
| Jobs stay `ACCEPTED` | No NodeManager has enough free memory for the requested container. Compare `mapreduce.map.memory.mb` against `yarn.nodemanager.resource.memory-mb`. |
| `docker compose` unknown command | Compose v1. This repository uses v2 syntax; upgrade or set `COMPOSE="docker-compose"`. |

More in [09 — Troubleshooting](09-troubleshooting.md).

Next: [04 — Configuration reference](04-configuration-reference.md)
