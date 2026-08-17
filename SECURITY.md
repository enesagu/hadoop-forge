# Security

## The clusters in this repository are deliberately insecure

They use `hadoop.security.authentication=simple`, which is not weak
authentication — it is the **absence** of authentication. Any client that can
reach the NameNode can claim to be any user:

```bash
HADOOP_USER_NAME=hdfs hdfs dfs -rm -r -skipTrash /
```

`dfs.permissions.enabled` does not help: permissions are enforced against the
identity the client asserted.

**Do not attach these clusters to a network you do not fully control.** They are
teaching tools for a laptop. Production needs Kerberos from the start — see
[docs/06-security.md](docs/06-security.md).

The Grafana instance in `monitoring/` likewise ships with anonymous access and the
password `admin`, and neither it nor Prometheus uses TLS.

## Reporting a vulnerability

If you find a problem in this repository's own code — a script that could be
tricked into destroying data, a container that escalates privilege, an injection
in the config templating — open a **private** security advisory through GitHub's
"Report a vulnerability" on the Security tab rather than a public issue.

Vulnerabilities in Apache Hadoop itself belong upstream:
<https://hadoop.apache.org/mailing_lists.html> (`security@hadoop.apache.org`).

Insecure defaults that are documented as such above are not vulnerabilities;
undocumented ones are, and are worth reporting.
