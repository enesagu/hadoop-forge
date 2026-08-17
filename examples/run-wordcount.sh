#!/usr/bin/env bash
#
# Run the WordCount example end to end.
#
#   make wordcount                                   # inside the cluster
#   docker compose exec gateway bash /examples/run-wordcount.sh
#   ./examples/run-wordcount.sh /my/input /my/output  # bare-metal, custom paths
#
# Uses the jar from examples/wordcount/target if it has been built, and falls
# back to Hadoop's bundled example otherwise — so this works before you have
# Maven installed.

set -euo pipefail

INPUT="${1:-/examples/input}"
OUTPUT="${2:-/examples/output}"
HADOOP_HOME="${HADOOP_HOME:-/opt/hadoop}"
HADOOP_VERSION="${HADOOP_VERSION:-3.3.6}"

# Inside the cluster containers examples/ is mounted read-only at /examples.
DATA_DIR="/examples/data"
[[ -d "${DATA_DIR}" ]] || DATA_DIR="$(cd "$(dirname "$0")/data" && pwd)"
CUSTOM_JAR="/examples/wordcount/target/wordcount-1.0.0.jar"
[[ -f "${CUSTOM_JAR}" ]] || CUSTOM_JAR="$(dirname "$0")/wordcount/target/wordcount-1.0.0.jar"
BUNDLED_JAR="${HADOOP_HOME}/share/hadoop/mapreduce/hadoop-mapreduce-examples-${HADOOP_VERSION}.jar"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

say "Staging input in HDFS at ${INPUT}"
hdfs dfs -mkdir -p "${INPUT}"
# -f overwrites, so re-running the script is not an error.
hdfs dfs -put -f "${DATA_DIR}"/*.txt "${INPUT}/"
# Hadoop's own XML config makes a decent second corpus and proves that reading
# many small files works.
hdfs dfs -put -f "${HADOOP_HOME}"/etc/hadoop/*.xml "${INPUT}/" 2>/dev/null || true
hdfs dfs -ls "${INPUT}"

say "Clearing ${OUTPUT}"
# MapReduce refuses to write into an existing directory, by design.
hdfs dfs -rm -r -f -skipTrash "${OUTPUT}" >/dev/null 2>&1 || true

if [[ -f "${CUSTOM_JAR}" ]]; then
  say "Running the project WordCount (${CUSTOM_JAR##*/})"
  # Two reducers, so the output is genuinely partitioned and you get
  # part-r-00000 and part-r-00001 rather than a single file.
  yarn jar "${CUSTOM_JAR}" \
    -D mapreduce.job.reduces=2 \
    -D wordcount.min.token.length=3 \
    "${INPUT}" "${OUTPUT}"
else
  say "Project jar not built (run: make example) — using the bundled example"
  yarn jar "${BUNDLED_JAR}" wordcount "${INPUT}" "${OUTPUT}"
fi

say "Output files"
hdfs dfs -ls "${OUTPUT}"

say "Top 20 words by frequency"
# Sort numerically on the count column, descending. The job output is sorted by
# key, not by count — there is no single-pass way to get a global top-N out of
# MapReduce without a second job.
hdfs dfs -cat "${OUTPUT}/part-r-*" | sort -k2,2nr | head -20

say "Done"
printf 'Inspect the job in the ResourceManager UI: http://localhost:8088\n'
