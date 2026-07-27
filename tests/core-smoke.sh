#!/usr/bin/env bash
# meta:id core-smoke
# meta:description Core smoke test: create -> join -> status shows peer -> leave -> gone
# meta:nodes 2
# meta:networks 1
#
# Brings up two VMs on one physical host, installs a locally-built tetron
# binary on each, has node1 create a network and node2 join it, asserts
# node1's `tetron status --json` shows node2 as a member, then has node2
# leave and asserts it drops back out.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd jq ssh scp

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"

RUN_ID="core-smoke-$$"
BROUGHT_UP=0

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "core-smoke: no tetron binary at $TESTSUITE_TETRON_BINARY (build one with 'cargo build --release' in the tetron repo, or set TESTSUITE_TETRON_BINARY) -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 2 || fatal "core-smoke: topology_up failed -- VMs never came up, no point running checks against them"
	BROUGHT_UP=1

	local node
	for node in node1 node2; do
		vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "core-smoke: vm_upload failed on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install" || fatal "core-smoke: install failed on $node"
	done

	local create_out invite
	create_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name smoketest --hostname node1")" || fatal "core-smoke: 'tetron create' failed on node1"
	invite="$(echo "$create_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	if [[ -z "$invite" ]]; then
		log_fail "core-smoke: could not find an invite code in 'tetron create' output:"
		echo "$create_out" >&2
		exit 1
	fi

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron join $invite --hostname node2" || fatal "core-smoke: 'tetron join' failed on node2"

	log_info "waiting for admission to propagate"
	sleep 8

	local status_json member_count peer_hostname
	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	member_count="$(json_get '.networks[0].member_count // 0' "$status_json")"
	peer_hostname="$(json_get '.networks[0].peers[0].hostname // empty' "$status_json")"

	if [[ "$member_count" != "1" || "$peer_hostname" != "node2" ]]; then
		log_fail "core-smoke: expected node1 to see 1 member (node2) after join, got member_count=$member_count peer_hostname=$peer_hostname"
		echo "$status_json" >&2
		exit 1
	fi
	log_pass "core-smoke: node1 sees node2 as a member after join"

	local net_key
	net_key="$(json_get '.networks[0].network_key // empty' "$status_json")"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron leave ${net_key:-smoketest} --force"

	log_info "waiting for departure to propagate"
	sleep 8

	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	member_count="$(json_get '.networks[0].member_count // 0' "$status_json")"
	if [[ "$member_count" != "0" ]]; then
		log_fail "core-smoke: expected node1 to see 0 members after node2 left, got member_count=$member_count"
		echo "$status_json" >&2
		exit 1
	fi
	log_pass "core-smoke: node1 sees node2 gone after leave"
}

main
