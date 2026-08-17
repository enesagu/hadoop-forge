# hadoop-forge

A hands-on Apache Hadoop 3.3.6 workshop: reproducible clusters, annotated
configuration, and the distributed-systems reasoning behind every knob.

> Work in progress — the sections below land incrementally.

## What this repository will contain

- **Docker clusters** — pseudo-distributed and multi-node HDFS + YARN topologies
  that come up with a single command.
- **Bare-metal installers** — idempotent, numbered shell scripts that reproduce a
  production-shaped install on Ubuntu 22.04 LTS.
- **Annotated configuration** — `core-site`, `hdfs-site`, `mapred-site` and
  `yarn-site` sets for pseudo, cluster and HA modes, with the reasoning inline.
- **Examples** — a real MapReduce WordCount job, built with Maven and unit tested.
- **Operations** — health checks, smoke tests, Prometheus/Grafana monitoring, and
  a troubleshooting catalogue.

## License

[MIT](LICENSE)
