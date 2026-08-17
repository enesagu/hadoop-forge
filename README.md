<h1 align="center">hadoop-forge</h1>

<p align="center">
  <strong>Apache Hadoop 3.3.6, from the inside out.</strong><br>
  Reproducible clusters, annotated configuration, and the distributed-systems
  reasoning behind every knob.
</p>

<p align="center">
  <a href="https://github.com/enesagu/hadoop-forge/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/enesagu/hadoop-forge/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="Hadoop 3.3.6" src="https://img.shields.io/badge/Hadoop-3.3.6-66CCFF">
  <img alt="Java 11" src="https://img.shields.io/badge/Java-11-orange">
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <a href="README.tr.md"><img alt="Türkçe" src="https://img.shields.io/badge/doc-Türkçe-red"></a>
</p>

---

Most Hadoop tutorials give you commands to paste. This one gives you a cluster you
can break on purpose, configuration that explains itself, and documentation that
says *why* 128 MB blocks, *why* three replicas in that particular placement, and
*why* your job is stuck in `ACCEPTED`.

Two minutes to a running cluster:

```bash
git clone https://github.com/enesagu/hadoop-forge.git
cd hadoop-forge
make up      # 3 DataNodes, 2 NodeManagers, HDFS + YARN + JobHistory
make smoke   # HDFS round trip verified by checksum, then a real MapReduce job
```

| UI | Address |
|---|---|
| NameNode | http://localhost:9870 |
| ResourceManager | http://localhost:8088 |
| JobHistory | http://localhost:19888 |

Prefer bare metal? `sudo ./scripts/install-pseudo-distributed.sh` on Ubuntu 22.04.

## What is here

| | |
|---|---|
| **[docs/](docs)** | Ten documents: architecture internals, installation, configuration reference, HA, security, tuning, monitoring, troubleshooting |
| **[docker/](docker)** | One multi-role image; single-node and multi-node Compose topologies |
| **[conf/](conf)** | Four configuration sets — `pseudo`, `cluster`, `docker`, `ha` — every property commented with its rationale |
| **[scripts/](scripts)** | Numbered, idempotent bare-metal installers plus health check, smoke test and teardown |
| **[examples/](examples)** | A production-shaped WordCount job with unit tests, and a guided HDFS command tour |
| **[monitoring/](monitoring)** | Prometheus and Grafana, provisioned, with alert rules |
| **[tests/](tests)** | Static configuration validation — 86 checks, no cluster required |

## Everyday commands

```bash
make up / down / purge      # cluster lifecycle (purge deletes HDFS data)
make single                 # smaller pseudo-distributed topology (~3 GB)
make shell                  # client shell in the gateway container
make report / nodes         # hdfs dfsadmin -report / yarn node -list
make health                 # full health report
make smoke                  # end-to-end verification
make example && make wordcount
make monitoring-up          # + Prometheus and Grafana
make lint                   # everything CI checks
```

Add `TOPOLOGY=single` to point any of them at the single-node cluster.

## Where to start reading

**New to Hadoop** → [01 — Architecture](docs/01-architecture.md). The write
pipeline, rack-aware placement, and why block locations are never persisted.

**Need a cluster now** → [03 — Docker quickstart](docs/03-docker-quickstart.md),
then [things worth trying](docs/03-docker-quickstart.md#things-worth-trying) —
stop a DataNode and watch re-replication happen.

**Something is broken** → [09 — Troubleshooting](docs/09-troubleshooting.md).
Symptom first, with the causes the error message does not mention.

**Something is slow** → [07 — Tuning](docs/07-tuning.md). Ordered by impact, and
it ends on reading counters instead of guessing at parameters.

**Planning production** → [05 — High availability](docs/05-high-availability.md)
and [06 — Security](docs/06-security.md), in that order.

## Three things this repository insists on

**Formatting a NameNode is deletion.** Block locations live only in the
NameNode's memory, so a fresh namespace turns every stored block into unreachable
bytes. `scripts/60-format-and-start.sh` refuses to format over existing metadata
unless you set `FORGE_FORCE_FORMAT=1`, and then still asks.

**`simple` authentication is not weak security — it is none.** Any client that
reaches the NameNode can be any user with one environment variable. The clusters
here are deliberately unsecured teaching tools; see
[SECURITY.md](SECURITY.md) before attaching one to anything.

**Most YARN incidents are arithmetic.** Node capacity → scheduler ceiling →
container size → task heap → sort buffer. Break the chain anywhere and jobs hang
in `ACCEPTED` or get killed mid-flight. `tests/validate-configs.sh` checks it
statically, because that is much easier than diagnosing it at 3 a.m.

## Verified, not asserted

CI starts a real cluster on both topologies and runs the smoke test: a 12 MB
random payload written to HDFS and compared byte for byte on read, then a
MapReduce job whose word counts are asserted against known values. A cluster with
every daemon reporting healthy still cannot run a job if the shuffle aux-service
is missing — so the test runs one.

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md). The short version: comment the *why* inline,
keep scripts idempotent, and never let a learning-mode shortcut into
`conf/cluster`.

## License

[MIT](LICENSE) · Türkçe: **[README.tr.md](README.tr.md)**
