#!/usr/bin/env bash
# meta:id scp-transfer
# meta:description scp file transfer between two VMs over their mesh IPs
# meta:nodes 2
# meta:networks 1
#
# Deliberately a separate test from rsync-transfer.sh, not folded together
# -- same setup, `scp` instead of `rsync` as the transfer mechanism, same
# checksum verification on the far side.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd jq ssh scp ssh-keygen

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"

RUN_ID="scp-transfer-$$"
BROUGHT_UP=0

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "scp-transfer: no tetron binary at $TESTSUITE_TETRON_BINARY -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 2 || fatal "scp-transfer: topology_up failed"
	BROUGHT_UP=1

	local node
	for node in node1 node2; do
		vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "scp-transfer: vm_upload failed on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install && sudo apt-get update -qq && sudo apt-get install -y -qq openssh-client" || fatal "scp-transfer: install failed on $node"
	done

	vm_setup_peer_ssh "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 node2 || fatal "scp-transfer: vm_setup_peer_ssh failed"

	local create_out invite
	create_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name scptest --hostname node1")" || fatal "scp-transfer: 'tetron create' failed on node1"
	invite="$(echo "$create_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite" ]] || fatal "scp-transfer: could not find an invite code in 'tetron create' output: $create_out"

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron join $invite --hostname node2" || fatal "scp-transfer: 'tetron join' failed on node2"

	log_info "waiting for admission to propagate"
	sleep 8

	local status_json node2_ip
	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	node2_ip="$(json_get '.networks[0].peers[0].ip // empty' "$status_json")"
	if [[ -z "$node2_ip" ]]; then
		log_fail "scp-transfer: could not find node2's mesh IP in node1's status:"
		echo "$status_json" >&2
		exit 1
	fi
	log_info "node2's mesh IP: $node2_ip"

	wait_for_peer_port "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "$node2_ip" 22 30 \
		|| fatal "scp-transfer: node2's mesh IP:22 never became reachable from node1"

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "head -c 1048576 /dev/urandom > /tmp/testfile.bin"
	local expected_sum
	expected_sum="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sha256sum /tmp/testfile.bin | cut -d' ' -f1")"

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 \
		"scp $TESTSUITE_PEER_SSH_OPTS -i ~/.ssh/id_ed25519_shared /tmp/testfile.bin vagrant@$node2_ip:/tmp/testfile.bin" \
		|| fatal "scp-transfer: scp from node1 to node2 failed"

	local actual_sum
	actual_sum="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sha256sum /tmp/testfile.bin | cut -d' ' -f1")"

	if [[ "$expected_sum" != "$actual_sum" ]]; then
		log_fail "scp-transfer: checksum mismatch after scp (expected $expected_sum, got $actual_sum)"
		exit 1
	fi
	log_pass "scp-transfer: 1MB file transferred over mesh IP, checksum matches ($expected_sum)"
}

main
