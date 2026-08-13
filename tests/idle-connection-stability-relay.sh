#!/usr/bin/env bash
# meta:id idle-connection-stability-relay
# meta:description CONN-STABILITY-001: a genuinely idle relay-forced connection between two admitted peers must not reconnect
# meta:nodes 2
# meta:networks 1
#
# Relay-forced companion to idle-connection-stability.sh -- this is the path
# type that actually showed the CONN-STABILITY-001 regression (a direct idle
# connection was already fine; see that requirement's own docstring). Uses
# lib/network_faults.sh's force_relay_only to block direct UDP between the
# two VMs before either daemon starts, so a direct path is never even
# attempted, then holds idle for 5x the current 30s ceiling (150s) and
# asserts zero "peer connection lost" events.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"
# shellcheck source=../lib/network_faults.sh
source "$ROOT/lib/network_faults.sh"

require_cmd jq ssh scp

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"
: "${TESTSUITE_IDLE_SECS:=150}"

RUN_ID="idle-connection-stability-relay-$$"
BROUGHT_UP=0

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "idle-connection-stability-relay: no tetron binary at $TESTSUITE_TETRON_BINARY -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 2 || fatal "idle-connection-stability-relay: topology_up failed"
	BROUGHT_UP=1

	local node
	for node in node1 node2; do
		vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "idle-connection-stability-relay: vm_upload failed on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install" || fatal "idle-connection-stability-relay: install failed on $node"
	done

	log_info "forcing relay-only path between node1 and node2 (blocking direct UDP)"
	force_relay_only "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 node2 >/dev/null

	local create_out invite
	create_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name idlestablerelay --hostname node1")" || fatal "idle-connection-stability-relay: 'tetron create' failed on node1"
	invite="$(echo "$create_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite" ]] || fatal "idle-connection-stability-relay: could not find an invite code"

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron join $invite --hostname node2" || fatal "idle-connection-stability-relay: 'tetron join' failed on node2"

	log_info "waiting for admission and relay path selection (30s)"
	sleep 30

	local status_json member_count
	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	member_count="$(json_get '.networks[0].member_count // 0' "$status_json")"
	if [[ "$member_count" != "1" ]]; then
		log_fail "idle-connection-stability-relay: expected node1 to see 1 member (node2) before the idle hold, got member_count=$member_count"
		echo "$status_json" >&2
		exit 1
	fi

	# Retries, not a single check: a rapidly-cycling connection (the exact
	# bug this test guards against) can land the single check in the gap
	# between "path closed" and the next "path selected", making a one-shot
	# check flaky independent of whether the real bug is present.
	local relay_host="" attempt
	for attempt in 1 2 3 4 5; do
		relay_host="$(relay_host_in_use "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1)"
		[[ -n "$relay_host" ]] && break
		sleep 3
	done
	if [[ -z "$relay_host" ]]; then
		log_fail "idle-connection-stability-relay: no relay path observed on node1 after 5 retries -- direct UDP block may not have taken effect"
		exit 1
	fi
	log_info "relay in use: $relay_host"

	log_info "holding genuinely idle for ${TESTSUITE_IDLE_SECS}s (zero synthetic traffic)"
	sleep "$TESTSUITE_IDLE_SECS"

	local lost_count
	lost_count="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo grep -c 'peer connection lost' /var/log/tetron/tetron.log.* 2>/dev/null || true")"
	lost_count="${lost_count:-0}"
	if [[ "$lost_count" != "0" ]]; then
		log_info "idle-connection-stability-relay: diagnostic dump -- path/connection lines:"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo grep -E 'peer connection lost|path (opened|closed|selected)' /var/log/tetron/tetron.log.* 2>/dev/null" >&2
		log_fail "idle-connection-stability-relay: expected 0 'peer connection lost' events over ${TESTSUITE_IDLE_SECS}s idle on a relay-forced connection, got $lost_count"
		exit 1
	fi
	log_pass "idle-connection-stability-relay: 0 reconnect events over ${TESTSUITE_IDLE_SECS}s of genuine idle on a relay-forced connection"

	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	member_count="$(json_get '.networks[0].member_count // 0' "$status_json")"
	if [[ "$member_count" != "1" ]]; then
		log_fail "idle-connection-stability-relay: expected node1 to still see 1 member (node2) after the idle hold, got member_count=$member_count"
		echo "$status_json" >&2
		exit 1
	fi
	log_pass "idle-connection-stability-relay: node1 still sees node2 as a member after the idle hold"
}

main
