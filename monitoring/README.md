# Monitoring

Prometheus and Grafana as an overlay on the multi-node cluster.

```bash
make monitoring-up
```

| Service | Address |
|---|---|
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3000 (anonymous viewer, or `admin`/`admin`) |

Grafana comes pre-provisioned with the Prometheus datasource and the **Hadoop
cluster overview** dashboard — no clicking required.

## Why there are no exporter sidecars

Hadoop 3.1+ serves Prometheus-format metrics natively at `/prom` on every
daemon's HTTP server, via `PrometheusMetricsSink`. So Prometheus scrapes the
daemons directly:

| Target | Endpoint |
|---|---|
| NameNode | `namenode:9870/prom` |
| DataNode | `datanode-N:9864/prom` |
| ResourceManager | `resourcemanager:8088/prom` |
| NodeManager | `nodemanager-N:8042/prom` |
| JobHistory | `historyserver:19888/prom` |

That is three containers instead of ten. On Hadoop 2.x, or with the endpoint
disabled, run `jmx_exporter` in httpserver mode against the JMX ports that
[`conf/cluster/hadoop-env.sh`](../conf/cluster/hadoop-env.sh) opens — 9010 for the
NameNode, 9011 DataNode, 9012 ResourceManager — and repoint the scrape jobs.

## Verify the metric names before trusting the alerts

`PrometheusMetricsSink` derives metric names from JMX record and attribute names
by splitting camel case, so they shift slightly between Hadoop versions. The
names in [`prometheus/alerts.yml`](prometheus/alerts.yml) and the dashboard follow
**Hadoop 3.3.6**. Confirm against your own cluster:

```bash
docker compose -f docker/docker-compose.yml exec namenode \
  curl -s localhost:9870/prom | grep -iE 'missing|under_replicated|capacity'

docker compose -f docker/docker-compose.yml exec resourcemanager \
  curl -s localhost:8088/prom | grep -iE 'unhealthy|apps_pending'
```

The `up`-based alerts need no verification — `up` is synthesised by Prometheus and
is always correct. Those also happen to be the most important ones: a daemon that
is gone matters more than any gauge.

Reload rule edits without a restart:

```bash
curl -X POST http://localhost:9090/-/reload
```

Then check **Status → Rules** in the Prometheus UI. A rule whose expression
matches no series shows up there rather than failing loudly, which is exactly how
a silently broken alert survives.

## Layout

```
monitoring/
├── docker-compose.monitoring.yml    overlay joining the cluster network
├── prometheus/
│   ├── prometheus.yml               scrape targets
│   └── alerts.yml                   alert rules, grouped by concern
└── grafana/
    ├── provisioning/
    │   ├── datasources/             Prometheus, uid pinned to "prometheus"
    │   └── dashboards/              file provider watching ../dashboards
    └── dashboards/
        └── hadoop-overview.json
```

Dashboard JSON is re-read every 30 seconds, so editing the file on disk is enough
— no import step.

## Security note

This stack is for a laptop. Anonymous Grafana access is on, the admin password is
`admin`, and neither service has TLS. Do not expose it. Real deployments need
authentication, TLS, and Alertmanager routing to somewhere a human reads.

Full guidance on what to watch and why:
[docs/08-monitoring.md](../docs/08-monitoring.md).
