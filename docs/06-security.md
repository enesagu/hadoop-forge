# 06 — Security

A default Hadoop cluster has **no security at all**. Not weak security — none.
This is the single largest gap between the clusters in this repository and a
production one, and it is worth being blunt about why.

## Contents

- [What "simple" authentication actually means](#what-simple-authentication-actually-means)
- [Kerberos: authentication](#kerberos-authentication)
- [Ranger: authorisation](#ranger-authorisation)
- [Encryption in transit](#encryption-in-transit)
- [Encryption at rest](#encryption-at-rest)
- [The rest of the checklist](#the-rest-of-the-checklist)

## What "simple" authentication actually means

```xml
<name>hadoop.security.authentication</name>
<value>simple</value>
```

The client tells the NameNode which user it is. The NameNode believes it. That is
the entire protocol.

```bash
# On any machine that can reach the NameNode
HADOOP_USER_NAME=hdfs hdfs dfs -rm -r -skipTrash /
```

There is no password, no token, no challenge. `dfs.permissions.enabled=true` does
not help — permissions are enforced *against the identity the client claimed*.
File modes and ACLs are a guardrail against accident, not a security boundary.

So an unsecured Hadoop cluster reachable from your network is equivalent to giving
every host on that network root access to all of your data. The clusters here are
deliberately unsecured and deliberately local; do not attach one to a network you
do not fully control.

## Kerberos: authentication

Kerberos is the only supported way to make Hadoop actually authenticate. It is
not optional in a real deployment and it is not a small project — allow weeks,
not an afternoon.

### The model

Every participant — every daemon and every user — is a **principal** with
credentials issued by a **KDC** (Key Distribution Center):

| Kind | Example | Credential |
|---|---|---|
| Service | `nn/master.example.com@EXAMPLE.COM` | keytab file on disk |
| Service | `dn/worker1.example.com@EXAMPLE.COM` | keytab file on disk |
| User | `enes@EXAMPLE.COM` | password, `kinit` on demand |

Service principals include the **FQDN**, so every host needs correct forward and
reverse DNS. Broken reverse DNS is the most common reason a Kerberised cluster
will not start, and the error message is rarely about DNS.

Daemons authenticate non-interactively from a **keytab**: a file holding the
principal's long-term key. A keytab is a credential — mode `0400`, owned by the
service account, never in version control, never copied around casually.

### Enabling it, in outline

```xml
<!-- core-site.xml -->
<property>
  <name>hadoop.security.authentication</name>
  <value>kerberos</value>
</property>
<property>
  <name>hadoop.security.authorization</name>
  <value>true</value>
</property>
<property>
  <!-- Maps a principal to a local username. Getting these rules wrong is the
       second most common source of "authenticated but denied". -->
  <name>hadoop.security.auth_to_local</name>
  <value>RULE:[2:$1@$0](nn/.*@EXAMPLE.COM)s/.*/hdfs/
RULE:[2:$1@$0](dn/.*@EXAMPLE.COM)s/.*/hdfs/
DEFAULT</value>
</property>
```

```xml
<!-- hdfs-site.xml, per daemon -->
<property>
  <name>dfs.namenode.kerberos.principal</name>
  <value>nn/_HOST@EXAMPLE.COM</value>
</property>
<property>
  <name>dfs.namenode.keytab.file</name>
  <value>/etc/security/keytabs/nn.service.keytab</value>
</property>
```

`_HOST` is substituted with the local FQDN at runtime, which is what lets one
configuration file serve every node.

Then, as a user:

```bash
kinit enes@EXAMPLE.COM
klist                      # ticket present and not expired?
hdfs dfs -ls /
```

### What makes it a project rather than a setting

- **KDC deployment.** MIT Kerberos or Active Directory, itself needing HA.
- **Realm design**, and cross-realm trust if users live in AD while services live
  in an MIT realm.
- **Keytab generation and distribution** for every service on every host, with
  rotation.
- **DataNodes on privileged ports.** A secure DataNode traditionally binds ports
  below 1024 to prove it was started by root, requiring `jsvc` — or SASL data
  transfer protection instead, which is the modern route.
- **Every client** — Hive, Spark, Oozie, your Airflow workers, notebooks — needs
  a principal and a ticket-renewal story.
- **Ticket lifetimes** versus long-running jobs. This is what delegation tokens
  exist for: a job that outlives its ticket needs a renewable token, and jobs
  failing at the 10-hour mark is the symptom of getting it wrong.

This repository does not provision a KDC. Adding one to the Docker topology would
be a fine contribution, and it would roughly double the size of the stack.

## Ranger: authorisation

Kerberos answers *who are you*. It says nothing about *what may you touch*. HDFS
POSIX permissions and ACLs handle the basics; **Apache Ranger** replaces them with
central policy management and audit:

- One policy engine covering HDFS paths, Hive databases, tables and **columns**,
  HBase namespaces, Kafka topics, YARN queues.
- Attribute- and tag-based policies, so classification (via Atlas) drives access
  rather than paths.
- **Audit logs** of every allow and deny — usually the actual compliance
  requirement, more than the enforcement itself.
- Column masking and row filtering in Hive, which POSIX permissions cannot
  express at all.

Apache Sentry filled this role in older Cloudera stacks and is retired; new
deployments use Ranger.

## Encryption in transit

Three separate channels, three settings. Enabling one and assuming the others
follow is a common mistake.

```xml
<!-- hdfs-site.xml — DataNode block transfer -->
<property>
  <name>dfs.encrypt.data.transfer</name>
  <value>true</value>
</property>
<property>
  <name>dfs.encrypt.data.transfer.algorithm</name>
  <value>3des</value>   <!-- or rc4; AES via dfs.encrypt.data.transfer.cipher.suites -->
</property>
<property>
  <name>dfs.data.transfer.protection</name>
  <value>privacy</value>  <!-- authentication | integrity | privacy -->
</property>
```

```xml
<!-- core-site.xml — RPC -->
<property>
  <name>hadoop.rpc.protection</name>
  <value>privacy</value>
</property>
```

```xml
<!-- hdfs-site.xml / yarn-site.xml — web UIs and shuffle -->
<property>
  <name>dfs.http.policy</name>
  <value>HTTPS_ONLY</value>
</property>
<property>
  <name>yarn.http.policy</name>
  <value>HTTPS_ONLY</value>
</property>
```

The bulk data path is the expensive one to encrypt — it is the highest-volume
channel in the cluster. Measure the throughput cost before committing, and prefer
AES-NI-accelerated cipher suites where the hardware supports them.

## Encryption at rest

HDFS **Transparent Data Encryption** encrypts designated directories
(*encryption zones*) with keys held by a Key Management Server:

```bash
hadoop key create payroll-key -size 256
hdfs crypto -createZone -keyName payroll-key -path /data/payroll
```

Files written under `/data/payroll` are encrypted client-side; the DataNodes only
ever hold ciphertext, and the NameNode never sees a key.

Two properties of the design matter operationally:

- **The KMS becomes critical infrastructure.** Lose the keys and the data is
  gone — this is a feature, and it means the KMS needs HA and a tested key backup
  procedure of its own.
- **Encryption zones cannot be nested or created over existing data.** Create the
  zone first, then write into it. Retrofitting means copying data.

TDE protects against stolen disks and against an operator reading blocks off a
DataNode. It does **not** protect against a compromised authenticated client —
that is Ranger's job.

## The rest of the checklist

| Area | What to do |
|---|---|
| Network | Put the cluster on its own segment. Only edge and gateway nodes reachable from user networks; nothing else exposed |
| Web UIs | HTTPS with real certificates, behind SPNEGO or a reverse proxy. The NameNode UI is a browsable filesystem to anyone who reaches it |
| Service ACLs | `hadoop-policy.xml` — restrict which principals may call which protocol |
| Superuser | `dfs.permissions.superusergroup`, and a very short list of members |
| Impersonation | `hadoop.proxyuser.*` lets a service act as its users. Scope hosts and groups narrowly; a wildcard here is a full bypass |
| Audit | `hdfs-audit.log` shipped off-host, since a local log is editable by whoever compromised the host |
| Kernel/OS | Patching, SELinux/AppArmor, no interactive login on data nodes |
| Secrets | Keytabs mode `0400`, never in git, rotated |
| Backups | The FsImage. HDFS replication is not a backup — `rm -r` replicates too |

## The one-line summary

`hadoop.security.authentication=simple` is not a weak setting to be hardened
later. It means there is no authentication. Anything holding data you would mind
losing needs Kerberos from the start, and the clusters in this repository are
teaching tools that should stay on your laptop.

Next: [07 — Tuning](07-tuning.md)
