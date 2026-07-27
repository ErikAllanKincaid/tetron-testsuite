#!/usr/bin/env bash
# meta:id ssh-pairwise
# meta:description SSH reachability between every node in the topology
# meta:nodes 3
# meta:networks 1
#
# NOT YET IMPLEMENTED. Shape: N nodes on one network, for every ordered
# pair (i, j) with i != j, ssh from node_i to node_j's mesh IP and run a
# trivial command (e.g. `hostname`), assert it returns node_j's own
# hostname. Needs each VM's own sshd reachable over its mesh IP and a
# shared throwaway key injected at provisioning time (not yet wired into
# lib/topology.sh -- currently only the host-to-VM `vagrant ssh` path
# exists, not VM-to-VM).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

log_warn "ssh-pairwise: not yet implemented"
exit "$TESTSUITE_SKIP_CODE"
