#!/usr/bin/env bash
# meta:id veilid-smoke
# meta:description Live connectivity check for the experimental Veilid transport (VEILID-001..004): create --veilid -> restart (self-heals the coordinator's own roster entry, VEILID-004) -> join --veilid -> restart (member self-heals via reconnect MeshHello, VEILID-003) -> status shows conn_type Veilid on both sides.
# meta:nodes 2
# meta:networks 1
#
# Requires a tetron binary built with `--features veilid`
# (`cargo build --release --features veilid` in the tetron repo). Not part
# of run-list.txt by default -- run explicitly: ./bin/tetron-testsuite veilid-smoke
#
# Both nodes' embedded Veilid transport only starts on the *second* daemon
# boot for a given node (the shared endpoint's custom transports are fixed
# at process startup, before --veilid has even reached config on the first
# create/join against an already-running daemon -- see spec/core.py's
# VeilidCoordinatorSelfEntryHeal, VEILID-004). Each `tetron restart` below
# is not incidental cleanup, it is the step that actually starts Veilid.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd jq ssh scp

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"
# Own-identity resolution + full public-network attach (both backgrounded,
# non-blocking as of the VEILID-005 fix -- see spec/core.py) has taken
# 2+ minutes in VM testing; restart, then poll status until responsive
# (fast now -- the daemon no longer blocks its own startup on this), then
# wait this much longer for identity/attach/admission/reconverge to land.
: "${TESTSUITE_VEILID_SETTLE_SECS:=240}"

RUN_ID="veilid-smoke-$$"
BROUGHT_UP=0

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

# wait_daemon_responsive <node> -- poll until `tetron status --json` succeeds
# again after a restart (proxy for "the daemon rebound and is answering IPC",
# not for "Veilid finished attaching" -- callers still sleep afterward for that).
wait_daemon_responsive() {
	local node="$1" tries=0
	while ((tries < 30)); do
		if vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "tetron status --json" >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
		((tries++))
	done
	return 1
}

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "veilid-smoke: no tetron binary at $TESTSUITE_TETRON_BINARY (build one with 'cargo build --release --features veilid' in the tetron repo, or set TESTSUITE_TETRON_BINARY) -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 2 || fatal "veilid-smoke: topology_up failed -- VMs never came up, no point running checks against them"
	BROUGHT_UP=1

	local node
	for node in node1 node2; do
		vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "veilid-smoke: vm_upload failed on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install" || fatal "veilid-smoke: install failed on $node"
	done

	local create_out invite
	create_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name veilidtest --hostname node1 --veilid")" || fatal "veilid-smoke: 'tetron create --veilid' failed on node1"
	invite="$(echo "$create_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	if [[ -z "$invite" ]]; then
		log_fail "veilid-smoke: could not find an invite code in 'tetron create' output:"
		echo "$create_out" >&2
		exit 1
	fi

	log_info "restarting node1 so its embedded Veilid node actually starts (VEILID-004 self-heals its roster entry on this boot)"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron restart" || fatal "veilid-smoke: restart failed on node1"
	wait_daemon_responsive node1 || fatal "veilid-smoke: node1 daemon did not come back up after restart"
	log_info "waiting up to ${TESTSUITE_VEILID_SETTLE_SECS}s for node1's Veilid attach"
	sleep "$TESTSUITE_VEILID_SETTLE_SECS"

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron join $invite --hostname node2 --veilid" || fatal "veilid-smoke: 'tetron join --veilid' failed on node2"

	log_info "restarting node2 so its embedded Veilid node actually starts (its reconnect MeshHello carries the real veilid_node_id, VEILID-003)"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron restart" || fatal "veilid-smoke: restart failed on node2"
	wait_daemon_responsive node2 || fatal "veilid-smoke: node2 daemon did not come back up after restart"
	log_info "waiting up to ${TESTSUITE_VEILID_SETTLE_SECS}s for node2's Veilid attach + reconnect + admission propagation"
	sleep "$TESTSUITE_VEILID_SETTLE_SECS"

	local status_json conn_type peer_hostname
	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	conn_type="$(json_get '.networks[0].peers[0].connection.conn_type // "None"' "$status_json")"
	peer_hostname="$(json_get '.networks[0].peers[0].hostname // empty' "$status_json")"
	log_info "node1 sees peer '$peer_hostname' via conn_type=$conn_type"
	if [[ "$peer_hostname" != "node2" ]]; then
		log_fail "veilid-smoke: node1 does not see node2 as a member at all"
		echo "$status_json" >&2
		exit 1
	fi
	if [[ "$conn_type" != "Veilid" ]]; then
		log_fail "veilid-smoke: node1<->node2 connected, but not over Veilid (conn_type=$conn_type) -- roster/dial-path wiring did not actually route traffic through the custom transport"
		echo "$status_json" >&2
		exit 1
	fi
	log_pass "veilid-smoke: node1 reaches node2 with conn_type=Veilid"

	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "tetron status --json")"
	conn_type="$(json_get '.networks[0].peers[0].connection.conn_type // "None"' "$status_json")"
	log_info "node2 sees its peer via conn_type=$conn_type"
	if [[ "$conn_type" != "Veilid" ]]; then
		log_fail "veilid-smoke: node2->node1 direction not over Veilid (conn_type=$conn_type)"
		echo "$status_json" >&2
		exit 1
	fi
	log_pass "veilid-smoke: node2 reaches node1 with conn_type=Veilid (bidirectional confirmed)"
}

main
