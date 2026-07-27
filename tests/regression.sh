#!/usr/bin/env bash
# meta:id regression
# meta:description Regression checks for the 2026-07-26 overlay-routing fixes (TUN-CAPTURE-001, PATH-BLEED-001, SUBNET-COLLISION-001, SUBNET-COLLISION-002, SELFCAPTURE-ROUTE-001)
# meta:nodes 1
# meta:networks 1
#
# PARTIAL COVERAGE, tracked honestly rather than silently claiming more than
# it checks:
#
#   - SELFCAPTURE-ROUTE-001: COVERED. Asserts the daemon installs the
#     documented `ip rule` (src/selfcapture.rs's SHADOW_TABLE=52369,
#     RULE_PRIORITY=52369) routing iroh's own outbound UDP around every
#     overlay subnet route.
#   - SUBNET-COLLISION-001: COVERED. Asserts an explicit `--subnet` that
#     overlaps a network this node already has is refused without --force
#     and accepted with it.
#   - SUBNET-COLLISION-002 (host physical-LAN collision), TUN-CAPTURE-001,
#     and PATH-BLEED-001: NOT YET COVERED. The first needs a VM whose
#     physical interface is deliberately made to overlap the overlay
#     subnet; the latter two need the cross-host, two-network topology from
#     the original milestone3b manual investigation
#     (DO-NOT-COMMIT/RESULTS_VMTestLab_OverlayRoutingBug.md in the tetron
#     repo), which this single-node topology does not build. Left as a
#     follow-up once lib/topology.sh grows multi-host, multi-network
#     support beyond what ssh-jump-host-cross-network alone needs.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd ssh scp

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"

RUN_ID="regression-$$"
BROUGHT_UP=0

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "regression: no tetron binary at $TESTSUITE_TETRON_BINARY (build one with 'cargo build --release' in the tetron repo, or set TESTSUITE_TETRON_BINARY) -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 1
	BROUGHT_UP=1

	vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "$TESTSUITE_TETRON_BINARY" "/tmp/tetron"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name regfirst --hostname node1"

	local rc=0

	check_selfcapture_rule || rc=1
	check_subnet_collision || rc=1

	return $rc
}

check_selfcapture_rule() {
	local rule_list
	rule_list="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "ip rule list")"
	if echo "$rule_list" | grep -q "lookup 52369" && echo "$rule_list" | grep "lookup 52369" | grep -q "sport 43737"; then
		log_pass "SELFCAPTURE-ROUTE-001: ip rule for iroh's outbound UDP (sport 43737, table 52369) present"
		return 0
	fi
	log_fail "SELFCAPTURE-ROUTE-001: expected an 'ip rule' entry with 'sport 43737 ... lookup 52369', got:"
	echo "$rule_list" >&2
	return 1
}

check_subnet_collision() {
	local out status_ok=0

	out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name regsecond --hostname node1 --subnet 10.88.0.0/24" 2>&1)"
	if echo "$out" | grep -q "overlaps a network this node already has"; then
		log_pass "SUBNET-COLLISION-001: overlapping --subnet refused without --force"
	else
		log_fail "SUBNET-COLLISION-001: expected refusal ('overlaps a network this node already has'), got:"
		echo "$out" >&2
		status_ok=1
	fi

	out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name regsecond --hostname node1 --subnet 10.88.0.0/24 --force" 2>&1)"
	if echo "$out" | grep -qi "error"; then
		log_fail "SUBNET-COLLISION-001: expected --force to succeed despite the overlap, got:"
		echo "$out" >&2
		status_ok=1
	else
		log_pass "SUBNET-COLLISION-001: --force overrides the overlap refusal"
	fi

	return $status_ok
}

main
