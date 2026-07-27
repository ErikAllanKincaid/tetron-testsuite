#!/usr/bin/env bash
# meta:id ssh-jump-host-cross-network
# meta:description SSH jump-host across two tetron networks with no direct route between them -- validates MULTISEG-003's documented workaround
# meta:nodes 3
# meta:networks 2
#
# node2 creates two networks (neta, netb) -- MULTISEG-002..007's "one shared
# daemon, N isolated per-network TUNs" -- node1 joins neta only, node3 joins
# netb only. node1 and node3 share no network and should NOT be able to
# reach each other directly (tetron deliberately does not route between a
# node's own segments, see AGENTS.md's architecture note); node2, joined to
# both, is the intended jump host: `ssh -J node2 node3` from node1 should
# work even though a direct `ssh node3` from node1 does not.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd jq ssh scp ssh-keygen

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"

RUN_ID="ssh-jump-host-$$"
BROUGHT_UP=0
NODES=(node1 node2 node3)

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "ssh-jump-host-cross-network: no tetron binary at $TESTSUITE_TETRON_BINARY -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 3 || fatal "ssh-jump-host-cross-network: topology_up failed"
	BROUGHT_UP=1

	local node
	for node in "${NODES[@]}"; do
		vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "ssh-jump-host-cross-network: vm_upload failed on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install && sudo apt-get update -qq && sudo apt-get install -y -qq openssh-client" || fatal "ssh-jump-host-cross-network: install failed on $node"
	done

	vm_setup_peer_ssh "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "${NODES[@]}" || fatal "ssh-jump-host-cross-network: vm_setup_peer_ssh failed"

	# node2 is the jump host: coordinator of both networks.
	local create_a invite_a
	create_a="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron create --network-name neta --hostname node2")" || fatal "ssh-jump-host-cross-network: 'tetron create neta' failed on node2"
	invite_a="$(echo "$create_a" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite_a" ]] || fatal "ssh-jump-host-cross-network: no invite code from neta create: $create_a"

	local create_b invite_b
	create_b="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron create --network-name netb --hostname node2")" || fatal "ssh-jump-host-cross-network: 'tetron create netb' failed on node2"
	invite_b="$(echo "$create_b" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite_b" ]] || fatal "ssh-jump-host-cross-network: no invite code from netb create: $create_b"

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron join $invite_a --hostname node1" || fatal "ssh-jump-host-cross-network: node1 join neta failed"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node3 "sudo tetron join $invite_b --hostname node3" || fatal "ssh-jump-host-cross-network: node3 join netb failed"

	log_info "waiting for admission to propagate"
	sleep 10

	local node1_status node2_status node2_ip_on_a node3_ip_on_b
	node1_status="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	node2_ip_on_a="$(json_get '.networks[] | select(.network=="neta") | .peers[] | select(.hostname=="node2") | .ip' "$node1_status")"
	[[ -n "$node2_ip_on_a" ]] || fatal "ssh-jump-host-cross-network: could not find node2's neta IP from node1's status: $node1_status"
	log_info "node2's neta IP (as seen from node1): $node2_ip_on_a"

	node2_status="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "tetron status --json")"
	node3_ip_on_b="$(json_get '.networks[] | select(.network=="netb") | .peers[] | select(.hostname=="node3") | .ip' "$node2_status")"
	[[ -n "$node3_ip_on_b" ]] || fatal "ssh-jump-host-cross-network: could not find node3's netb IP from node2's status: $node2_status"
	log_info "node3's netb IP (as seen from node2): $node3_ip_on_b"

	# Only wait for the two hops the jump-host check actually needs --
	# node1 -> node2 over neta, node2 -> node3 over netb. Deliberately not
	# waiting for node3 to be reachable from node1 directly: that's the
	# isolation check right below, and it is supposed to never succeed.
	wait_for_peer_port "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "$node2_ip_on_a" 22 30 \
		|| fatal "ssh-jump-host-cross-network: node2's neta IP:22 never became reachable from node1"
	wait_for_peer_port "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "$node3_ip_on_b" 22 30 \
		|| fatal "ssh-jump-host-cross-network: node3's netb IP:22 never became reachable from node2"

	local rc=0

	# Isolation check: node1 has no route to netb's subnet at all (not a
	# member), so a direct connection attempt should fail, not just be
	# refused -- confirms MULTISEG-003's "does not route between a node's
	# own segments" claim before proving the jump-host workaround.
	if timeout 10 vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "ssh $TESTSUITE_PEER_SSH_OPTS -o ConnectTimeout=5 -i ~/.ssh/id_ed25519_shared vagrant@$node3_ip_on_b true" 2>/dev/null; then
		log_fail "ssh-jump-host-cross-network: node1 reached node3 directly -- networks are NOT isolated as documented"
		rc=1
	else
		log_pass "ssh-jump-host-cross-network: node1 cannot reach node3 directly (expected -- no shared network)"
	fi

	# The actual workaround: jump through node2, which is on both networks.
	# Explicit -o ProxyCommand instead of the -J shorthand: found live that
	# -J's implicit jump connection did not reliably inherit this command's
	# own -o StrictHostKeyChecking=no/UserKnownHostsFile=/dev/null, causing
	# "Host key verification failed" against the jump hop. ProxyCommand is
	# a fully explicit invocation, so both hops are unambiguously covered
	# by the same options.
	local got
	got="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "ssh $TESTSUITE_PEER_SSH_OPTS -i ~/.ssh/id_ed25519_shared -o 'ProxyCommand=ssh $TESTSUITE_PEER_SSH_OPTS -i ~/.ssh/id_ed25519_shared -W %h:%p vagrant@$node2_ip_on_a' vagrant@$node3_ip_on_b hostname")"
	if [[ "$got" == "node3" ]]; then
		log_pass "ssh-jump-host-cross-network: node1 -J node2 -> node3 succeeded (hostname: $got)"
	else
		log_fail "ssh-jump-host-cross-network: expected 'node3' via jump host, got '$got'"
		rc=1
	fi

	return $rc
}

main
