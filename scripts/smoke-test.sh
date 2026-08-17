#!/usr/bin/env bash
#
# End-to-end verification: does this cluster actually store data and run jobs?
#
#   ./scripts/smoke-test.sh        # bare metal, as the hadoop user
#   make smoke                    # against the containerised cluster
#
# Exits non-zero on the first real failure, so it is usable as a CI gate.
#
# A cluster whose daemons are all "up" can still be unable to run a single job —
# a missing shuffle aux-service, a container size larger than any node can grant,
# an absent staging directory. Only an actual write and an actual job prove it.

set -uo pipefail

HADOOP_HOME="${HADOOP_HOME:-/opt/hadoop}"
HADOOP_VERSION="${HADOOP_VERSION:-3.3.6}"
PATH="${HADOOP_HOME}/bin:${HADOOP_HOME}/sbin:${PATH}"
export PATH

# Unique per run so concurrent runs and leftovers from a failed run never collide.
WORKDIR="/tmp/forge-smoke-$$-$(date +%s)"
LOCAL_TMP="$(mktemp -d)"
FAILED=0

if [[ -t 1 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; B=$'\033[1m'; Z=$'\033[0m'
else
  R=''; G=''; B=''; Z=''
fi

step() { printf '\n%s==> %s%s\n' "$B" "$*" "$Z"; }
pass() { printf '  %s✓%s %s\n' "$G" "$Z" "$*"; }
fail() { printf '  %s✗%s %s\n' "$R" "$Z" "$*"; FAILED=1; }
die()  { fail "$*"; cleanup; exit 1; }

cleanup() {
  step "Cleaning up"
  hdfs dfs -rm -r -f -skipTrash "${WORKDIR}" >/dev/null 2>&1 || true
  rm -rf "${LOCAL_TMP}"
  pass "Removed ${WORKDIR}"
}
trap 'rm -rf "${LOCAL_TMP}"' EXIT

printf '%shadoop-forge smoke test%s\n' "$B" "$Z"

# ---------------------------------------------------------------------------
step "1/6 Client can reach the NameNode"
command -v hdfs >/dev/null 2>&1 || die "hdfs not on PATH"
hdfs dfs -ls / >/dev/null 2>&1 || die "Cannot list / — NameNode unreachable"
pass "fs.defaultFS = $(hdfs getconf -confKey fs.defaultFS)"

step "2/6 HDFS is accepting writes"
hdfs dfsadmin -safemode get 2>/dev/null | grep -q OFF \
  || die "Safe mode is ON — the filesystem is read-only"
pass "Safe mode OFF"

# ---------------------------------------------------------------------------
step "3/6 Write and read back, byte for byte"
mkdir -p "${LOCAL_TMP}"
SRC="${LOCAL_TMP}/payload.bin"
# 12 MB of random data: large enough to exercise the write pipeline and multiple
# packets, small enough to be quick. Random rather than zeros so a silently
# truncated or deduplicated read cannot pass by accident.
head -c 12582912 /dev/urandom > "${SRC}"
SRC_SUM="$(sha256sum "${SRC}" | awk '{print $1}')"

hdfs dfs -mkdir -p "${WORKDIR}/in" || die "mkdir failed"
hdfs dfs -put "${SRC}" "${WORKDIR}/payload.bin" || die "put failed"
pass "Wrote 12 MB to HDFS"

hdfs dfs -get "${WORKDIR}/payload.bin" "${LOCAL_TMP}/roundtrip.bin" || die "get failed"
DST_SUM="$(sha256sum "${LOCAL_TMP}/roundtrip.bin" | awk '{print $1}')"
if [[ "${SRC_SUM}" == "${DST_SUM}" ]]; then
  pass "SHA-256 matches after the round trip"
else
  die "Checksum mismatch — data corruption between write and read"
fi

# ---------------------------------------------------------------------------
step "4/6 Replication is satisfied"
WANT_REP="$(hdfs getconf -confKey dfs.replication 2>/dev/null || echo 1)"
FSCK="$(hdfs fsck "${WORKDIR}/payload.bin" -files -blocks 2>/dev/null || true)"
GOT_REP="$(sed -n 's/^[[:space:]]*Average block replication:[[:space:]]*\([0-9.]\{1,\}\).*/\1/p' <<<"${FSCK}" | head -n1)"
GOT_REP="${GOT_REP:-0}"
if awk -v w="${WANT_REP}" -v g="${GOT_REP}" 'BEGIN {exit !(g+0 >= w+0)}'; then
  pass "Average block replication ${GOT_REP} meets dfs.replication=${WANT_REP}"
else
  # A warning, not a failure: replication catches up asynchronously and a fresh
  # write may legitimately still be in flight.
  printf '  ! replication is %s, want %s — under-replicated (may still be catching up)\n' \
         "${GOT_REP}" "${WANT_REP}"
fi
BLOCKS="$(grep -c 'blk_' <<<"${FSCK}" || true)"
pass "File occupies ${BLOCKS} block(s)"

# ---------------------------------------------------------------------------
step "5/6 YARN can schedule a real MapReduce job"
command -v yarn >/dev/null 2>&1 || die "yarn not on PATH"
yarn node -list >/dev/null 2>&1 || die "Cannot reach the ResourceManager"

NM_COUNT="$(yarn node -list 2>/dev/null | grep -c RUNNING || true)"
(( NM_COUNT > 0 )) || die "No RUNNING NodeManagers — nothing can be scheduled"
pass "${NM_COUNT} NodeManager(s) available"

# Words with known counts, so correctness is verifiable rather than assumed.
cat > "${LOCAL_TMP}/corpus.txt" <<'EOF'
namenode datanode namenode
yarn yarn yarn resourcemanager
namenode
EOF
hdfs dfs -put "${LOCAL_TMP}/corpus.txt" "${WORKDIR}/in/" || die "Could not stage the corpus"

EXAMPLES_JAR="${HADOOP_HOME}/share/hadoop/mapreduce/hadoop-mapreduce-examples-${HADOOP_VERSION}.jar"
[[ -f "${EXAMPLES_JAR}" ]] || EXAMPLES_JAR="$(find "${HADOOP_HOME}/share/hadoop/mapreduce" -name 'hadoop-mapreduce-examples-*.jar' | head -n1)"
[[ -f "${EXAMPLES_JAR}" ]] || die "Cannot find the MapReduce examples jar"

if yarn jar "${EXAMPLES_JAR}" wordcount "${WORKDIR}/in" "${WORKDIR}/out" \
     > "${LOCAL_TMP}/job.log" 2>&1; then
  APP_ID="$(sed -n 's/.*\(application_[0-9]\{1,\}_[0-9]\{1,\}\).*/\1/p' "${LOCAL_TMP}/job.log" | head -n1)"
  pass "Job succeeded${APP_ID:+ (${APP_ID})}"
else
  printf '\n--- last 40 lines of job output ---\n'
  tail -40 "${LOCAL_TMP}/job.log"
  printf -- '-----------------------------------\n'
  die "MapReduce job failed"
fi

step "6/6 Job output is correct"
RESULT="$(hdfs dfs -cat "${WORKDIR}/out/part-r-*" 2>/dev/null || true)"
[[ -n "${RESULT}" ]] || die "Output directory is empty"

check_count() {
  local word="$1" want="$2"
  local got
  got="$(awk -v w="$word" '$1 == w {print $2}' <<<"${RESULT}")"
  if [[ "${got}" == "${want}" ]]; then
    pass "${word} = ${want}"
  else
    fail "${word} = ${got:-<missing>}, expected ${want}"
  fi
}
check_count namenode 3
check_count yarn 3
check_count datanode 1
check_count resourcemanager 1

cleanup

# ---------------------------------------------------------------------------
printf '\n'
if (( FAILED == 0 )); then
  printf '%sSmoke test passed — this cluster stores data and runs jobs.%s\n\n' "$G" "$Z"
  exit 0
fi
printf '%sSmoke test FAILED.%s\n\n' "$R" "$Z"
exit 1
