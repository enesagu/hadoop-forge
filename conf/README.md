# Configuration sets

Four self-contained configuration sets. Each directory is copied verbatim into
`$HADOOP_HOME/etc/hadoop/` (or bind-mounted there in Docker) — never merge them.

| Set | Target | `fs.defaultFS` | Replication |
|---|---|---|---|
| [`pseudo/`](pseudo) | One machine, every daemon in its own JVM | `hdfs://localhost:9000` | 1 |
| [`cluster/`](cluster) | Bare-metal multi-node: `master` + `worker1..3` | `hdfs://master:9000` | 3 |
| [`docker/`](docker) | Compose topology, daemons in separate containers | `hdfs://namenode:9000` | 3 |
| [`ha/`](ha) | Active/Standby NameNodes over a JournalNode quorum | `hdfs://forge-ns` | 3 |

Applied with:

```bash
./scripts/50-apply-config.sh pseudo     # or cluster / ha
```

Every parameter is explained in
[docs/04-configuration-reference.md](../docs/04-configuration-reference.md).
The XML comments here state *why* a value was chosen; the reference table states
what to change for production.

## A note on the learning-mode shortcuts

The `pseudo` and `docker` sets deliberately relax two things so that a laptop
cluster is usable:

- `dfs.permissions.enabled=false` — no POSIX permission checks.
- `hadoop.security.authentication=simple` — anyone can claim any username via
  `HADOOP_USER_NAME`.

Both are called out inline and must be inverted before any real deployment. See
[docs/06-security.md](../docs/06-security.md).
