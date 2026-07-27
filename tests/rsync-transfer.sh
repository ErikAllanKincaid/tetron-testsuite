#!/usr/bin/env bash
# meta:id rsync-transfer
# meta:description rsync file transfer between two VMs over their mesh IPs
# meta:nodes 2
# meta:networks 1
#
# NOT YET IMPLEMENTED. Shape: same topology as core-smoke.sh (2 nodes, one
# network), then `rsync` a generated file from node1 to node2 over node2's
# mesh IP (from `tetron status --json` on node1), verify checksum match on
# the far side.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

log_warn "rsync-transfer: not yet implemented"
exit "$TESTSUITE_SKIP_CODE"
