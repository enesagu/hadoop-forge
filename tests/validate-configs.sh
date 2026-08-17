#!/usr/bin/env bash
#
# Static validation of every configuration set. Needs no cluster, no Docker and
# no Java — it is the cheap gate that runs on every push.
#
#   bash tests/validate-configs.sh
#   make lint-xml
#
# Catches the class of mistake that otherwise surfaces as a daemon that starts
# and then behaves subtly wrong: malformed XML, a property defined twice, a
# reference to a file that does not exist, a container larger than any node can
# allocate.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "${REPO_ROOT}"

if [[ -t 1 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; Z=$'\033[0m'
else
  R=''; G=''; Y=''; B=''; Z=''
fi

FAILS=0
CHECKS=0

section() { printf '\n%s── %s %s\n' "$B" "$*" "$Z"; }
pass() { printf '  %s✓%s %s\n' "$G" "$Z" "$*"; CHECKS=$((CHECKS + 1)); }
warn() { printf '  %s!%s %s\n' "$Y" "$Z" "$*"; }
fail() { printf '  %s✗%s %s\n' "$R" "$Z" "$*"; FAILS=$((FAILS + 1)); CHECKS=$((CHECKS + 1)); }

# Read a single property's value out of a Hadoop XML file.
#
# Deliberately awk and not python or xmllint: this script is the cheap gate that
# has to run anywhere, including a bare CI container and Git Bash on Windows,
# neither of which reliably has python3. Hadoop's configuration format is regular
# enough that a real parser buys nothing here.
prop() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  awk -v key="$key" '
    { doc = doc " " $0 }
    END {
      n = split(doc, blocks, /<property>/)
      for (i = 2; i <= n; i++) {
        b = blocks[i]
        if (!match(b, /<name>[^<]*<\/name>/)) continue
        name = substr(b, RSTART + 6, RLENGTH - 13)
        gsub(/^[ \t]+|[ \t]+$/, "", name)
        if (name != key) continue
        if (match(b, /<value>[^<]*<\/value>/)) {
          value = substr(b, RSTART + 7, RLENGTH - 15)
          gsub(/^[ \t]+|[ \t]+$/, "", value)
          print value
        } else if (match(b, /<value><\/value>/)) {
          print ""
        }
        exit
      }
    }
  ' "$file"
}

# Every <name> in a file, one per line.
prop_names() {
  sed -n 's/.*<name>\([^<]*\)<\/name>.*/\1/p' "$1"
}

# First -Xmx value in a string, in MB.
xmx_mb() {
  sed -n 's/.*-Xmx\([0-9]\+\)m.*/\1/p' <<<"${1:-}" | head -n1
}

printf '%shadoop-forge configuration validation%s\n' "$B" "$Z"

# ---------------------------------------------------------------------------
section "XML is well-formed"
mapfile -t XML_FILES < <(find conf -name '*.xml' | sort)
(( ${#XML_FILES[@]} > 0 )) || { printf '%sNo XML found under conf/%s\n' "$R" "$Z"; exit 1; }

if command -v xmllint >/dev/null 2>&1; then
  for f in "${XML_FILES[@]}"; do
    if xmllint --noout "$f" 2>/dev/null; then
      pass "$f"
    else
      fail "$f is not well-formed XML"
      xmllint --noout "$f" || true
    fi
  done
else
  warn "xmllint not installed — falling back to a tag-balance check"
  for f in "${XML_FILES[@]}"; do
    balanced=1
    for tag in configuration property name value; do
      opens="$(grep -c "<${tag}>" "$f" || true)"
      closes="$(grep -c "</${tag}>" "$f" || true)"
      (( opens == closes )) || { balanced=0; break; }
    done
    if (( balanced == 1 )); then
      pass "$f (tags balanced)"
    else
      fail "$f has unbalanced <${tag}> tags"
    fi
  done
fi

# ---------------------------------------------------------------------------
section "No duplicate properties"
# A duplicated <name> wins or loses by parse order. Nothing warns you, and the
# effective value is whichever the parser saw last.
for f in "${XML_FILES[@]}"; do
  dupes="$(prop_names "$f" | sort | uniq -d || true)"
  if [[ -z "${dupes}" ]]; then
    pass "$(basename "$(dirname "$f")")/$(basename "$f")"
  else
    fail "$f defines these twice: $(tr '\n' ' ' <<<"${dupes}")"
  fi
done

# ---------------------------------------------------------------------------
section "Required properties are present"
for set_dir in conf/pseudo conf/cluster conf/docker; do
  [[ -d "$set_dir" ]] || continue
  name="$(basename "$set_dir")"

  fs="$(prop "$set_dir/core-site.xml" fs.defaultFS)"
  [[ -n "$fs" ]] && pass "${name}: fs.defaultFS = ${fs}" \
                 || fail "${name}: fs.defaultFS is not set — no client can find the cluster"

  aux="$(prop "$set_dir/yarn-site.xml" yarn.nodemanager.aux-services)"
  if [[ "$aux" == *mapreduce_shuffle* ]]; then
    pass "${name}: shuffle aux-service registered"
  else
    fail "${name}: yarn.nodemanager.aux-services lacks mapreduce_shuffle — every MapReduce job will fail in shuffle"
  fi

  fw="$(prop "$set_dir/mapred-site.xml" mapreduce.framework.name)"
  [[ "$fw" == "yarn" ]] && pass "${name}: mapreduce.framework.name = yarn" \
                        || fail "${name}: mapreduce.framework.name is '${fw:-unset}', expected yarn"

  cp="$(prop "$set_dir/mapred-site.xml" mapreduce.application.classpath)"
  [[ -n "$cp" ]] && pass "${name}: application classpath set" \
                 || fail "${name}: mapreduce.application.classpath missing — containers die with ClassNotFoundException"
done

# ---------------------------------------------------------------------------
section "Memory settings are internally consistent"
# The single most common misconfiguration: a container request larger than the
# scheduler's ceiling, or larger than any node can offer. The job is accepted and
# then waits forever, which looks like a hang rather than a config error.
for set_dir in conf/pseudo conf/cluster conf/docker; do
  [[ -d "$set_dir" ]] || continue
  name="$(basename "$set_dir")"

  nm_total="$(prop "$set_dir/yarn-site.xml" yarn.nodemanager.resource.memory-mb)"
  sched_max="$(prop "$set_dir/yarn-site.xml" yarn.scheduler.maximum-allocation-mb)"
  sched_min="$(prop "$set_dir/yarn-site.xml" yarn.scheduler.minimum-allocation-mb)"
  map_mb="$(prop "$set_dir/mapred-site.xml" mapreduce.map.memory.mb)"
  red_mb="$(prop "$set_dir/mapred-site.xml" mapreduce.reduce.memory.mb)"

  if [[ -n "$sched_max" && -n "$nm_total" ]] && (( sched_max > nm_total )); then
    fail "${name}: maximum-allocation-mb (${sched_max}) exceeds a node's capacity (${nm_total})"
  else
    pass "${name}: maximum-allocation-mb fits within node capacity"
  fi

  for pair in "map:${map_mb}" "reduce:${red_mb}"; do
    role="${pair%%:*}"; value="${pair#*:}"
    [[ -n "$value" && -n "$sched_max" ]] || continue
    if (( value > sched_max )); then
      fail "${name}: mapreduce.${role}.memory.mb (${value}) exceeds maximum-allocation-mb (${sched_max}) — jobs will sit in ACCEPTED forever"
    elif [[ -n "$sched_min" ]] && (( value < sched_min )); then
      warn "${name}: mapreduce.${role}.memory.mb (${value}) is below minimum-allocation-mb (${sched_min}); it will be rounded up"
    else
      pass "${name}: mapreduce.${role}.memory.mb is allocatable"
    fi
  done

  # A task heap larger than its container is killed by the NodeManager the
  # moment it grows into the gap.
  for role in map reduce; do
    opts="$(prop "$set_dir/mapred-site.xml" "mapreduce.${role}.java.opts")"
    container="$(prop "$set_dir/mapred-site.xml" "mapreduce.${role}.memory.mb")"
    heap="$(xmx_mb "${opts:-}")"
    [[ -n "$heap" && -n "$container" ]] || continue
    if (( heap >= container )); then
      fail "${name}: ${role} heap -Xmx${heap}m is not smaller than its ${container}MB container — the NodeManager will kill the task"
    else
      pct=$(( heap * 100 / container ))
      if (( pct > 90 )); then
        warn "${name}: ${role} heap is ${pct}% of the container; leave room for stacks and metaspace"
      else
        pass "${name}: ${role} heap is ${pct}% of its container"
      fi
    fi
  done
done

# ---------------------------------------------------------------------------
section "Replication matches the topology"
docker_rep="$(prop conf/docker/hdfs-site.xml dfs.replication)"
dn_count="$(grep -cE '^  datanode(-[0-9]+)?:' docker/docker-compose.yml || echo 0)"
if [[ -n "$docker_rep" ]] && (( dn_count > 0 )); then
  if (( docker_rep <= dn_count )); then
    pass "docker: dfs.replication=${docker_rep} with ${dn_count} DataNode service(s)"
  else
    fail "docker: dfs.replication=${docker_rep} but only ${dn_count} DataNode(s) — every block stays under-replicated"
  fi
fi

pseudo_rep="$(prop conf/pseudo/hdfs-site.xml dfs.replication)"
[[ "$pseudo_rep" == "1" ]] && pass "pseudo: dfs.replication=1, correct for one node" \
                           || fail "pseudo: dfs.replication=${pseudo_rep}, must be 1 on a single node"

# ---------------------------------------------------------------------------
section "Referenced files exist"
for key_file in \
  "net.topology.script.file.name:rack-topology.sh" \
  "dfs.hosts:dfs.include" \
  "dfs.hosts.exclude:dfs.exclude"
do
  key="${key_file%%:*}"; expected="${key_file#*:}"
  for site in conf/cluster/core-site.xml conf/cluster/hdfs-site.xml; do
    value="$(prop "$site" "$key")"
    [[ -n "$value" ]] || continue
    if [[ -f "conf/cluster/${expected}" ]]; then
      pass "cluster: ${key} → ${expected} is present in the set"
    else
      fail "cluster: ${key} points at ${value} but conf/cluster/${expected} is missing from the repository"
    fi
  done
done

# ---------------------------------------------------------------------------
section "Production relaxations are confined to learning modes"
# These are deliberate in pseudo/docker and must never appear in cluster/ha.
for set_dir in conf/cluster conf/ha; do
  [[ -d "$set_dir" ]] || continue
  name="$(basename "$set_dir")"
  perms="$(prop "$set_dir/hdfs-site.xml" dfs.permissions.enabled)"
  if [[ -z "$perms" || "$perms" == "true" ]]; then
    pass "${name}: HDFS permission checks are enabled"
  else
    fail "${name}: dfs.permissions.enabled=false — that shortcut belongs to the pseudo/docker sets only"
  fi
done

# ---------------------------------------------------------------------------
section "Shell scripts parse"
mapfile -t SH_FILES < <(find scripts docker conf examples tests -name '*.sh' 2>/dev/null | sort)
for f in "${SH_FILES[@]}"; do
  if bash -n "$f" 2>/dev/null; then
    pass "$f"
  else
    fail "$f has a syntax error"
    bash -n "$f" || true
  fi
done

# ---------------------------------------------------------------------------
printf '\n'
if (( FAILS > 0 )); then
  printf '%s%d of %d checks failed.%s\n\n' "$R" "$FAILS" "$CHECKS" "$Z"
  exit 1
fi
printf '%sAll %d checks passed.%s\n\n' "$G" "$CHECKS" "$Z"
