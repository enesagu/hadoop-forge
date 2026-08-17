# Documentation

Read these in order the first time; use them as reference afterwards.

| Document | What it answers |
|---|---|
| [01 — Architecture](01-architecture.md) | How HDFS, YARN and MapReduce actually work internally |
| [02 — Bare-metal installation](02-installation-bare-metal.md) | Installing on Ubuntu 22.04, single node then multi-node |
| [03 — Docker quickstart](03-docker-quickstart.md) | Bringing a cluster up in minutes with Compose |
| [04 — Configuration reference](04-configuration-reference.md) | Every parameter we set, why, and its production value |
| [05 — High availability](05-high-availability.md) | Active/Standby NameNode, JournalNode quorum, ZKFC, fencing |
| [06 — Security](06-security.md) | Kerberos, Ranger, wire encryption, encryption zones |
| [07 — Tuning](07-tuning.md) | Small files, locality, compression, speculative execution, GC |
| [08 — Monitoring](08-monitoring.md) | JMX, Prometheus, Grafana, and the alerts that matter |
| [09 — Troubleshooting](09-troubleshooting.md) | Symptom → cause → fix catalogue |
| [10 — Hadoop vs alternatives](10-hadoop-vs-alternatives.md) | When Hadoop is still the right answer |

## Conventions used throughout

- **Version:** Apache Hadoop 3.3.6, OpenJDK 11.
- **Install prefix:** `/opt/hadoop` (`$HADOOP_HOME`).
- **Data directories:** `/data/hdfs/{namenode,datanode,tmp}`.
- **Service account:** `hadoop`, never `root`.
- Commands prefixed `$` run as the `hadoop` user; `#` means root/sudo.
