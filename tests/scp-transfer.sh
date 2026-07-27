#!/usr/bin/env bash
# meta:id scp-transfer
# meta:description scp file transfer between two VMs over their mesh IPs
# meta:nodes 2
# meta:networks 1
#
# NOT YET IMPLEMENTED. Deliberately a separate test from rsync-transfer.sh,
# not folded together -- same topology, `scp` instead of `rsync` as the
# transfer mechanism, same checksum verification on the far side.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

log_warn "scp-transfer: not yet implemented"
exit "$TESTSUITE_SKIP_CODE"
