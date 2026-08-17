#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared helpers for every script in this directory.
#
# Sourced, never executed:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# shellcheck disable=SC2034
# ^ Several values defined here are consumed only by the scripts that source
#   this file, which shellcheck cannot see from inside a library.

# Guard against double-sourcing when scripts chain into each other.
[[ -n "${_FORGE_COMMON_SOURCED:-}" ]] && return 0
_FORGE_COMMON_SOURCED=1

set -euo pipefail

# --------------------------------------------------------------------------
# Defaults — override by exporting before invoking any script, or via .env
# --------------------------------------------------------------------------
HADOOP_VERSION="${HADOOP_VERSION:-3.3.6}"
HADOOP_HOME="${HADOOP_HOME:-/opt/hadoop}"
HADOOP_USER="${HADOOP_USER:-hadoop}"
HADOOP_GROUP="${HADOOP_GROUP:-hadoop}"
HADOOP_DATA_ROOT="${HADOOP_DATA_ROOT:-/data/hdfs}"
HADOOP_MIRROR="${HADOOP_MIRROR:-https://downloads.apache.org/hadoop/common}"
HADOOP_ARCHIVE_MIRROR="${HADOOP_ARCHIVE_MIRROR:-https://archive.apache.org/dist/hadoop/common}"
JAVA_PACKAGE="${JAVA_PACKAGE:-openjdk-11-jdk}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/tmp/hadoop-forge-downloads}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------
if [[ -t 1 ]]; then
  _C_RESET=$'\033[0m'; _C_RED=$'\033[31m'; _C_GREEN=$'\033[32m'
  _C_YELLOW=$'\033[33m'; _C_BLUE=$'\033[34m'; _C_BOLD=$'\033[1m'
else
  _C_RESET=''; _C_RED=''; _C_GREEN=''; _C_YELLOW=''; _C_BLUE=''; _C_BOLD=''
fi

log()     { printf '%s[ info ]%s %s\n' "$_C_BLUE" "$_C_RESET" "$*"; }
ok()      { printf '%s[  ok  ]%s %s\n' "$_C_GREEN" "$_C_RESET" "$*"; }
warn()    { printf '%s[ warn ]%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
err()     { printf '%s[ fail ]%s %s\n' "$_C_RED" "$_C_RESET" "$*" >&2; }
die()     { err "$*"; exit 1; }
heading() { printf '\n%s==> %s%s\n' "$_C_BOLD" "$*" "$_C_RESET"; }

# Marks a step that produced no change, so re-running a script reads clearly.
skip() { printf '%s[ skip ]%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*"; }

# --------------------------------------------------------------------------
# Guards
# --------------------------------------------------------------------------
require_root() {
  [[ ${EUID} -eq 0 ]] || die "This step needs root. Re-run with sudo: sudo $0 $*"
}

refuse_root() {
  [[ ${EUID} -ne 0 ]] || die "Do not run this step as root — run it as the '${HADOOP_USER}' user."
}

require_cmd() {
  local missing=()
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) || die "Missing required command(s): ${missing[*]}"
}

require_linux() {
  [[ "$(uname -s)" == "Linux" ]] || die "These installers target Linux. On Windows or macOS use the Docker path: make up"
}

# --------------------------------------------------------------------------
# Small utilities
# --------------------------------------------------------------------------

# Resolve JAVA_HOME from the java binary actually on PATH, so we never guess a
# path that does not exist on this distribution.
detect_java_home() {
  local java_bin
  java_bin="$(command -v java 2>/dev/null)" || return 1
  local resolved
  resolved="$(readlink -f "$java_bin")"
  # .../jvm/java-11-openjdk-amd64/bin/java -> .../jvm/java-11-openjdk-amd64
  printf '%s\n' "${resolved%/bin/java}"
}

java_major_version() {
  # "openjdk version \"11.0.21\"" -> 11 ; "1.8.0_392" -> 8
  local raw
  raw="$(java -version 2>&1 | head -n1 | sed -E 's/.*version "([^"]+)".*/\1/')"
  case "$raw" in
    1.*) printf '%s\n' "${raw#1.}" | cut -d. -f1 ;;
    *)   printf '%s\n' "$raw" | cut -d. -f1 ;;
  esac
}

# Idempotent line insertion: append only if the exact line is absent.
ensure_line_in_file() {
  local line="$1" file="$2"
  [[ -f "$file" ]] || : > "$file"
  if grep -qxF -- "$line" "$file"; then
    return 1  # already present
  fi
  printf '%s\n' "$line" >> "$file"
  return 0
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "sport = :${port}" 2>/dev/null | grep -q LISTEN
  else
    # shellcheck disable=SC2009  # ss is preferred; netstat is the fallback
    netstat -ltn 2>/dev/null | grep -q ":${port} "
  fi
}

confirm() {
  local prompt="${1:-Continue?}"
  [[ "${FORGE_ASSUME_YES:-0}" == "1" ]] && { log "$prompt (auto-confirmed)"; return 0; }
  local reply
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}
