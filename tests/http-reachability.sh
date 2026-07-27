#!/usr/bin/env bash
# meta:id http-reachability
# meta:description HTTP reachability across the mesh -- validates MINIMAL-010's "every mesh peer reaches every port a local service binds" claim
# meta:nodes 2
# meta:networks 1
#
# NOT YET IMPLEMENTED. Shape: same topology as core-smoke.sh, run `python3
# -m http.server` on node1 bound to its mesh IP, curl it from node2 over
# that IP, assert a 200 and matching body. tetron has no data-plane packet
# filter of its own (MINIMAL-010) -- membership is the only gate -- so this
# should just work with no port-specific configuration on either side.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

log_warn "http-reachability: not yet implemented"
exit "$TESTSUITE_SKIP_CODE"
