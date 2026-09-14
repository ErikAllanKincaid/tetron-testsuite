#!/usr/bin/env bash
# meta:id idle-connection-stability
# meta:description CONN-STABILITY-001: a genuinely idle direct connection between two admitted peers must not reconnect
# meta:nodes 2
# meta:networks 1
#
# Standing regression gate (not exploratory) for CONN-STABILITY-001, which
# reverted HARDEN-007's global 10s QUIC max_idle_timeout back to iroh/quinn's
# 30s default -- see tetron/spec/security.py's
# QuicIdleTimeoutRevertedToUpstreamDefault and
# tetron/DO-NOT-COMMIT/ANALYSIS_idle-timeout-reconnect-churn_2026-08-11.md.
# Two VMs join normally (direct path, no forced relay), then sit genuinely
# idle -- zero synthetic traffic -- for 5x the current 30s ceiling (150s),
# and the test asserts zero "peer connection lost" events in that window.
#
# Direct-path companion to idle-connection-stability-relay.sh, deliberately
# kept as a separate file (both path types matter and behave slightly
# differently per the investigation's own findings, same precedent as
# rsync-transfer/scp-transfer staying separate).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd jq ssh scp

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"
: "${TESTSUITE_IDLE_SECS:=150}"

RUN_ID="idle-connection-stability-$$"
BROUGHT_UP=0

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "idle-connection-stability: no tetron binary at $TESTSUITE_TETRON_BINARY -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 2 || fatal "idle-connection-stability: topology_up failed"
	BROUGHT_UP=1

	local node
	for node in node1 node2; do
		vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "idle-connection-stability: vm_upload failed on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install" || fatal "idle-connection-stability: install failed on $node"
	done

	local create_out invite
	create_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name idlestable --hostname node1")" || fatal "idle-connection-stability: 'tetron create' failed on node1"
	invite="$(echo "$create_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite" ]] || fatal "idle-connection-stability: could not find an invite code"

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron join $invite --hostname node2" || fatal "idle-connection-stability: 'tetron join' failed on node2"

	log_info "waiting for admission and path selection to settle (20s)"
	sleep 20

	local status_json member_count
	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	member_count="$(json_get '.networks[0].member_count // 0' "$status_json")"
	if [[ "$member_count" != "1" ]]; then
		log_fail "idle-connection-stability: expected node1 to see 1 member (node2) before the idle hold, got member_count=$member_count"
		echo "$status_json" >&2
		exit 1
	fi

	log_info "holding genuinely idle for ${TESTSUITE_IDLE_SECS}s (zero synthetic traffic)"
	sleep "$TESTSUITE_IDLE_SECS"

	local lost_count
	lost_count="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo grep -c 'peer connection lost' /var/log/tetron/tetron.log.* 2>/dev/null || true")"
	lost_count="${lost_count:-0}"
	if [[ "$lost_count" != "0" ]]; then
		log_info "idle-connection-stability: diagnostic dump -- path/connection lines:"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo grep -E 'peer connection lost|path (opened|closed|selected)' /var/log/tetron/tetron.log.* 2>/dev/null" >&2
		log_fail "idle-connection-stability: expected 0 'peer connection lost' events over ${TESTSUITE_IDLE_SECS}s idle, got $lost_count"
		exit 1
	fi
	log_pass "idle-connection-stability: 0 reconnect events over ${TESTSUITE_IDLE_SECS}s of genuine idle on a direct connection"

	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	member_count="$(json_get '.networks[0].member_count // 0' "$status_json")"
	if [[ "$member_count" != "1" ]]; then
		log_fail "idle-connection-stability: expected node1 to still see 1 member (node2) after the idle hold, got member_count=$member_count"
		echo "$status_json" >&2
		exit 1
	fi
	log_pass "idle-connection-stability: node1 still sees node2 as a member after the idle hold"
}

main
