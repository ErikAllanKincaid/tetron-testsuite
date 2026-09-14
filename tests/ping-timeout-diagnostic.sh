#!/usr/bin/env bash
# meta:id ping-timeout-diagnostic
# meta:description DIAGNOSTIC (not a pass/fail gate): confirms whether the relay protocol's own ping/pong heartbeat timeout correlates with the observed ~10-16s reconnect churn
#
# One-off investigative script for the idle-timeout-reconnect-churn
# question (tetron/DO-NOT-COMMIT/PLAN_connection-stability-idle-timeout_2026-08-11.md,
# TODO_DETAILS.md #6). Not part of the standing suite, not added to
# run-list.txt -- this is Phase 1/2 exploratory work, not a Phase 4
# regression gate. Forces two VMs onto a relay-only path (no direct UDP),
# elevates node1's RUST_LOG to see iroh's own internal relay-transport
# ping/pong tracing (tetron's own `log-level` config only filters the
# `tetron` crate, not `iroh` -- confirmed in main::init_tracing), leaves
# the connection genuinely idle, then dumps every ping/pong/timeout/
# reconnect line in timestamp order for manual correlation.
#
# iroh-relay-1.0.3's own ping/pong constants (vendored source, not
# assumed): PING_INTERVAL = 15s (+ jitter), PING_TIMEOUT = 5s default (or
# 3x last RTT). If "Ping timeout"/"pong timed out" lines precede each
# "peer connection lost" event by a consistent, small margin, that
# confirms this heartbeat -- not tetron's own QUIC max_idle_timeout -- is
# what's actually driving the cycle.

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
: "${TESTSUITE_IDLE_SECS:=180}"

RUN_ID="ping-timeout-diagnostic-$$"
BROUGHT_UP=0

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "ping-timeout-diagnostic: no tetron binary at $TESTSUITE_TETRON_BINARY -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 2 || fatal "ping-timeout-diagnostic: topology_up failed"
	BROUGHT_UP=1

	local node
	for node in node1 node2; do
		vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "ping-timeout-diagnostic: vm_upload failed on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install" || fatal "ping-timeout-diagnostic: install failed on $node"
	done

	log_info "forcing relay-only path between node1 and node2 (blocking direct UDP)"
	force_relay_only "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 node2 >/dev/null

	log_info "elevating node1's RUST_LOG to see iroh's own relay-transport ping/pong tracing"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo systemctl set-environment 'RUST_LOG=info,tetron=debug,iroh::socket::transports::relay=trace' && sudo systemctl restart tetron" || fatal "ping-timeout-diagnostic: could not set RUST_LOG on node1"
	sleep 3

	local create_out invite
	create_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name pingdiag --hostname node1")" || fatal "ping-timeout-diagnostic: 'tetron create' failed on node1"
	invite="$(echo "$create_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite" ]] || fatal "ping-timeout-diagnostic: could not find an invite code"

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron join $invite --hostname node2" || fatal "ping-timeout-diagnostic: 'tetron join' failed on node2"

	log_info "waiting for admission + relay path selection (30s)"
	sleep 30

	local relay_host
	relay_host="$(relay_host_in_use "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1)"
	log_info "relay in use (if selected yet): ${relay_host:-<not yet observed>}"

	log_info "now leaving genuinely idle for ${TESTSUITE_IDLE_SECS}s to observe the natural cycle"
	sleep "$TESTSUITE_IDLE_SECS"

	log_info "=== node1 log: every ping/pong/timeout/reconnect line, in order ==="
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 \
		"sudo grep -E 'ping|pong|Ping|Pong|peer connection lost|path (opened|closed|selected)' /var/log/tetron/tetron.log.* 2>/dev/null" \
		| sort

	log_info "=== reconnect event count vs ping-timeout event count (sanity totals) ==="
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 \
		"echo -n 'peer connection lost: '; sudo grep -c 'peer connection lost' /var/log/tetron/tetron.log.* 2>/dev/null || true; echo -n 'ping timeout: '; sudo grep -ci 'ping timeout\|pong timed out' /var/log/tetron/tetron.log.* 2>/dev/null || true"
}

main
