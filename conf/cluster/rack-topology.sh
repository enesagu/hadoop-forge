#!/usr/bin/env bash
#
# Rack topology resolver.
#
# Hadoop invokes this script with one or more IP addresses (or hostnames) as
# arguments and expects one rack path per argument on stdout, in the same order.
# The output feeds two decisions:
#
#   1. Replica placement — replica 2 must land in a different rack from
#      replica 1, replica 3 in the same rack as replica 2.
#   2. Scheduler locality — node-local beats rack-local beats off-rack.
#
# Return /default-rack for anything unknown. Never fail: a non-zero exit or
# malformed output makes the NameNode treat the topology as flat.
#
# In a real deployment this is generated from your CMDB or IPAM rather than
# hand-maintained.
set -uo pipefail

declare -A RACK_MAP=(
  # master
  ["192.168.1.10"]="/dc1/rack1"
  ["master"]="/dc1/rack1"

  # rack1 workers
  ["192.168.1.11"]="/dc1/rack1"
  ["worker1"]="/dc1/rack1"

  # rack2 workers
  ["192.168.1.12"]="/dc1/rack2"
  ["worker2"]="/dc1/rack2"
  ["192.168.1.13"]="/dc1/rack2"
  ["worker3"]="/dc1/rack2"
)

for host in "$@"; do
  printf '%s\n' "${RACK_MAP[$host]:-/default-rack}"
done
