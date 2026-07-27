#!/usr/bin/env bash
# meta:id ssh-jump-host-cross-network
# meta:description SSH jump-host across two tetron networks with no direct route between them -- validates MULTISEG-003's documented workaround
# meta:nodes 3
# meta:networks 2
#
# NOT YET IMPLEMENTED. The one v1 test that specifically needs a
# multi-network topology: node1 joins network A only, node3 joins network B
# only, node2 joins both A and B (the jump host). node1 cannot reach node3
# directly (tetron deliberately does not route between a node's own
# segments, see MULTISEG-003's architecture note in AGENTS.md) -- assert
# that fails, then assert `ssh -J node2 node3` from node1 succeeds. Needs
# lib/topology.sh to grow actual multi-network support (forming two
# separate tetron networks across the declared nodes at provisioning time,
# not just N VMs on one) -- deferred until this test is picked up.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

log_warn "ssh-jump-host-cross-network: not yet implemented"
exit "$TESTSUITE_SKIP_CODE"
