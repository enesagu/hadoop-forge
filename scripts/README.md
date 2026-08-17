# Scripts

Numbered scripts run in order and are individually re-runnable. Unnumbered ones
are tools you use afterwards.

| Script | Runs as | Purpose |
|---|---|---|
| `00-preflight.sh` | any user | Read-only readiness report: OS, Java, RAM, disk, ports, SSH |
| `10-install-prerequisites.sh` | root | JDK 11, OpenSSH, rsync, Snappy, ulimits, swappiness, THP |
| `20-create-hadoop-user.sh` | root | `hadoop` service account and `/data/hdfs` directories |
| `30-setup-ssh.sh` | `hadoop` | ed25519 key, `authorized_keys`, client config, worker distribution |
| `40-install-hadoop.sh` | root | Download, SHA-512 verify, unpack to `/opt/hadoop`, shell exports |
| `50-apply-config.sh` | root | Install a `conf/` set, validate XML, reject duplicate properties |
| `60-format-and-start.sh` | `hadoop` | Format once, start HDFS/YARN/JobHistory, wait for safe mode |
| `install-pseudo-distributed.sh` | root | Runs 00–60 end to end, then the smoke test |
| `distribute-config.sh` | `hadoop` | rsync `etc/hadoop` to workers; `--check` for a dry run |
| `health-check.sh` | `hadoop` | Daemons, safe mode, block health, DataNode and NodeManager state |
| `smoke-test.sh` | `hadoop` | End-to-end HDFS write/read plus a real MapReduce job |
| `teardown.sh` | `hadoop` | Stop daemons; `--purge-data` for a clean slate |

## Conventions

- `set -euo pipefail` everywhere, via `lib/common.sh`.
- Guards, not comments: a step that must not run as root calls `refuse_root`.
- Idempotent. Re-running prints `[ skip ]` for work already done.
- Destructive actions require an explicit opt-in — `FORGE_FORCE_FORMAT=1`,
  `--purge-data` — and then still confirm interactively.
- `FORGE_ASSUME_YES=1` answers those confirmations for CI.

## Overridable settings

Export before invoking, or place in a `.env` you source yourself:

| Variable | Default |
|---|---|
| `HADOOP_VERSION` | `3.3.6` |
| `HADOOP_HOME` | `/opt/hadoop` |
| `HADOOP_USER` / `HADOOP_GROUP` | `hadoop` |
| `HADOOP_DATA_ROOT` | `/data/hdfs` |
| `JAVA_PACKAGE` | `openjdk-11-jdk` |
| `HADOOP_MIRROR` | `https://downloads.apache.org/hadoop/common` |
